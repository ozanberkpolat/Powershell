#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Run one script on many Azure VMs through Run Command and keep the evidence.

.DESCRIPTION
    One wrapper for everything that used to be a pile of one-off Run Command scripts:

      - Targets by VM name (+ optional resource group / subscription) or by resource ID list.
        Names are resolved with Resource Graph across every readable subscription. A name that
        matches zero or several VMs stops the run before anything is sent.
      - Windows or Linux is detected per VM (RunPowerShellScript / RunShellScript).
      - Script from a file (-ScriptPath) or inline (-Script). Text is sent verbatim; CRLF is
        converted to LF for Linux so a Windows-edited .sh does not fail with "\r: command not found".
      - Retries with backoff when Azure answers Conflict (another Run Command or extension
        operation is still running on that VM).
      - -Parallel fans out over VMs (different VMs in parallel, never two scripts on one VM).
      - -ProtectedParameter passes secrets such as a SAS token so they never appear in the
        script text, the Activity Log or the evidence folder (only the parameter NAMES are saved).
        Protected parameters exist only on managed Run Command resources, so that switches the
        method to Managed automatically.
      - Evidence per VM under <EvidenceFolder>/<timestamp>/<vm>/ : script as sent, stdout.txt,
        stderr.txt, result.json (state, exit code, attempts, seconds). A summary table is printed
        and written to summary.csv.
      - Exit code of the PowerShell process is 1 when any VM failed, so it can gate a pipeline.

    Methods
      Invoke   (default) POST .../runCommand. Nothing is left behind on the VM resource.
               The API returns output but NO exit code; a VM is marked Failed on an API error or a
               Failed status, and optionally on any stderr output (-FailOnStderr).
      Managed  PUT .../runCommands/<name>, read instance view, then delete the resource (unless
               -KeepRunCommand). Gives a real exitCode, supports protected parameters and long
               timeouts. Each VM allows only 25 managed run commands; see Remove-StaleRunCommands.ps1.

.PARAMETER VmName
    VM names. Combine with -ResourceGroup and/or -Subscription to disambiguate.
.PARAMETER ResourceId
    Full VM resource IDs. Use instead of -VmName.
.PARAMETER ScriptPath
    Script file to send.
.PARAMETER Script
    Inline script text to send.
.PARAMETER Parameter
    Hashtable of plain parameters. Windows: available as parameters of the script; Linux: environment variables.
.PARAMETER ProtectedParameter
    Hashtable of secret parameters (for example @{ SAS = $sas }). Forces -Method Managed.
.PARAMETER OsType
    Auto (default), Windows or Linux. Auto uses the OS type recorded on the VM's OS disk.
.PARAMETER Method
    Invoke (default) or Managed.
.PARAMETER Parallel
    Run VMs concurrently. Needs an Az context that child runspaces can load (default autosave is fine;
    if not, run Enable-AzContextAutosave first).
.PARAMETER ThrottleLimit
    Concurrent VMs with -Parallel. Default 5.
.PARAMETER TimeoutSeconds
    Script timeout. Invoke: how long to poll. Managed: also sent as timeoutInSeconds. Default 1800.
.PARAMETER MaxConflictRetries
    Retries on Conflict with 15s, 30s, 60s ... capped at 120s. Default 8.
.PARAMETER EvidenceFolder
    Root folder for evidence. Default ./run-command-evidence.
.PARAMETER FailOnStderr
    Treat any stderr output as a failure.
.PARAMETER KeepRunCommand
    Managed method: do not delete the run command resource afterwards.
.PARAMETER PassThru
    Also return the per-VM result objects.

.EXAMPLE
    ./Invoke-VmRunCommand.ps1 -VmName vm-app-01,vm-app-02 -ResourceGroup rg-app -ScriptPath ./check-service.ps1

.EXAMPLE
    ./Invoke-VmRunCommand.ps1 -ResourceId $ids -Script 'uname -r; df -h /boot' -Parallel -ThrottleLimit 8

.EXAMPLE
    # Long copy with a SAS that must not be logged
    ./Invoke-VmRunCommand.ps1 -VmName vm-db-01 -ScriptPath ./copy-backups.sh -Parameter @{ MODE = 'dryrun' } `
        -ProtectedParameter @{ SAS = $sas } -TimeoutSeconds 7200

.NOTES
    Required role: Virtual Machine Contributor (Microsoft.Compute/virtualMachines/runCommand/action, and for
    -Method Managed also runCommands/write and delete). With PIM, activate before the run.
    Modules: Az.Accounts. Name resolution uses the Resource Graph REST API (Reader is enough).
    Traps kept from real use:
      - Only one Run Command (or VM extension operation) runs per VM at a time; the second gets Conflict.
        That is why VMs run in parallel but each VM is sequential, and why Conflict is retried.
      - Maximum 25 managed run commands per VM; at the limit Azure refuses new ones AND refuses to
        overwrite an existing name, so this script uses a unique name per call and deletes it afterwards.
      - Run Command payload limit is about 2 MB (4 MB is rejected with RequestedSizeExceeded). For larger
        files use Push-InstallerViaRunCommand.ps1.
      - Output is truncated by the platform at about 4 KB for the Invoke method. Write long output to a file
        on the VM, or print a compact summary line, or use -Method Managed (larger instance view).
      - The Linux agent runs scripts as root with a minimal PATH; use absolute paths for tools.
      - Send the script to run exactly as it was reviewed. The saved sent-script file is byte-identical
        to what was posted (after the LF normalisation), so it can be attached to a change record.
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')][string[]]$VmName,
    [Parameter(ParameterSetName = 'ByName')][string]$ResourceGroup,
    [Parameter(ParameterSetName = 'ByName')][string]$Subscription,
    [Parameter(Mandatory, ParameterSetName = 'ById')][string[]]$ResourceId,

    [string]$ScriptPath,
    [string]$Script,
    [hashtable]$Parameter,
    [hashtable]$ProtectedParameter,
    [ValidateSet('Auto', 'Windows', 'Linux')][string]$OsType = 'Auto',
    [ValidateSet('Invoke', 'Managed')][string]$Method = 'Invoke',
    [switch]$Parallel,
    [int]$ThrottleLimit = 5,
    [int]$TimeoutSeconds = 1800,
    [int]$MaxConflictRetries = 8,
    [string]$EvidenceFolder = './run-command-evidence',
    [switch]$FailOnStderr,
    [switch]$KeepRunCommand,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')

# ---- input checks -----------------------------------------------------------
if ([bool]$ScriptPath -eq [bool]$Script) { throw 'Pass exactly one of -ScriptPath or -Script.' }
if ($ScriptPath) {
    if (-not (Test-Path $ScriptPath)) { throw "Script file not found: $ScriptPath" }
    $scriptText = Get-Content -Raw -Path $ScriptPath
} else { $scriptText = $Script }
$scriptText = $scriptText.TrimStart([char]0xFEFF)
if (-not $scriptText.Trim()) { throw 'The script is empty.' }
if ($ProtectedParameter -and $Method -ne 'Managed') {
    Write-Warning 'Protected parameters need a managed run command: switching to -Method Managed.'
    $Method = 'Managed'
}
$bytes = [Text.Encoding]::UTF8.GetByteCount($scriptText)
if ($bytes -gt 2MB) { throw "Script is $bytes bytes; Run Command accepts about 2 MB. See Push-InstallerViaRunCommand.ps1 for large payloads." }
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }

# ---- resolve targets (Resource Graph, all readable subscriptions) -------------
$kql = "resources | where type =~ 'microsoft.compute/virtualmachines' | extend osType = tostring(properties.storageProfile.osDisk.osType) | project id, name, resourceGroup, subscriptionId, location, osType"
$q = if ($PSCmdlet.ParameterSetName -eq 'ById') {
    $list = ($ResourceId | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    "$kql | where id in~ ($list)"
} else {
    $list = ($VmName | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $f = "$kql | where name in~ ($list)"
    if ($ResourceGroup) { $f += " | where resourceGroup =~ '" + ($ResourceGroup -replace "'", "''") + "'" }
    $f
}
$subScope = if ($Subscription) { @($Subscription) } else { $null }
$found = if ($subScope) { @(Search-Graph -Query $q -Subscription $subScope) } else { @(Search-Graph -Query $q) }
$wanted = if ($PSCmdlet.ParameterSetName -eq 'ById') { $ResourceId } else { $VmName }
foreach ($w in $wanted) {
    $m = @($found | Where-Object { $_.id -ieq $w -or $_.name -ieq $w })
    if ($m.Count -eq 0) { throw "No VM matched '$w' in the readable subscriptions." }
    if ($m.Count -gt 1) { throw "'$w' matched $($m.Count) VMs ($($m.id -join '; ')). Add -ResourceGroup/-Subscription or use -ResourceId." }
}
$targets = @($found | Sort-Object id -Unique)
foreach ($t in $targets) { if (-not $t.osType -and $OsType -eq 'Auto') { throw "OS type of $($t.name) unknown; pass -OsType." } }

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$root = Join-Path $EvidenceFolder $runId
New-Item -ItemType Directory -Path $root -Force | Out-Null
Write-Host "Targets: $($targets.Count) VM(s), method $Method, evidence $root" -ForegroundColor Cyan

# ---- worker: self-contained so it can run in a parallel runspace -------------
$worker = {
    param($vm, $ctx)
    $ErrorActionPreference = 'Stop'
    $started = Get-Date
    $os = if ($ctx.OsType -eq 'Auto') { $vm.osType } else { $ctx.OsType }
    $isLinux = ($os -eq 'Linux')
    $commandId = if ($isLinux) { 'RunShellScript' } else { 'RunPowerShellScript' }
    $text = if ($isLinux) { $ctx.ScriptText -replace "`r`n", "`n" } else { $ctx.ScriptText }
    $dir = Join-Path $ctx.Root $vm.name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $ext = if ($isLinux) { 'sh' } else { 'ps1' }
    [IO.File]::WriteAllText((Join-Path $dir "sent-script.$ext"), $text, [Text.UTF8Encoding]::new($false))

    $res = [ordered]@{
        Vm = $vm.name; ResourceGroup = $vm.resourceGroup; Subscription = $vm.subscriptionId; OsType = $os
        Method = $ctx.Method; State = 'Error'; ExitCode = $null; Attempts = 0; Seconds = 0; Error = $null; Evidence = $dir
    }
    $stdout = ''; $stderr = ''
    $api = '2024-07-01'

    function HeaderValue($resp, $name) {
        foreach ($h in $resp.Headers) { if ("$($h.Key)" -ieq $name) { return (@($h.Value) | Select-Object -First 1) } }
        $null
    }
    function Wait-Backoff($n) { $s = [Math]::Min(15 * [Math]::Pow(2, $n - 1), 120); Start-Sleep -Seconds $s }
    function Split-Output($vals) {
        $o = ''; $e = ''
        foreach ($v in @($vals)) {
            if ($v.code -like '*StdOut*') { $o += $v.message }
            elseif ($v.code -like '*StdErr*') { $e += $v.message }
        }
        # Older Linux agents return one StdOut entry carrying "[stdout] ... [stderr] ...".
        if (-not $e -and $o -match '(?s)\[stdout\]\r?\n(.*?)\r?\n?\[stderr\]\r?\n?(.*)$') { $o = $Matches[1]; $e = $Matches[2] }
        @($o, $e)
    }

    try {
        if (-not (Get-AzContext)) { throw 'No Az context in this runspace. Run Enable-AzContextAutosave (or Connect-AzAccount) and retry with -Parallel off if it persists.' }
        $conflict = 0
        $deadline = (Get-Date).AddSeconds($ctx.TimeoutSeconds + 300)

        if ($ctx.Method -eq 'Invoke') {
            $body = @{ commandId = $commandId; script = @($text -split "`n") }
            if ($ctx.Parameter) { $body.parameters = @($ctx.Parameter.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = "$($_.Value)" } }) }
            $json = $body | ConvertTo-Json -Depth 6 -Compress
            while ($true) {
                $res.Attempts++
                $r = Invoke-AzRestMethod -Method POST -Path "$($vm.id)/runCommand?api-version=$api" -Payload $json
                $code = [int]$r.StatusCode
                if ($code -eq 409) { $conflict++; if ($conflict -gt $ctx.MaxConflictRetries) { throw "Conflict persisted after $($ctx.MaxConflictRetries) retries: $($r.Content)" }; Write-Warning "$($vm.name): Conflict, another operation is running. Retry $conflict."; Wait-Backoff $conflict; continue }
                if ($code -eq 429) { Start-Sleep -Seconds 30; continue }
                if ($code -notin 200, 202) { throw "POST runCommand returned $code $($r.Content)" }
                $poll = HeaderValue $r 'Azure-AsyncOperation'
                if (-not $poll) { $poll = HeaderValue $r 'Location' }
                $c = $null
                if ($code -eq 200) { $c = $r.Content | ConvertFrom-Json }
                else {
                    if (-not $poll) { throw 'No polling URL returned by Run Command.' }
                    while ($true) {
                        if ((Get-Date) -gt $deadline) { $res.State = 'TimedOut'; throw "Timed out polling after $($ctx.TimeoutSeconds)s." }
                        Start-Sleep -Seconds 10
                        $p = Invoke-AzRestMethod -Method GET -Uri "$poll"
                        if ([int]$p.StatusCode -eq 202) { continue }
                        $c = if ($p.Content) { $p.Content | ConvertFrom-Json } else { $null }
                        if ($c -and $c.status -in 'InProgress', 'Running') { continue }
                        break
                    }
                }
                $errText = if ($c.error) { ($c.error | ConvertTo-Json -Depth 5 -Compress) } else { $null }
                if ($errText -match 'Conflict') { $conflict++; if ($conflict -gt $ctx.MaxConflictRetries) { throw "Conflict persisted: $errText" }; Wait-Backoff $conflict; continue }
                $vals = if ($c.properties.output.value) { $c.properties.output.value } elseif ($c.value) { $c.value } else { $null }
                if ($errText -or $c.status -eq 'Failed') { throw "Run Command failed: $errText" }
                if (-not $vals) { throw "No output values returned (status '$($c.status)')." }
                $stdout, $stderr = Split-Output $vals
                $res.State = 'Succeeded'
                if ($ctx.FailOnStderr -and $stderr.Trim()) { $res.State = 'Failed'; $res.Error = 'stderr output present (-FailOnStderr).' }
                break
            }
        }
        else {
            $name = 'rc-{0}-{1}' -f (Get-Date -Format 'yyyyMMddHHmmss'), (Get-Random -Maximum 99999)
            $props = @{ source = @{ script = $text }; asyncExecution = $false; timeoutInSeconds = $ctx.TimeoutSeconds; treatFailureAsDeploymentFailure = $false }
            if ($ctx.Parameter) { $props.parameters = @($ctx.Parameter.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = "$($_.Value)" } }) }
            if ($ctx.ProtectedParameter) { $props.protectedParameters = @($ctx.ProtectedParameter.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = "$($_.Value)" } }) }
            $json = @{ location = $vm.location; properties = $props } | ConvertTo-Json -Depth 8 -Compress
            $rcPath = "$($vm.id)/runCommands/$name"
            $created = $false
            while ($true) {
                $res.Attempts++
                $r = Invoke-AzRestMethod -Method PUT -Path "${rcPath}?api-version=$api" -Payload $json
                $code = [int]$r.StatusCode
                if ($code -eq 409) { $conflict++; if ($conflict -gt $ctx.MaxConflictRetries) { throw "Conflict persisted after $($ctx.MaxConflictRetries) retries: $($r.Content)" }; Write-Warning "$($vm.name): Conflict, another operation is running. Retry $conflict."; Wait-Backoff $conflict; continue }
                if ($code -eq 429) { Start-Sleep -Seconds 30; continue }
                if ($code -notin 200, 201, 202) { throw "PUT runCommands returned $code $($r.Content). At the 25-per-VM limit run Remove-StaleRunCommands.ps1." }
                $created = $true
                break
            }
            try {
                $terminal = 'Succeeded', 'Failed', 'TimedOut', 'Canceled'
                $iv = $null
                while ($true) {
                    if ((Get-Date) -gt $deadline) { $res.State = 'TimedOut'; throw "Timed out polling after $($ctx.TimeoutSeconds)s." }
                    Start-Sleep -Seconds 10
                    $g = Invoke-AzRestMethod -Method GET -Path "${rcPath}?`$expand=instanceView&api-version=$api"
                    if ([int]$g.StatusCode -ge 400) { throw "GET runCommands returned $($g.StatusCode) $($g.Content)" }
                    $o = $g.Content | ConvertFrom-Json
                    if ($o.properties.provisioningState -eq 'Failed' -and -not $o.properties.instanceView) { throw "Provisioning failed: $($g.Content)" }
                    $iv = $o.properties.instanceView
                    if ($iv -and $iv.executionState -in $terminal) { break }
                }
                $stdout = "$($iv.output)"; $stderr = "$($iv.error)"
                $res.ExitCode = $iv.exitCode
                $res.State = $iv.executionState
                if ($iv.executionState -eq 'Succeeded' -and $iv.exitCode -ne 0) { $res.State = 'Failed'; $res.Error = "exit code $($iv.exitCode)" }
                if ($ctx.FailOnStderr -and $stderr.Trim() -and $res.State -eq 'Succeeded') { $res.State = 'Failed'; $res.Error = 'stderr output present (-FailOnStderr).' }
            }
            finally {
                if ($created -and -not $ctx.KeepRunCommand) {
                    $d = Invoke-AzRestMethod -Method DELETE -Path "${rcPath}?api-version=$api"
                    if ([int]$d.StatusCode -ge 400) { Write-Warning "$($vm.name): could not delete run command ${name}: $($d.StatusCode) $($d.Content)" }
                } elseif ($created) { $res.Evidence = $dir; $res.RunCommand = $name }
            }
        }
    }
    catch {
        if ($res.State -ne 'TimedOut') { $res.State = 'Error' }
        $res.Error = "$_"
    }
    Set-Content -Path (Join-Path $dir 'stdout.txt') -Value $stdout -Encoding utf8
    Set-Content -Path (Join-Path $dir 'stderr.txt') -Value $stderr -Encoding utf8
    $res.Seconds = [int]((Get-Date) - $started).TotalSeconds
    $obj = [pscustomobject]$res
    # Parameter VALUES are never saved; protected parameters only by name.
    $meta = $obj | Select-Object *, @{ n = 'ParameterNames'; e = { @($ctx.Parameter.Keys) } }, @{ n = 'ProtectedParameterNames'; e = { @($ctx.ProtectedParameter.Keys) } }
    $meta | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dir 'result.json') -Encoding utf8
    $obj
}

$ctx = @{
    OsType = $OsType; Method = $Method; ScriptText = $scriptText; Root = $root
    Parameter = $Parameter; ProtectedParameter = $ProtectedParameter
    TimeoutSeconds = $TimeoutSeconds; MaxConflictRetries = $MaxConflictRetries
    FailOnStderr = [bool]$FailOnStderr; KeepRunCommand = [bool]$KeepRunCommand
}

if ($Parallel -and $targets.Count -gt 1) {
    $workerText = $worker.ToString()
    $results = $targets | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $sb = [scriptblock]::Create($using:workerText)
        & $sb $_ $using:ctx
    }
} else {
    $results = foreach ($t in $targets) { Write-Host "-> $($t.name)"; & $worker $t $ctx }
}
$results = @($results)

# ---- summary -------------------------------------------------------------------
$summary = $results | Select-Object Vm, OsType, Method, State, ExitCode, Attempts, Seconds, Error
$summary | Format-Table -AutoSize | Out-String | Write-Host
$summary | Export-Csv -Path (Join-Path $root 'summary.csv') -NoTypeInformation -Encoding utf8
Write-Host "Evidence: $root" -ForegroundColor Cyan

$bad = @($results | Where-Object { $_.State -ne 'Succeeded' })
if ($PassThru) { $results }
if ($bad.Count) {
    Write-Error "$($bad.Count) of $($results.Count) VM(s) failed: $($bad.Vm -join ', ')" -ErrorAction Continue
    exit 1
}
