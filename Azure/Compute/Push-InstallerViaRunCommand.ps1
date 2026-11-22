#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Deliver an installer to VMs that cannot download it, through Run Command, then install it.

.DESCRIPTION
    Some VMs cannot fetch software themselves: outbound TLS inspection breaks every external HTTPS
    host under SYSTEM, shared-key storage is disabled, no blob data role is held, and public network
    access on storage is denied by policy. Run Command is the one channel that already reaches the VM,
    so the bytes ride in on it:

      1. Optional precheck script per VM. Only VMs whose output matches -PrecheckOkPattern get the
         payload, so nothing large is shipped to a machine that is already current or busy.
      2. The file is base64 encoded and cut into chunks (default 1.8 million characters). Each chunk
         is one Run Command call that writes one part file and echoes its landed length. The length is
         checked against what was sent. Chunk 0 resets the staging folder so a retry never appends to
         a stale run.
      3. A finalize call concatenates the parts, decodes, compares SHA-256 with the local file and only
         then runs -InstallScript. The staging folder is removed afterwards.

    VMs run in parallel (-Throttle), the chunks of one VM run in order because a VM runs one Run Command
    at a time. Conflict (another operation running) is retried with backoff.

    Windows and Linux targets are supported (detected per VM).

.PARAMETER FilePath
    The installer or payload to deliver.
.PARAMETER VmName
    VM names (+ -ResourceGroup / -Subscription), or -ResourceId.
.PARAMETER InstallScript
    Script text run on the VM after the hash check. The token {{FILE}} is replaced with the staged path,
    {{SHA256}} with the expected hash. Windows targets run it as PowerShell, Linux as bash. Leave empty to only stage
    the file (it then stays in the staging folder).
.PARAMETER PrecheckScript
    Script text run first. Together with -PrecheckOkPattern decides which VMs receive the payload.
.PARAMETER PrecheckOkPattern
    Regex that the precheck stdout must match. Required when -PrecheckScript is used.
.PARAMETER StageDir
    Staging folder on the VM. Default C:\Windows\Temp\installer-stage (Windows) or /var/tmp/installer-stage (Linux).
.PARAMETER StagedName
    File name on the VM. Default is the local file name.
.PARAMETER ChunkChars
    Base64 characters per call. The platform accepts about 2 MB per script and rejects 4 MB with
    RequestedSizeExceeded, so stay at 1.8 million or below.
.PARAMETER Throttle
    VMs in parallel. Default 5.
.PARAMETER LogCsv
    Result CSV. Default ./installer-push-<timestamp>.csv

.EXAMPLE
    $install = '$p = Start-Process "{{FILE}}" -ArgumentList "/S" -Wait -PassThru; "STATUS=DONE;exit=$($p.ExitCode)"'
    ./Push-InstallerViaRunCommand.ps1 -FilePath ./tool-setup.exe -VmName vm-app-01,vm-app-02 -InstallScript $install -WhatIf

.NOTES
    Role: Virtual Machine Contributor. Installing software is a change: raise it as one and activate PIM first.
    Modules: Az.Accounts. The local file is read fully into memory and encoded once; a 10 MB file is about
    6 calls per VM, so a 40 VM fleet is a few hundred calls: mind the ARM write limits and use a modest -Throttle.
    Traps kept:
      - The 2 MB / 4 MB payload ceiling (see ChunkChars).
      - Verify the length of every chunk AND the final SHA-256. A silently truncated installer is worse than a failed one.
      - Do not run the installer when the application is in use unless your install script defers; put that decision
        in the precheck, not after the 9 MB has been sent.
      - Run Command output is truncated at about 4 KB; the install script should print one STATUS= line.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory, ParameterSetName = 'ByName')][string[]]$VmName,
    [Parameter(ParameterSetName = 'ByName')][string]$ResourceGroup,
    [Parameter(ParameterSetName = 'ByName')][string]$Subscription,
    [Parameter(Mandatory, ParameterSetName = 'ById')][string[]]$ResourceId,
    [string]$InstallScript = '',
    [string]$PrecheckScript = '',
    [string]$PrecheckOkPattern = '',
    [string]$StageDir,
    [string]$StagedName,
    [ValidateRange(100000, 1900000)][int]$ChunkChars = 1800000,
    [int]$Throttle = 5,
    [int]$MaxConflictRetries = 8,
    [string]$LogCsv = "./installer-push-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Test-Path $FilePath)) { throw "File not found: $FilePath" }
if ($PrecheckScript -and -not $PrecheckOkPattern) { throw '-PrecheckScript needs -PrecheckOkPattern.' }
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }

# ---- targets -----------------------------------------------------------------
$kql = "resources | where type =~ 'microsoft.compute/virtualmachines' | extend osType = tostring(properties.storageProfile.osDisk.osType) | project id, name, resourceGroup, subscriptionId, location, osType"
if ($PSCmdlet.ParameterSetName -eq 'ById') { $kql += " | where id in~ (" + (($ResourceId | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")" }
else {
    $kql += " | where name in~ (" + (($VmName | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")"
    if ($ResourceGroup) { $kql += " | where resourceGroup =~ '" + ($ResourceGroup -replace "'", "''") + "'" }
}
$targets = @(if ($Subscription) { Search-Graph -Query $kql -Subscription $Subscription } else { Search-Graph -Query $kql })
$wanted = if ($PSCmdlet.ParameterSetName -eq 'ById') { $ResourceId } else { $VmName }
foreach ($w in $wanted) {
    $m = @($targets | Where-Object { $_.id -ieq $w -or $_.name -ieq $w })
    if ($m.Count -ne 1) { throw "'$w' matched $($m.Count) VMs; need exactly 1." }
}

# ---- payload -------------------------------------------------------------------
$expectedSha = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($FilePath))
$chunks = for ($i = 0; $i -lt $b64.Length; $i += $ChunkChars) { $b64.Substring($i, [Math]::Min($ChunkChars, $b64.Length - $i)) }
$chunks = @($chunks)
$leaf = if ($StagedName) { $StagedName } else { Split-Path $FilePath -Leaf }
Write-Host ("{0} | SHA-256 {1} | {2:n0} base64 chars -> {3} chunk(s) | {4} VM(s)" -f $leaf, $expectedSha, $b64.Length, $chunks.Count, $targets.Count) -ForegroundColor Cyan
Write-Host ("Calls: {0} total ({1} chunks + finalize{2} per VM)" -f ($targets.Count * ($chunks.Count + 1 + [int][bool]$PrecheckScript)), $chunks.Count, $(if ($PrecheckScript) { ' + precheck' } else { '' }))

if (-not $PSCmdlet.ShouldProcess("$($targets.Count) VM(s): $($targets.name -join ', ')", "Push $leaf and run install script")) { return }

$ctx = @{
    Chunks = $chunks; Sha = $expectedSha; Leaf = $leaf; StageDir = $StageDir
    Install = $InstallScript; Precheck = $PrecheckScript; PrecheckOk = $PrecheckOkPattern; MaxConflict = $MaxConflictRetries
}

$worker = {
    param($vm, $ctx)
    $ErrorActionPreference = 'Stop'
    $isLinux = ($vm.osType -eq 'Linux')
    $stage = if ($ctx.StageDir) { $ctx.StageDir } elseif ($isLinux) { '/var/tmp/installer-stage' } else { 'C:\Windows\Temp\installer-stage' }
    $staged = if ($isLinux) { "$stage/$($ctx.Leaf)" } else { Join-Path $stage $ctx.Leaf }
    $api = '2024-07-01'

    # Send one script, return stdout (string) or throw. Retries Conflict with backoff.
    function Send([string]$text) {
        if ($isLinux) { $text = $text -replace "`r`n", "`n" }
        $body = @{ commandId = $(if ($isLinux) { 'RunShellScript' } else { 'RunPowerShellScript' }); script = @($text -split "`n") } | ConvertTo-Json -Depth 5 -Compress
        $conflict = 0
        while ($true) {
            $r = Invoke-AzRestMethod -Method POST -Path "$($vm.id)/runCommand?api-version=$api" -Payload $body
            $code = [int]$r.StatusCode
            if ($code -eq 409 -or $code -eq 429) {
                $conflict++; if ($conflict -gt $ctx.MaxConflict) { throw "Still busy ($code) after $($ctx.MaxConflict) retries" }
                Start-Sleep -Seconds ([Math]::Min(15 * [Math]::Pow(2, $conflict - 1), 120)); continue
            }
            if ($code -notin 200, 202) { throw "POST runCommand $code $($r.Content)" }
            $poll = $null
            foreach ($h in $r.Headers) { if ("$($h.Key)" -ieq 'Azure-AsyncOperation') { $poll = @($h.Value)[0] } }
            if (-not $poll) { foreach ($h in $r.Headers) { if ("$($h.Key)" -ieq 'Location') { $poll = @($h.Value)[0] } } }
            $c = if ($code -eq 200) { $r.Content | ConvertFrom-Json } else { $null }
            $deadline = (Get-Date).AddMinutes(20)
            while ($code -eq 202) {
                if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for Run Command' }
                Start-Sleep -Seconds 5
                $p = Invoke-AzRestMethod -Method GET -Uri "$poll"
                if ([int]$p.StatusCode -eq 202) { continue }
                $c = if ($p.Content) { $p.Content | ConvertFrom-Json } else { $null }
                if ($c -and $c.status -in 'InProgress', 'Running') { continue }
                break
            }
            if ($c.error) {
                $e = $c.error | ConvertTo-Json -Compress -Depth 4
                if ($e -match 'Conflict') { $conflict++; if ($conflict -gt $ctx.MaxConflict) { throw "Conflict: $e" }; Start-Sleep -Seconds ([Math]::Min(15 * [Math]::Pow(2, $conflict - 1), 120)); continue }
                throw "Run Command error: $e"
            }
            $vals = if ($c.properties.output.value) { $c.properties.output.value } else { $c.value }
            if (-not $vals) { throw 'No output returned' }
            return (($vals | Where-Object { $_.code -like '*StdOut*' } | ForEach-Object message) -join "`n")
        }
    }
    function Marker([string]$out, [string]$name) { ($out -split "`r?`n" | Where-Object { $_ -match "^$name=" } | Select-Object -First 1) }
    function Row($code, $detail) { [pscustomobject]@{ Vm = $vm.name; Code = $code; Detail = $detail } }

    try {
        # 1. precheck
        if ($ctx.Precheck) {
            $pre = Send $ctx.Precheck
            if ($pre -notmatch $ctx.PrecheckOk) { Write-Host "$($vm.name): precheck says skip" -ForegroundColor Yellow; return Row 'SKIPPED-PRECHECK' (($pre -split "`n" | Select-Object -First 1)) }
        }
        # 2. chunks
        for ($i = 0; $i -lt $ctx.Chunks.Count; $i++) {
            $part = 'part{0:d3}.b64' -f $i
            $len = $ctx.Chunks[$i].Length
            if ($isLinux) {
                $reset = if ($i -eq 0) { "rm -rf '$stage'; mkdir -p '$stage'" } else { "[ -d '$stage' ] || { echo 'CHUNK=MISSING-STAGEDIR'; exit 0; }" }
                $s = "$reset`nprintf '%s' '$($ctx.Chunks[$i])' > '$stage/$part'`necho `"CHUNK=OK;idx=$i;len=`$(wc -c < '$stage/$part' | tr -d ' ')`""
            } else {
                $reset = if ($i -eq 0) { "if (Test-Path '$stage') { Remove-Item '$stage' -Recurse -Force }`nNew-Item -ItemType Directory -Path '$stage' -Force | Out-Null" }
                         else { "if (-not (Test-Path '$stage')) { Write-Output 'CHUNK=MISSING-STAGEDIR'; return }" }
                $s = "$reset`n`$b = '$($ctx.Chunks[$i])'`n[IO.File]::WriteAllText((Join-Path '$stage' '$part'), `$b)`nWrite-Output `"CHUNK=OK;idx=$i;len=`$(`$b.Length)`""
            }
            $m = Marker (Send $s) 'CHUNK'
            if ($m -ne "CHUNK=OK;idx=$i;len=$len") { return Row 'CHUNK-FAILED' "chunk $i of $($ctx.Chunks.Count): got '$m', expected len $len" }
            Write-Host ("{0,-40} chunk {1}/{2} ok" -f $vm.name, ($i + 1), $ctx.Chunks.Count) -ForegroundColor DarkGray
        }
        # 3. finalize: reassemble, verify hash, install, clean up
        $inst = $ctx.Install.Replace('{{FILE}}', $staged).Replace('{{SHA256}}', $ctx.Sha)
        if ($isLinux) {
            $f = @"
set -e
cd '$stage'
n=`$(ls part*.b64 | wc -l); [ "`$n" -eq $($ctx.Chunks.Count) ] || { echo "STATUS=FAILED;reason=chunk-count-`$n"; exit 0; }
cat part*.b64 | base64 -d > '$staged'
h=`$(sha256sum '$staged' | cut -d' ' -f1)
if [ "`${h^^}" != '$($ctx.Sha.ToUpper())' ]; then echo "STATUS=FAILED;reason=hash-mismatch;got=`$h"; rm -rf '$stage'; exit 0; fi
echo "STAGED=OK;sha256=`$h"
$inst
rm -rf '$stage'
"@
        } else {
            $f = @"
`$parts = Get-ChildItem '$stage' -Filter 'part*.b64' | Sort-Object Name
if (`$parts.Count -ne $($ctx.Chunks.Count)) { Write-Output "STATUS=FAILED;reason=chunk-count-`$(`$parts.Count)"; return }
`$sb = New-Object Text.StringBuilder
foreach (`$p in `$parts) { [void]`$sb.Append([IO.File]::ReadAllText(`$p.FullName)) }
[IO.File]::WriteAllBytes('$staged', [Convert]::FromBase64String(`$sb.ToString()))
`$h = (Get-FileHash '$staged' -Algorithm SHA256).Hash
if (`$h -ne '$($ctx.Sha)') { Write-Output "STATUS=FAILED;reason=hash-mismatch;got=`$h"; Remove-Item '$stage' -Recurse -Force; return }
Write-Output "STAGED=OK;sha256=`$h"
$inst
Remove-Item '$stage' -Recurse -Force -ErrorAction SilentlyContinue
"@
        }
        $out = Send $f
        $st = Marker $out 'STATUS'
        if ($st) { return Row (($st -replace '^STATUS=', '') -split ';' | Select-Object -First 1) $st }
        if ($out -match 'STAGED=OK') { return Row 'STAGED-OK' (($out -split "`n" | Select-Object -Last 3) -join ' | ') }
        return Row 'FAILED' "no STAGED=OK or STATUS= in output: $(($out -split "`n" | Select-Object -First 3) -join ' | ')"
    }
    catch { Row 'INVOKE-FAILED' "$_" }
}

$workerText = $worker.ToString()
$results = @($targets | ForEach-Object -ThrottleLimit $Throttle -Parallel {
    $sb = [scriptblock]::Create($using:workerText)
    & $sb $_ $using:ctx
})

$results | Export-Csv -Path $LogCsv -NoTypeInformation -Encoding utf8
Write-Host "`n--- Summary ---" -ForegroundColor White
$results | Group-Object Code | Sort-Object Count -Descending | Select-Object Count, Name | Format-Table -AutoSize
$results | Format-Table Vm, Code, Detail -AutoSize -Wrap
Write-Host "Log: $LogCsv"
$bad = @($results | Where-Object { $_.Code -in 'CHUNK-FAILED', 'INVOKE-FAILED', 'FAILED' })
if ($bad.Count) { Write-Error "$($bad.Count) VM(s) failed: $($bad.Vm -join ', '). Re-run for those names." -ErrorAction Continue; exit 1 }
