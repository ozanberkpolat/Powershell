<#
.SYNOPSIS
    In-guest check and extend of a Windows partition (default C:) after its Azure managed disk was grown.

.DESCRIPTION
    Runs INSIDE the VM (Windows PowerShell 5.1, as administrator or SYSTEM through Run Command).

    -Mode Assess (default, read-only)
        Partition style (GPT/MBR), partitions in physical order, current and maximum supported size of the
        target partition, any partition that sits AFTER it (a Recovery partition there blocks the extend),
        WinRE status, pending reboot flags and the unallocated space. Run it before the resize to know
        whether the extend will work, and after it to confirm.
    -Mode Extend
        Rescans storage, waits until the new size is visible, refuses when a partition sits after the target,
        extends the partition to its maximum supported size and verifies the result.

    Prints a report and ends with one line:  RESULT=<OK|WOULD-GROW|NOTHING-TO-GROW|BLOCKED|FAILED>;key=value...
    Exit code 1 on BLOCKED or FAILED (visible with Invoke-VmRunCommand.ps1 -Method Managed).

    Typical Azure sequence (outside this script): pin the NIC private IP to Static, snapshot the OS disk,
    stop the workload gracefully, deallocate, grow the disk (Update-AzDisk / az disk update --size-gb),
    start, then run this with -Mode Extend.

.PARAMETER Mode
    Assess or Extend. A string, not a switch, because Run Command passes name/value pairs.
.PARAMETER DriveLetter
    Partition to extend. Default C.
.PARAMETER EvidencePath
    Text log of everything printed. Default C:\Windows\Temp\extend-partition-<timestamp>.txt.
.PARAMETER RescanWaitSeconds
    How long to wait for the rescan to show the new disk size. Default 60.

.EXAMPLE
    # From your workstation, read-only assessment on a VM
    ./Azure/Compute/Invoke-VmRunCommand.ps1 -VmName vm-app-01 -ResourceGroup rg-app -ScriptPath ./Windows/Extend-OsPartition.ps1

.EXAMPLE
    ./Azure/Compute/Invoke-VmRunCommand.ps1 -VmName vm-app-01 -ResourceGroup rg-app -ScriptPath ./Windows/Extend-OsPartition.ps1 `
        -Parameter @{ Mode = 'Extend' } -Method Managed

.EXAMPLE
    # Locally on the server
    .\Extend-OsPartition.ps1 -Mode Extend -DriveLetter C

.NOTES
    Role: local administrator in the guest. Through Run Command: Virtual Machine Contributor (PIM).
    Modules: Storage (built in). Works on Windows Server 2016 and later.
    Traps kept from real use:
      - NTFS only extends into ADJACENT unallocated space. A Recovery (WinRE) partition after C: blocks the
        extend. The fix is online and needs no second reboot, but only with a snapshot in place:
        reagentc /disable, diskpart (select disk N, select partition <recovery>, delete partition override),
        extend C:, then reagentc /enable (WinRE moves into C:). This script reports the blocker; it never
        deletes a partition.
      - The new size is not visible until the storage cache is rescanned (Update-HostStorageCache); right
        after start the rescan may lag, so the script waits and retries before calling "nothing to grow".
      - MBR caps a partition at 2 TB. Record the partition style either way.
      - "Cannot grow" after a resize is a failure, not a clean result: either the rescan has not landed or
        a partition is in the way.
      - Through Run Command keep the output short (4 KB limit on the classic invoke); the full report is in
        the evidence file.
#>
[CmdletBinding()]
param(
    [ValidateSet('Assess', 'Extend')][string]$Mode = 'Assess',
    [ValidatePattern('^[A-Za-z]$')][string]$DriveLetter = 'C',
    [string]$EvidencePath = (Join-Path $env:SystemRoot ("Temp\extend-partition-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [int]$RescanWaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $EvidencePath) | Out-Null

function Say([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Output $line
    Add-Content -Path $EvidencePath -Value $line -Encoding UTF8
}
function Dump([string]$label, $obj) {
    Say "=== $label ==="
    $t = ($obj | Out-String -Width 200).TrimEnd()
    Write-Output $t
    Add-Content -Path $EvidencePath -Value $t -Encoding UTF8
}
function Result([string]$code, [hashtable]$kv) {
    $parts = @("RESULT=$code", "host=$env:COMPUTERNAME", "mode=$Mode")
    foreach ($k in $kv.Keys) { $parts += ('{0}={1}' -f $k, ("$($kv[$k])" -replace '[\r\n;]', ' ')) }
    $line = $parts -join ';'
    Write-Output $line
    Add-Content -Path $EvidencePath -Value $line -Encoding UTF8
}
function GB($b) { [math]::Round($b / 1GB, 2) }

function Get-Layout {
    $p = Get-Partition -DriveLetter $DriveLetter
    $disk = Get-Disk -Number $p.DiskNumber
    $sup = Get-PartitionSupportedSize -DriveLetter $DriveLetter
    $end = $p.Offset + $p.Size
    $after = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Offset -ge $end } | Sort-Object Offset)
    [pscustomobject]@{ Part = $p; Disk = $disk; Max = $sup.SizeMax; After = $after; Growable = ($sup.SizeMax - $p.Size) }
}

try {
    Say "Mode $Mode, drive ${DriveLetter}:, evidence $EvidencePath"
    if ($Mode -eq 'Extend') {
        Say 'Rescanning storage (Update-HostStorageCache)'
        Update-HostStorageCache
    }

    $l = Get-Layout
    if ($Mode -eq 'Extend' -and $l.Growable -le 1GB -and $l.After.Count -eq 0) {
        # The rescan can lag right after start: wait before calling it "nothing to grow".
        $deadline = (Get-Date).AddSeconds($RescanWaitSeconds)
        while ((Get-Date) -lt $deadline -and $l.Growable -le 1GB) {
            Start-Sleep -Seconds 10
            Update-HostStorageCache
            $l = Get-Layout
        }
    }

    Dump 'DISK' ($l.Disk | Select-Object Number, PartitionStyle, @{ n = 'SizeGB'; e = { GB $_.Size } }, @{ n = 'AllocatedGB'; e = { GB $_.AllocatedSize } }, HealthStatus | Format-List)
    Dump 'PARTITIONS IN PHYSICAL ORDER' (Get-Partition -DiskNumber $l.Disk.Number | Sort-Object Offset |
        Select-Object PartitionNumber, Type, DriveLetter, @{ n = 'SizeMB'; e = { [math]::Round($_.Size / 1MB, 1) } }, @{ n = 'OffsetGB'; e = { [math]::Round($_.Offset / 1GB, 3) } } | Format-Table -AutoSize)
    Say ('{0}: current {1} GB, max supported {2} GB, growable {3} GB' -f $DriveLetter, (GB $l.Part.Size), (GB $l.Max), (GB $l.Growable))
    if ($l.Disk.PartitionStyle -eq 'MBR') { Say 'NOTE: MBR disk, a partition is capped at 2 TB.' }

    if ($Mode -eq 'Assess') {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # 5.1: native stderr under Stop would throw
        $winre = @(& reagentc.exe /info 2>&1 | ForEach-Object { "$_" })
        $ErrorActionPreference = $prev
        Dump 'WinRE' $winre
        $pend = [ordered]@{
            CbsRebootPending  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            WuRebootRequired  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            PendingFileRename = $null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        }
        Dump 'PENDING REBOOT' ([pscustomobject]$pend | Format-List)
    }

    $kv = @{ style = $l.Disk.PartitionStyle; sizeGB = (GB $l.Part.Size); maxGB = (GB $l.Max); evidence = $EvidencePath }
    if ($l.After.Count) {
        $b = ($l.After | ForEach-Object { '{0}:{1}:{2}MB' -f $_.PartitionNumber, $_.Type, [math]::Round($_.Size / 1MB) }) -join ','
        Say "BLOCKER: partition(s) after ${DriveLetter}: $b. Snapshot first, then reagentc /disable, delete the recovery partition with diskpart (delete partition override), extend, reagentc /enable."
        $kv.after = $b
        Result 'BLOCKED' $kv
        exit 1
    }

    if ($Mode -eq 'Assess') {
        if ($l.Growable -gt 1GB) { Result 'WOULD-GROW' $kv } else { Result 'NOTHING-TO-GROW' $kv }
        exit 0
    }

    if ($l.Growable -le 1GB) {
        Say "${DriveLetter}: cannot grow: the new space is not visible after ${RescanWaitSeconds}s or the disk was not resized."
        Result 'FAILED' ($kv + @{ reason = 'no-unallocated-space' })
        exit 1
    }
    Resize-Partition -DriveLetter $DriveLetter -Size $l.Max
    $after = Get-Layout
    Dump 'VOLUME' (Get-Volume -DriveLetter $DriveLetter | Select-Object DriveLetter, FileSystemLabel, @{ n = 'SizeGB'; e = { GB $_.Size } }, @{ n = 'FreeGB'; e = { GB $_.SizeRemaining } }, HealthStatus | Format-Table -AutoSize)
    if ($after.Part.Size -lt $l.Max - 1MB) {
        Result 'FAILED' ($kv + @{ reason = 'size-after-resize-below-max'; newGB = (GB $after.Part.Size) })
        exit 1
    }
    Result 'OK' ($kv + @{ newGB = (GB $after.Part.Size) })
    exit 0
}
catch {
    Say "ERROR: $($_.Exception.Message)"
    Result 'FAILED' @{ reason = $_.Exception.Message; evidence = $EvidencePath }
    exit 1
}
