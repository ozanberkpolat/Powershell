<#
.SYNOPSIS
    Check, gracefully shut down, or resume a standalone on-premises Exchange server around maintenance.

.DESCRIPTION
    Runs INSIDE the Exchange server (Windows PowerShell 5.1, as administrator or SYSTEM through Run Command).
    The Exchange management snap-in is loaded explicitly, because Run Command starts a plain PowerShell.

    -Mode Check (default, read-only)
        Boot time, Exchange and IIS services, automatic services not running, databases mounted, server
        component states that are not Active, non-empty queues. Changes nothing.
    -Mode Shutdown
        For maintenance that needs the VM deallocated (OS disk resize, SKU change, host move):
          1. baseline (components, databases, volumes) to the evidence file
          2. HubTransport -> Draining, restart MSExchangeTransport, wait until the queues are empty
          3. ServerWideOffline -> Inactive
          4. dismount every database on this server
          5. eseutil /mh on every database file: every one must say "Clean Shutdown"
        Leaves the VM RUNNING: deallocate from Azure only after RESULT=CLEAN.
    -Mode Resume
        After the maintenance: mount databases, ServerWideOffline and HubTransport -> Active, restart
        transport, then verify (Test-ServiceHealth, components, databases, MAPI connectivity, queues,
        managed availability). Run Test-ExchangeEndpoints.ps1 afterwards for OWA/EWS/MAPI over HTTPS.

    Ends with one line RESULT=<code>;... and exit code 0 (good) or 1 (stop and look).

.PARAMETER Mode
    Check, Shutdown or Resume (string, so Run Command can pass it).
.PARAMETER DrainTimeoutMinutes
    How long to wait for the transport queues to drain. Default 15.
.PARAMETER ExpectedInactiveComponents
    Components that are Inactive by design and do not count as a problem. Default ForwardSyncDaemon,
    ProvisioningRps (both Inactive on on-premises servers).
.PARAMETER EvidencePath
    Log file. Default C:\Windows\Temp\exchange-<mode>-<timestamp>.txt.

.EXAMPLE
    ./Azure/Compute/Invoke-VmRunCommand.ps1 -VmName vm-exch-01 -ResourceGroup rg-mail -ScriptPath ./Exchange-OnPrem/Invoke-ExchangeGracefulShutdown.ps1

.EXAMPLE
    ./Azure/Compute/Invoke-VmRunCommand.ps1 -VmName vm-exch-01 -ResourceGroup rg-mail -ScriptPath ./Exchange-OnPrem/Invoke-ExchangeGracefulShutdown.ps1 `
        -Parameter @{ Mode = 'Shutdown' } -Method Managed -TimeoutSeconds 3600

.NOTES
    Role: Exchange Organization Management (or Server Management) in the guest; Run Command needs Virtual
    Machine Contributor (PIM). Exchange 2016/2019 on Windows Server.
    Traps kept from real use:
      - STANDALONE servers only. A DAG member must be put into maintenance with database copy moves
        (StartDagServerMaintenance.ps1, Redirect-Message) instead; this script refuses when a database
        has more than one copy.
      - Drain, do not stop: HubTransport Draining plus a transport restart lets queued mail finish. Messages
        still queued at the timeout persist on disk and deliver after the restart (a warning, not a failure).
        Poison and Shadow queues are excluded from the count.
      - Any failure before the dismount stops the run (nothing half done is followed by a dismount).
      - eseutil /mh must report "Clean Shutdown" for every database before deallocation. "Dirty Shutdown"
        means logs still need replay: do NOT deallocate; mount again or replay (eseutil /r <log prefix>).
      - Two components are Inactive by design on premises (ForwardSyncDaemon, ProvisioningRps); everything
        else must be Active after Resume.
      - Invoke-WebRequest against https://localhost/owa can fail on the .NET TLS stack while OWA is healthy;
        use Test-ExchangeEndpoints.ps1 (native curl.exe) for the HTTP checks.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Shutdown', 'Resume')][string]$Mode = 'Check',
    [int]$DrainTimeoutMinutes = 15,
    [string[]]$ExpectedInactiveComponents = @('ForwardSyncDaemon', 'ProvisioningRps'),
    [string]$EvidencePath = (Join-Path $env:SystemRoot ("Temp\exchange-{0}-{1}.txt" -f $Mode.ToLower(), (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
$srv = $env:COMPUTERNAME
New-Item -ItemType Directory -Force -Path (Split-Path $EvidencePath) | Out-Null

function Say([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Output $line
    Add-Content -Path $EvidencePath -Value $line -Encoding UTF8
}
function Dump([string]$label, $obj) {
    Say "=== $label ==="
    $t = ($obj | Out-String -Width 200).TrimEnd()
    if (-not $t) { $t = '(none)' }
    Write-Output $t
    Add-Content -Path $EvidencePath -Value $t -Encoding UTF8
}
function Result([string]$code, [string]$detail, [int]$exitCode) {
    $line = "RESULT=$code;host=$srv;mode=$Mode;evidence=$EvidencePath;$($detail -replace '[\r\n]', ' ')"
    Write-Output $line
    Add-Content -Path $EvidencePath -Value $line -Encoding UTF8
    exit $exitCode
}
function Get-BadComponents {
    @(Get-ServerComponentState -Identity $srv | Where-Object { $_.State -ne 'Active' -and $ExpectedInactiveComponents -notcontains $_.Component })
}
function Get-QueueDepth {
    $q = @(Get-Queue -Server $srv | Where-Object { $_.Identity -notlike '*\Poison*' -and $_.Identity -notlike '*\Shadow*' })
    $n = ($q | Measure-Object -Property MessageCount -Sum).Sum
    if ($null -eq $n) { 0 } else { [int]$n }
}

try {
    Say "Mode $Mode on $srv, evidence $EvidencePath"
    $os = Get-CimInstance Win32_OperatingSystem
    Say ('Boot {0:s}Z, now {1:s}Z' -f $os.LastBootUpTime.ToUniversalTime(), (Get-Date).ToUniversalTime())

    if ($Mode -eq 'Check') {
        # Services are readable even when the snap-in fails, so report them first.
        Dump 'EXCHANGE AND IIS SERVICES' (Get-Service | Where-Object { $_.Name -like 'MSExchange*' -or $_.Name -in 'W3SVC', 'WAS', 'HostControllerService', 'MSComplianceAudit' } |
            Sort-Object Name | Format-Table Name, Status, StartType -AutoSize)
        Dump 'AUTOMATIC SERVICES NOT RUNNING' (Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" | Format-Table Name, State, ExitCode -AutoSize)
    }

    Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue
    if (-not (Get-Command Get-MailboxDatabase -ErrorAction SilentlyContinue)) {
        Result 'FAILED' 'reason=exchange-snapin-not-loaded;nothing changed' 1
    }

    $dbs = @(Get-MailboxDatabase -Server $srv -Status)
    if ($dbs.Count -eq 0) { Result 'FAILED' 'reason=no-mailbox-database-on-this-server' 1 }

    switch ($Mode) {
        'Check' {
            Dump 'DATABASES' ($dbs | Format-Table Name, Mounted, DatabaseSize -AutoSize)
            $bad = Get-BadComponents
            Dump 'COMPONENTS NOT ACTIVE (excluding expected)' ($bad | Format-Table Component, State -AutoSize)
            Dump 'NON-EMPTY QUEUES' (Get-Queue -Server $srv | Where-Object MessageCount -gt 0 | Format-Table Identity, Status, MessageCount, LastError -AutoSize)
            $notMounted = @($dbs | Where-Object { -not $_.Mounted })
            if ($bad.Count -or $notMounted.Count) { Result 'ATTENTION' ("componentsNotActive={0};dbNotMounted={1}" -f $bad.Count, $notMounted.Count) 1 }
            Result 'HEALTHY' "databases=$($dbs.Count)" 0
        }

        'Shutdown' {
            $multi = @($dbs | Where-Object { @($_.DatabaseCopies).Count -gt 1 })
            if ($multi.Count) { Result 'REFUSED' "reason=dag-database-copies;db=$($multi.Name -join ',');use DAG maintenance instead" 1 }

            Dump 'BASELINE COMPONENTS' (Get-ServerComponentState -Identity $srv | Format-Table Component, State -AutoSize)
            Dump 'BASELINE DATABASES' ($dbs | Format-Table Name, Mounted, EdbFilePath -AutoSize)
            Dump 'BASELINE VOLUMES' (Get-Volume | Format-Table DriveLetter, FileSystemLabel, Size, SizeRemaining -AutoSize)

            Say 'HubTransport -> Draining, restarting MSExchangeTransport'
            Set-ServerComponentState -Identity $srv -Component HubTransport -State Draining -Requester Maintenance
            Restart-Service MSExchangeTransport -Force
            $deadline = (Get-Date).AddMinutes($DrainTimeoutMinutes)
            do {
                $n = Get-QueueDepth
                Say "Queue depth: $n"
                if ($n -eq 0) { break }
                Start-Sleep -Seconds 20
            } while ((Get-Date) -lt $deadline)
            if ($n -gt 0) { Say "WARNING: $n message(s) still queued after $DrainTimeoutMinutes min. They persist on disk and deliver after the restart." }

            Say 'ServerWideOffline -> Inactive'
            Set-ServerComponentState -Identity $srv -Component ServerWideOffline -State Inactive -Requester Maintenance

            foreach ($db in $dbs) {
                Say "Dismounting $($db.Name)"
                Dismount-Database -Identity $db.Name -Confirm:$false
            }

            $eseutil = Join-Path $env:ExchangeInstallPath 'Bin\eseutil.exe'
            if (-not (Test-Path $eseutil)) { Result 'FAILED' "reason=eseutil-not-found;path=$eseutil;databases dismounted" 1 }
            $dirty = @()
            foreach ($db in $dbs) {
                $edb = $db.EdbFilePath.PathName
                $hit = & $eseutil /mh "$edb" 2>&1 | Select-String -Pattern '^\s*State:'
                $state = if ($hit) { $hit[0].ToString().Trim() } else { 'State: UNKNOWN (no State line from eseutil)' }
                Say "$($db.Name) -> $state"
                if ($state -notmatch 'Clean Shutdown') { $dirty += $db.Name }
            }
            if ($dirty.Count) { Result 'DIRTY' "db=$($dirty -join ',');do NOT deallocate: mount again or replay logs" 1 }
            Result 'CLEAN' "databases=$($dbs.Count);queuedLeft=$n;safe to deallocate" 0
        }

        'Resume' {
            $failed = @()
            foreach ($db in $dbs | Where-Object { -not $_.Mounted }) {
                try { Mount-Database -Identity $db.Name -Confirm:$false; Say "Mounted $($db.Name)" }
                catch { Say "FAILED to mount $($db.Name): $($_.Exception.Message)"; $failed += $db.Name }
            }
            Say 'ServerWideOffline and HubTransport -> Active, restarting MSExchangeTransport'
            Set-ServerComponentState -Identity $srv -Component ServerWideOffline -State Active -Requester Maintenance
            Set-ServerComponentState -Identity $srv -Component HubTransport -State Active -Requester Maintenance
            Restart-Service MSExchangeTransport -Force
            Start-Sleep -Seconds 20

            $health = @(Test-ServiceHealth)
            Dump 'SERVICE HEALTH (RequiredServicesRunning must be True)' ($health | Format-Table Role, RequiredServicesRunning, ServicesNotRunning -AutoSize)
            $bad = Get-BadComponents
            Dump 'COMPONENTS NOT ACTIVE (excluding expected)' ($bad | Format-Table Component, State -AutoSize)
            $dbNow = @(Get-MailboxDatabase -Server $srv -Status)
            Dump 'DATABASES' ($dbNow | Format-Table Name, Mounted, DatabaseSize, AvailableNewMailboxSpace -AutoSize)
            $mapi = @(Test-MAPIConnectivity -Server $srv)
            Dump 'MAPI CONNECTIVITY' ($mapi | Format-Table Server, Database, Result, Error -AutoSize)
            Dump 'QUEUES' (Get-Queue -Server $srv | Format-Table Identity, DeliveryType, Status, MessageCount, LastError -AutoSize)
            Dump 'MANAGED AVAILABILITY NOT HEALTHY' (Get-ServerHealth -Identity $srv | Where-Object { $_.AlertValue -notin 'Healthy', 'Disabled' } | Format-Table HealthSetName, Name, AlertValue -AutoSize)

            $problems = @()
            if ($failed.Count) { $problems += "mountFailed=$($failed -join ',')" }
            if (@($dbNow | Where-Object { -not $_.Mounted }).Count) { $problems += 'dbNotMounted' }
            if (@($health | Where-Object { -not $_.RequiredServicesRunning }).Count) { $problems += 'servicesNotRunning' }
            if ($bad.Count) { $problems += "components=$($bad.Component -join ',')" }
            if (@($mapi | Where-Object { "$($_.Result)" -notmatch 'Success' }).Count) { $problems += 'mapiFailed' }
            if ($problems.Count) { Result 'ATTENTION' ($problems -join ';') 1 }
            Result 'RESUMED' "databases=$($dbNow.Count)" 0
        }
    }
}
catch {
    Say "ERROR: $($_.Exception.Message)"
    Result 'FAILED' "reason=$($_.Exception.Message)" 1
}
