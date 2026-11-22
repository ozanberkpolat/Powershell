#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.RecoveryServices, Az.Compute, Az.Network
<#
.SYNOPSIS
    Restore-test an Azure Backup VM into an isolated subnet, collect evidence, and clean up afterwards.

.DESCRIPTION
    Proves that a backup restores into a working machine. One run does, in the order that matters:

      0. Pre-checks: vault, backup item, recovery point, isolated subnet exists and holds only machines you expect.
      1. Restore: restore-disks with a new VM into the isolated subnet (Restore-AzRecoveryServicesBackupItem creates the VM).
         If -NicNsgId is given, that NSG is attached to the restored NIC the moment the NIC resource appears, BEFORE the machine
         boots, so a restored production system cannot reach production storage or the internet in its first minutes.
      2. Boot diagnostics: PATCHed on as soon as the VM resource exists. A restore does NOT carry boot diagnostics over, even when the
         source has it. Doing it early means no restart is needed later; a restart makes pending Windows updates from the source
         install, which then has to be recorded as a deviation.
      3. Wait for the guest agent to report Ready (it proves the platform channel works).
      4. Evidence: console screenshot (retried until a frame is not black) and serial log from boot diagnostics, saved to the evidence folder.
      5. Access (skip with -SkipAccess): local account with a password set through Run Command (protected parameter), Network Level
         Authentication switched off on Windows (no domain controller is reachable in isolation, so RDP would fail before asking for a
         password), password SSH enabled on Linux, services matching -StopServicePattern stopped and disabled so the copy does not start
         the source's scheduled work.
      6. Checks: disk caching and LUNs compared with the source (a mismatch is silent and shows up later as a slow database), private IP,
         optional TCP probe of RDP or SSH.
      7. Protocol values: every timestamp (UTC), restore job id, recovery point id, address, evidence paths, and a JSON file.

    Cleanup mode (-Cleanup -TargetVmName <name>) deletes the restored VM, its disks and NICs after sign-off and verifies that the isolated
    subnet is empty again. Guarded by ShouldProcess.

.PARAMETER Vault
    Recovery Services vault name.
.PARAMETER VaultResourceGroup
    Vault resource group.
.PARAMETER SourceVm
    Name of the protected source VM.
.PARAMETER SourceVmResourceGroup
    Resource group of the source VM.
.PARAMETER RecoveryPointId
    Recovery point ID (the numeric ID at the end of the recovery point path). Omit to list the available points and stop.
.PARAMETER TargetResourceGroup
    Resource group for the restored machine (a dedicated restore-test group).
.PARAMETER TargetVnetName
    Isolated virtual network.
.PARAMETER TargetVnetResourceGroup
    Its resource group.
.PARAMETER TargetSubnetName
    Isolated subnet.
.PARAMETER StagingStorageAccount
    Storage account for the restore staging (same region as the vault; LRS or ZRS, not a premium or ASR cache account you care about).
.PARAMETER StagingStorageAccountResourceGroup
    Its resource group.
.PARAMETER RestoreDateTag
    yyyyMMdd tag used in the restored VM name. Default: the date of the recovery point.
.PARAMETER TargetVmName
    Restored VM name. Default rst-<source short name>-<tag>.
.PARAMETER NicNsgId
    Resource ID of an NSG to attach to the restored NIC before boot.
.PARAMETER LocalAccount
    Local account to provision. Default rstadmin.
.PARAMETER StopServicePattern
    Regex of service names (Windows) or enabled unit files (Linux) to stop and disable on the restored copy, for example 'oracle|crond|scheduler'.
.PARAMETER SkipAccess
    Do not provision access (evidence only).
.PARAMETER EvidenceFolder
    Default ./restore-test-evidence
.PARAMETER Cleanup
    Delete a restored machine (needs -TargetVmName, -TargetResourceGroup and the isolated subnet parameters).

.EXAMPLE
    ./Invoke-RestoreTest.ps1 -Vault rsv-backup -VaultResourceGroup rg-mgmt -SourceVm vm-app-01 -SourceVmResourceGroup rg-app `
        -TargetResourceGroup rg-restoretest -TargetVnetName vnet-isolated -TargetVnetResourceGroup rg-restoretest -TargetSubnetName snet-isolated `
        -StagingStorageAccount stagingrestore01 -StagingStorageAccountResourceGroup rg-restoretest      # lists recovery points

.EXAMPLE
    ./Invoke-RestoreTest.ps1 ...same parameters... -RecoveryPointId 1234567890123456789 -NicNsgId $nsgId -StopServicePattern 'scheduler|cron'

.EXAMPLE
    ./Invoke-RestoreTest.ps1 -Cleanup -TargetVmName rst-app-01-20260101 -TargetResourceGroup rg-restoretest -TargetVnetName vnet-isolated `
        -TargetVnetResourceGroup rg-restoretest -TargetSubnetName snet-isolated -WhatIf

.NOTES
    Roles (activate PIM first; this script writes): Backup Operator on the vault (restore), Contributor on the target resource group,
    Virtual Machine Contributor (Run Command), Network Contributor for the NIC NSG, Storage Account Contributor on the staging account.
    Modules: Az.Accounts, Az.RecoveryServices (Restore-AzRecoveryServicesBackupItem with -TargetVMName needs a recent version),
    Az.Compute, Az.Network.
    Traps kept:
      - Boot diagnostics are dropped by the restore: PATCH diagnosticsProfile.bootDiagnostics.enabled = true right away; do NOT restart.
      - The console returns a fully black frame once the display idles. A Linux console is white text on black, so judge a frame by the number
        of clearly lit pixels, not by mean brightness (the mean discarded valid frames). On Windows the first frames after boot often show
        "Working on updates": that is expected for a restored machine; wait, then capture, and note it in the protocol.
      - The serial log of a Windows guest carries the hourly health report; the first one can take up to an hour.
      - The restored machine carries production monitoring and backup agents and, if it can reach it, production storage. Attach -NicNsgId
        before boot and confirm the subnet NSG denies Storage and Internet outbound. Stop the source's scheduled jobs (-StopServicePattern).
      - Restored domain controllers answer as domain controllers of the production domain: isolate inbound too and set the VNet DNS to the
        isolated DC once it is up.
      - Restore time scales with data: plan about 36 minutes for 384 GB; a multi-terabyte database server should be started first and left alone.
      - Recovery points expire (30 days on a daily policy): work oldest first.
      - Compare disk caching AND LUN numbers with the source: on Linux device names follow attach order, so a changed LUN moves mount points.
        Fixing caching needs a deallocate, so do it before handover.
      - Isolated clients must have a route to the subnet: if the VPN split tunnel does not advertise the isolated range, nobody can reach the
        machine, and clients that are already connected must reconnect to learn new routes.
      - The generated password is written to <evidence>/<vm>.handover.txt, outside any script text. Hand it over separately and delete the file.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Restore')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Restore')][string]$Vault,
    [Parameter(Mandatory, ParameterSetName = 'Restore')][string]$VaultResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'Restore')][string]$SourceVm,
    [Parameter(Mandatory, ParameterSetName = 'Restore')][string]$SourceVmResourceGroup,
    [Parameter(ParameterSetName = 'Restore')][string]$RecoveryPointId,
    [Parameter(Mandatory, ParameterSetName = 'Restore')][string]$StagingStorageAccount,
    [Parameter(Mandatory, ParameterSetName = 'Restore')][string]$StagingStorageAccountResourceGroup,
    [Parameter(ParameterSetName = 'Restore')][string]$RestoreDateTag,
    [Parameter(ParameterSetName = 'Restore')][string]$NicNsgId,
    [Parameter(ParameterSetName = 'Restore')][string]$LocalAccount = 'rstadmin',
    [Parameter(ParameterSetName = 'Restore')][string]$StopServicePattern,
    [Parameter(ParameterSetName = 'Restore')][switch]$SkipAccess,

    [Parameter(Mandatory, ParameterSetName = 'Cleanup')][switch]$Cleanup,
    [Parameter(ParameterSetName = 'Restore')][Parameter(Mandatory, ParameterSetName = 'Cleanup')][string]$TargetVmName,

    [Parameter(Mandatory)][string]$TargetResourceGroup,
    [Parameter(Mandatory)][string]$TargetVnetName,
    [Parameter(Mandatory)][string]$TargetVnetResourceGroup,
    [Parameter(Mandatory)][string]$TargetSubnetName,
    [string]$EvidenceFolder = './restore-test-evidence'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first (and activate PIM).' }
$sub = (Get-AzContext).Subscription.Id
New-Item -ItemType Directory -Path $EvidenceFolder -Force | Out-Null
$vmApi = '2024-07-01'
$log = [ordered]@{}
function Stamp([string]$key) { $t = (Get-Date).ToUniversalTime(); $script:log[$key] = $t; Write-Host ('  {0}  {1}' -f $t.ToString('HH:mm:ss'), $key) }

function Get-SubnetOccupants {
    $s = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork (Get-AzVirtualNetwork -Name $TargetVnetName -ResourceGroupName $TargetVnetResourceGroup) -Name $TargetSubnetName
    @($s.IpConfigurations | ForEach-Object { $_.Id })
}

# ======================= CLEANUP ==========================================================
if ($PSCmdlet.ParameterSetName -eq 'Cleanup') {
    $vm = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $TargetVmName -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM $TargetVmName not found in $TargetResourceGroup." }
    if ($TargetVmName -notlike 'rst-*') { throw "Refusing to delete '$TargetVmName': restored test machines are named rst-*." }
    $disks = @($vm.StorageProfile.OsDisk.Name) + @($vm.StorageProfile.DataDisks.Name)
    $nics = @($vm.NetworkProfile.NetworkInterfaces.Id)
    Write-Host "Will delete VM $TargetVmName, disks: $($disks -join ', '), NICs: $(($nics | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
    if ($PSCmdlet.ShouldProcess($TargetVmName, 'Delete restored VM, its disks and NICs')) {
        Remove-AzVM -ResourceGroupName $TargetResourceGroup -Name $TargetVmName -Force | Out-Null
        foreach ($n in $nics) { Remove-AzNetworkInterface -ResourceGroupName $TargetResourceGroup -Name (Split-Path $n -Leaf) -Force }
        foreach ($d in $disks) { Remove-AzDisk -ResourceGroupName $TargetResourceGroup -DiskName $d -Force | Out-Null }
        Write-Host 'Deleted.' -ForegroundColor Green
        $left = Get-SubnetOccupants
        if ($left.Count) { Write-Warning "Isolated subnet still holds $($left.Count) IP configuration(s):`n  $($left -join "`n  ")" } else { Write-Host 'Isolated subnet is empty again.' -ForegroundColor Green }
    }
    return
}

# ======================= RESTORE ==========================================================
# 0. pre-checks
$vaultObj = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroup -Name $Vault
if (-not $vaultObj) { throw "Vault $Vault not found." }
$container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $SourceVm -ResourceGroupName $SourceVmResourceGroup -VaultId $vaultObj.ID | Select-Object -First 1
if (-not $container) { throw "No backup container for $SourceVm in $SourceVmResourceGroup in vault $Vault." }
$item = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $vaultObj.ID
if (-not $item) { throw "No backup item for $SourceVm." }
$points = @(Get-AzRecoveryServicesBackupRecoveryPoint -Item $item -VaultId $vaultObj.ID | Sort-Object RecoveryPointTime -Descending)
if (-not $points.Count) { throw "No recovery points for $SourceVm." }
if (-not $RecoveryPointId) {
    $points | Select-Object @{ n = 'RecoveryPointId'; e = { ($_.RecoveryPointId -split '/')[-1] } }, RecoveryPointTime, RecoveryPointType | Format-Table -AutoSize
    Write-Host 'Pass -RecoveryPointId to restore. Nothing was changed.'
    return
}
$rp = $points | Where-Object { ($_.RecoveryPointId -split '/')[-1] -eq $RecoveryPointId } | Select-Object -First 1
if (-not $rp) { throw "Recovery point $RecoveryPointId not found." }
if (-not $RestoreDateTag) { $RestoreDateTag = $rp.RecoveryPointTime.ToUniversalTime().ToString('yyyyMMdd') }
$shortName = ($SourceVm -split '-')[-1]
if (-not $TargetVmName) { $TargetVmName = "rst-$shortName-$RestoreDateTag".ToLower() }
$srcVm = Get-AzVM -ResourceGroupName $SourceVmResourceGroup -Name $SourceVm
$isLinux = ($srcVm.StorageProfile.OsDisk.OsType -eq 'Linux')
$occupants = Get-SubnetOccupants
Write-Host "=== $TargetVmName ($(if ($isLinux) { 'Linux' } else { 'Windows' })) ===" -ForegroundColor Cyan
Write-Host "Recovery point $RecoveryPointId ($($rp.RecoveryPointTime.ToUniversalTime().ToString('u')))"
Write-Host "Isolated subnet currently holds $($occupants.Count) IP configuration(s)" $(if ($occupants.Count) { ': ' + (($occupants | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') })
if (-not $PSCmdlet.ShouldProcess($TargetVmName, "Restore $SourceVm from recovery point $RecoveryPointId into $TargetSubnetName")) { return }

# 1. restore
Stamp 'restore submitted'
$job = Restore-AzRecoveryServicesBackupItem -RecoveryPoint $rp -StorageAccountName $StagingStorageAccount -StorageAccountResourceGroupName $StagingStorageAccountResourceGroup `
    -TargetResourceGroupName $TargetResourceGroup -VaultId $vaultObj.ID -VaultLocation $vaultObj.Location `
    -TargetVMName $TargetVmName -TargetVNetName $TargetVnetName -TargetVNetResourceGroup $TargetVnetResourceGroup -TargetSubnetName $TargetSubnetName
Write-Host "  job $($job.JobId)"
$vmId = "/subscriptions/$sub/resourceGroups/$TargetResourceGroup/providers/Microsoft.Compute/virtualMachines/$TargetVmName"

# 2. while the job runs: NSG on the NIC and boot diagnostics, the moment each resource exists
$diagOn = $false; $nsgOn = -not $NicNsgId; $done = $false
$bootBody = @{ properties = @{ diagnosticsProfile = @{ bootDiagnostics = @{ enabled = $true } } } }
while (-not $done) {
    $j = Get-AzRecoveryServicesBackupJob -JobId $job.JobId -VaultId $vaultObj.ID
    if ($j.Status -ne 'InProgress') { $done = $true; Write-Host "  job $($j.Status)" ; if ($j.Status -ne 'Completed') { throw "Restore job ended as $($j.Status): $(($j.ErrorDetails | ForEach-Object { $_.ErrorMessage }) -join '; ')" } }
    if (-not $nsgOn) {
        $nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$TargetVmName*" } | Select-Object -First 1
        if ($nic) {
            $nic.NetworkSecurityGroup = [Microsoft.Azure.Commands.Network.Models.PSNetworkSecurityGroup]@{ Id = $NicNsgId }
            $nic | Set-AzNetworkInterface | Out-Null
            $nsgOn = $true; Stamp 'NIC security group attached'
        }
    }
    if (-not $diagOn) {
        $exists = Invoke-ArmRequest -Path "${vmId}?api-version=$vmApi" -IgnoreNotFound
        if ($exists) {
            try { [void](Invoke-ArmRequest -Method PATCH -Path "${vmId}?api-version=$vmApi" -Body $bootBody); $diagOn = $true; Stamp 'boot diagnostics enabled' }
            catch { Write-Verbose "boot diagnostics PATCH not accepted yet: $_" }
        }
    }
    if (-not $done) { Start-Sleep -Seconds 30 }
}
if (-not $diagOn) { [void](Invoke-ArmRequest -Method PATCH -Path "${vmId}?api-version=$vmApi" -Body $bootBody); Stamp 'boot diagnostics enabled (after job)' }
if (-not $nsgOn) { throw 'The NIC never appeared, so -NicNsgId was NOT attached. Attach it manually before anyone uses the machine.' }
Stamp 'restore completed'

# 3. guest agent
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    $iv = Invoke-ArmRequest -Path "$vmId/instanceView?api-version=$vmApi"
    if ($iv.vmAgent.statuses[0].displayStatus -eq 'Ready') { $ready = $true; Stamp 'guest agent ready'; break }
    Start-Sleep -Seconds 30
}
if (-not $ready) { Write-Warning 'Guest agent did not report Ready in 20 minutes; access provisioning and Run Command steps will fail.' }
$nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup | Where-Object { $_.Name -like "$TargetVmName*" } | Select-Object -First 1
$privateIp = $nic.IpConfigurations[0].PrivateIpAddress

# 4. console screenshot (retry until a frame is not black) and serial log
function Get-BootUris {
    $r = Invoke-ArmRequest -Method POST -Path "$vmId/retrieveBootDiagnosticsData?sasUriExpirationTimeInMinutes=10&api-version=$vmApi"
    $r
}
$shot = Join-Path $EvidenceFolder "$TargetVmName-console.bmp"
$haveShot = $false
$canDraw = $false; try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop; $canDraw = [bool]('System.Drawing.Bitmap' -as [type]) } catch { $canDraw = $false }
if (-not $canDraw) { Write-Warning 'System.Drawing is not available: the first console frame is kept without a black-frame check.' }
for ($i = 1; $i -le 12 -and -not $haveShot; $i++) {
    try {
        $u = Get-BootUris
        if ($u.consoleScreenshotBlobUri -like 'http*') {
            $tmp = Join-Path $EvidenceFolder 'probe.bmp'
            Invoke-WebRequest -Uri $u.consoleScreenshotBlobUri -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            $lit = 21
            if ($canDraw) {
                $bm = [System.Drawing.Bitmap]::new($tmp); $lit = 0
                for ($x = 0; $x -lt $bm.Width; $x += 4) { for ($y = 0; $y -lt $bm.Height; $y += 4) { $p = $bm.GetPixel($x, $y); if (($p.R + $p.G + $p.B) -gt 150) { $lit++ } } }
                $bm.Dispose()
            }
            # Count clearly lit pixels: a Linux console is white text on black, its MEAN brightness is under 1 even when legible.
            if ($lit -gt 20) { Move-Item $tmp $shot -Force; $haveShot = $true; Stamp 'console screenshot captured' }
        }
    } catch { Write-Verbose "screenshot attempt $i failed: $_" }
    if (-not $haveShot) { Start-Sleep -Seconds 20 }
}
if (-not $haveShot) { Write-Warning 'No non-black console frame captured. Retry later; the display may be asleep.' }
$serial = Join-Path $EvidenceFolder "$TargetVmName-serial.log"
try { $u = Get-BootUris; if ($u.serialConsoleLogBlobUri -like 'http*') { Invoke-WebRequest -Uri $u.serialConsoleLogBlobUri -OutFile $serial -UseBasicParsing; Stamp 'serial log captured' } } catch { Write-Warning "Serial log not captured: $_" }

# 5. access
$handover = Join-Path $EvidenceFolder "$TargetVmName.handover.txt"
if (-not $SkipAccess) {
    $pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }); $pw += '!9aZ'
    $runner = Join-Path $PSScriptRoot '../Compute/Invoke-VmRunCommand.ps1'
    if ($isLinux) {
        $script = @'
id "$Account" >/dev/null 2>&1 || useradd -m "$Account"
echo "$Account:$Pw" | chpasswd
usermod -aG wheel "$Account" 2>/dev/null || usermod -aG sudo "$Account" 2>/dev/null || true
sed -i 's/^ *PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl reload sshd 2>/dev/null || systemctl reload ssh
if [ -n "$StopPattern" ]; then
  for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager | awk '{print $1}' | grep -Ei "$StopPattern"); do
    systemctl disable --now "$u" >/dev/null 2>&1 && echo "stopped $u"
  done
fi
sshd -T | grep -i passwordauthentication
'@
    } else {
        $script = @'
param([string]$Account, [string]$Pw, [string]$StopPattern)
$ErrorActionPreference = 'Stop'
$sec = ConvertTo-SecureString $Pw -AsPlainText -Force
if (Get-LocalUser -Name $Account -ErrorAction SilentlyContinue) { Set-LocalUser -Name $Account -Password $sec; Enable-LocalUser -Name $Account }
else { New-LocalUser -Name $Account -Password $sec -PasswordNeverExpires | Out-Null; Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $Account }   # S-1-5-32-544 = local Administrators
# No domain controller is reachable in isolation: without this RDP fails before it asks for a password.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 0
if ($StopPattern) {
    $s = Get-Service | Where-Object { $_.Name -match $StopPattern -or $_.DisplayName -match $StopPattern }
    foreach ($x in $s) { Stop-Service -Name $x.Name -Force -ErrorAction SilentlyContinue; Set-Service -Name $x.Name -StartupType Disabled -ErrorAction SilentlyContinue }
    'services stopped: ' + (($s | Select-Object -ExpandProperty Name) -join ', ')
}
'access provisioned for ' + $Account
'@
    }
    $r = & $runner -ResourceId $vmId -OsType $(if ($isLinux) { 'Linux' } else { 'Windows' }) -Method Managed -Script $script `
            -Parameter @{ Account = $LocalAccount; StopPattern = "$StopServicePattern" } -ProtectedParameter @{ Pw = $pw } `
            -EvidenceFolder (Join-Path $EvidenceFolder 'run-command') -PassThru
    if (@($r)[0].State -ne 'Succeeded') { throw "Access provisioning failed: $(@($r)[0].Error). See $(@($r)[0].Evidence)" }
    Stamp 'interactive logon enabled'
    Set-Content -Path $handover -Encoding utf8 -Value "system  : $TargetVmName`naddress : $privateIp`naccount : $LocalAccount`npassword: $pw`n(hand over separately, then delete this file)"
}

# 6. disk configuration against the source
function Get-DiskView($vm) {
    [pscustomobject]@{ Os = "$($vm.StorageProfile.OsDisk.Caching)"; Data = @($vm.StorageProfile.DataDisks | Sort-Object Lun | ForEach-Object { [pscustomobject]@{ Lun = $_.Lun; Caching = "$($_.Caching)"; Gb = $_.DiskSizeGB } }) }
}
$src = Get-DiskView $srcVm
$dst = Get-DiskView (Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $TargetVmName)
Write-Host "`n--- disk configuration ---" -ForegroundColor Cyan
Write-Host ('  OS disk caching  source {0}  restored {1}' -f $src.Os, $dst.Os)
$mismatch = @(); if ($src.Os -ne $dst.Os) { $mismatch += 'OS disk caching' }
foreach ($d in $src.Data) {
    $r = $dst.Data | Where-Object Lun -eq $d.Lun
    $flag = ''
    if (-not $r) { $flag = '   MISSING'; $mismatch += "LUN $($d.Lun) missing" } elseif ($r.Caching -ne $d.Caching) { $flag = '   MISMATCH'; $mismatch += "LUN $($d.Lun) caching" }
    Write-Host ('  LUN {0,-3} {1,6} GB  source {2,-10} restored {3,-10}{4}' -f $d.Lun, $d.Gb, $d.Caching, $(if ($r) { $r.Caching } else { '-' }), $flag)
}
if ($dst.Data.Count -ne $src.Data.Count) { $mismatch += "data disk count $($src.Data.Count) vs $($dst.Data.Count)" }
if ($mismatch.Count) { Write-Warning ("Disk configuration differs from the source: {0}. Fix before handover; changing caching needs a deallocate." -f ($mismatch -join ', ')) } else { Write-Host '  matches source' -ForegroundColor Green }

# 7. reachability (informational: from an AVD session the isolated range may be unreachable by design)
$port = if ($isLinux) { 22 } else { 3389 }
$probe = Test-NetConnection -ComputerName $privateIp -Port $port -WarningAction SilentlyContinue -InformationLevel Quiet
Write-Host ("  TCP {0} on {1} from here: {2}" -f $port, $privateIp, $(if ($probe) { 'open' } else { 'not reachable (check routes/NSG, or you are outside the isolated network)' }))

# 8. values for the protocol
$result = [ordered]@{ TargetVm = $TargetVmName; Address = $privateIp; RestoreJobId = $job.JobId; RecoveryPointId = $RecoveryPointId
    RecoveryPointTimeUtc = $rp.RecoveryPointTime.ToUniversalTime().ToString('o'); Screenshot = $(if ($haveShot) { $shot }); SerialLog = $serial
    DiskMismatch = $mismatch; Timestamps = @($log.GetEnumerator() | ForEach-Object { @{ $_.Key = $_.Value.ToString('o') } }) }
$result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $EvidenceFolder "$TargetVmName.result.json") -Encoding utf8
Write-Host "`n--- values for the protocol (UTC) ---" -ForegroundColor Cyan
$log.GetEnumerator() | ForEach-Object { '  {0,-34} {1}' -f $_.Key, $_.Value.ToString('yyyy-MM-dd HH:mm:ss') }
"`n  restored system   : $TargetVmName`n  address           : $privateIp`n  restore job id    : $($job.JobId)`n  recovery point id : $RecoveryPointId"
if (-not $SkipAccess) { "  credentials       : $handover (hand over separately, then delete)" }
"  screenshot        : $(if ($haveShot) { $shot } else { 'NOT CAPTURED' })`n  serial log        : $serial"
if (-not $haveShot -or $mismatch.Count) { exit 1 }
