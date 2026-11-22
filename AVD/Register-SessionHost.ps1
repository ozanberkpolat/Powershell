#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Re-register an AVD session host with a host pool: remove the stale record, issue a registration token, re-register the agent, verify, revoke the token.

.DESCRIPTION
    For a session host that shows Unavailable or never became Available, typically because it registered under its short name before
    domain join (or was rebuilt) and the old record keeps the identity:

      1. Finds session host records of the pool that belong to the VM (by VM resource ID or by name, short or FQDN) and shows their status.
      2. Removes the stale records (those not Available; -RemoveAvailable to include a healthy one). Guarded by ShouldProcess.
      3. Issues a registration token on the host pool (PATCH registrationInfo, Update operation, default lifetime 24 hours).
      4. In the guest, through Run Command with the token as a PROTECTED parameter (never in the script text, evidence or Activity Log):
         writes RegistrationToken, sets IsRegistered to 0, restarts RDAgentBootLoader, waits until IsRegistered is 1.
      5. Polls the host pool until the VM has a session host record with status Available (default 10 minutes); fails otherwise.
      6. Revokes the registration token (Delete operation) unless -KeepToken.

    The RDAgent and RDAgentBootLoader must already be installed on the guest. If the registry key is missing the guest step fails with
    a clear message; reinstall the agents (Remote Desktop Services Infrastructure Agent and Boot Loader) using a fresh token as the
    REGISTRATIONTOKEN property of the MSI.

.PARAMETER HostPoolName
    Host pool name.
.PARAMETER HostPoolResourceGroup
    Host pool resource group.
.PARAMETER HostPoolSubscription
    Host pool subscription ID. Default: current context.
.PARAMETER VmName
    The session host VM (name).
.PARAMETER VmResourceGroup
    VM resource group.
.PARAMETER VmSubscription
    VM subscription. Default: the host pool subscription.
.PARAMETER TokenLifetimeHours
    Token validity, 1 to 696 hours (the API maximum is 27 days). Default 24.
.PARAMETER RemoveAvailable
    Also remove a record that is currently Available.
.PARAMETER KeepToken
    Do not revoke the token at the end.
.PARAMETER WaitMinutes
    How long to wait for Available. Default 10.

.EXAMPLE
    ./Register-SessionHost.ps1 -HostPoolName hp-pooled-01 -HostPoolResourceGroup rg-avd -VmName vm-avd-01 -VmResourceGroup rg-avd-compute -WhatIf

.NOTES
    Roles: Desktop Virtualization Host Pool Contributor (hostpool and sessionHosts write/delete) and Virtual Machine Contributor
    (Run Command) on the VM. Activate PIM first. Modules: Az.Accounts.
    Traps kept:
      - A record created before domain join stays under the short name; the re-registered host appears under the FQDN. The old record
        is what stays Unavailable and must be deleted (DELETE sessionHosts/<name>?force=true).
      - Do not leave a long-lived token on the pool: revoke it after the host is Available.
      - The token must be written to the registry value RegistrationToken together with IsRegistered=0, then RDAgentBootLoader restarted
        (the boot loader reads it); restarting RDAgent alone does nothing.
      - The guest script receives the token as a parameter. It never echoes it.
      - Entra-joined hosts that must enrol in Intune need the session host registered in a host pool first (multi-session enrolment);
        check enrolment after this step.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$HostPoolName,
    [Parameter(Mandatory)][string]$HostPoolResourceGroup,
    [string]$HostPoolSubscription,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$VmResourceGroup,
    [string]$VmSubscription,
    [ValidateRange(1, 696)][int]$TokenLifetimeHours = 24,
    [switch]$RemoveAvailable,
    [switch]$KeepToken,
    [int]$WaitMinutes = 10
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Azure/Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
if (-not $HostPoolSubscription) { $HostPoolSubscription = (Get-AzContext).Subscription.Id }
if (-not $VmSubscription) { $VmSubscription = $HostPoolSubscription }
$api = '2024-04-03'
$hp = "/subscriptions/$HostPoolSubscription/resourceGroups/$HostPoolResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
$vmId = "/subscriptions/$VmSubscription/resourceGroups/$VmResourceGroup/providers/Microsoft.Compute/virtualMachines/$VmName"

# sanity: both exist
$pool = Invoke-ArmRequest -Path "${hp}?api-version=$api"
$vm = Invoke-ArmRequest -Path "${vmId}?api-version=2024-07-01"
Write-Host "Host pool: $($pool.name) ($($pool.properties.hostPoolType)), VM: $($vm.name)" -ForegroundColor Cyan

function Get-VmRecords {
    $all = @(Invoke-Arm -Path "$hp/sessionHosts" -ApiVersion $api | Where-Object { $_ })
    @($all | Where-Object {
        $leaf = ($_.name -split '/')[-1]
        ($_.properties.resourceId -and $_.properties.resourceId -ieq $vmId) -or $leaf -ieq $VmName -or $leaf -like "$VmName.*"
    })
}

# 1-2. stale records
$records = Get-VmRecords
if ($records.Count) { $records | ForEach-Object { [pscustomobject]@{ Record = ($_.name -split '/')[-1]; Status = $_.properties.status; LastHeartbeat = $_.properties.lastHeartBeat; Sessions = $_.properties.sessions } } | Format-Table -AutoSize }
else { Write-Host 'No existing session host record for this VM.' }
foreach ($r in $records) {
    $leaf = ($r.name -split '/')[-1]
    if ($r.properties.status -eq 'Available' -and -not $RemoveAvailable) { Write-Host "Keeping $leaf (Available)." -ForegroundColor DarkGray; continue }
    if ($PSCmdlet.ShouldProcess("$HostPoolName/$leaf", 'Delete session host record')) {
        [void](Invoke-ArmRequest -Method DELETE -Path "$hp/sessionHosts/${leaf}?force=true&api-version=$api")
        Write-Host "Removed record $leaf" -ForegroundColor Yellow
    }
}

# 3. token
$token = $null
if ($PSCmdlet.ShouldProcess($HostPoolName, "Issue registration token ($TokenLifetimeHours h)")) {
    $exp = (Get-Date).ToUniversalTime().AddHours($TokenLifetimeHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $resp = Invoke-ArmRequest -Method PATCH -Path "${hp}?api-version=$api" -Body @{ properties = @{ registrationInfo = @{ expirationTime = $exp; registrationTokenOperation = 'Update' } } }
    $token = $resp.properties.registrationInfo.token
    if (-not $token) {
        $tr = Invoke-ArmRequest -Method POST -Path "$hp/retrieveRegistrationToken?api-version=$api"
        $token = $tr.token
    }
    if (-not $token) { throw 'No registration token returned by the host pool.' }
} else { Write-Host 'WhatIf: would issue a token, re-register the agent in the guest, wait for Available and revoke the token.'; return }

try {
    # 4. guest
    $guest = @'
param([string]$RegistrationToken)
$ErrorActionPreference = 'Stop'
$k = 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
if (-not (Test-Path $k)) { Write-Output 'FAILED: RDInfraAgent registry key missing, the AVD agent is not installed.'; exit 2 }
if (-not $RegistrationToken) { Write-Output 'FAILED: no token received.'; exit 3 }
Set-ItemProperty -Path $k -Name RegistrationToken -Value $RegistrationToken
Set-ItemProperty -Path $k -Name IsRegistered -Value 0
Restart-Service RDAgentBootLoader -Force
$ok = $false
for ($i = 0; $i -lt 18; $i++) { Start-Sleep -Seconds 10; if ((Get-ItemProperty $k).IsRegistered -eq 1) { $ok = $true; break } }
'IsRegistered=' + (Get-ItemProperty $k).IsRegistered
Get-Service RDAgentBootLoader, RdAgent -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + '=' + $_.Status }
if (-not $ok) { Write-Output 'FAILED: IsRegistered did not become 1 within 3 minutes.'; exit 1 }
'@
    $rc = & (Join-Path $PSScriptRoot '../Azure/Compute/Invoke-VmRunCommand.ps1') -ResourceId $vmId -OsType Windows -Method Managed -Script $guest `
            -ProtectedParameter @{ RegistrationToken = $token } -TimeoutSeconds 600 -EvidenceFolder './avd-register-evidence' -PassThru
    $rc = @($rc)[0]
    Get-Content (Join-Path $rc.Evidence 'stdout.txt') | Write-Host
    if ($rc.State -ne 'Succeeded') { throw "Guest registration failed: state $($rc.State), exit $($rc.ExitCode). $($rc.Error)" }

    # 5. wait for Available
    $deadline = (Get-Date).AddMinutes($WaitMinutes); $ok = $false
    while ((Get-Date) -lt $deadline) {
        $now = Get-VmRecords
        $avail = @($now | Where-Object { $_.properties.status -eq 'Available' })
        if ($avail.Count) { Write-Host "Session host $(($avail[0].name -split '/')[-1]) is Available." -ForegroundColor Green; $ok = $true; break }
        Write-Host ("  waiting: " + $(if ($now.Count) { ($now | ForEach-Object { "$(($_.name -split '/')[-1])=$($_.properties.status)" }) -join ', ' } else { 'no record yet' }))
        Start-Sleep -Seconds 20
    }
    if (-not $ok) { throw "No Available session host record for $VmName after $WaitMinutes minutes. Check the RDAgent event log (Application, source RDAgent) and outbound access to the AVD service endpoints." }
}
finally {
    # 6. revoke
    if ($token -and -not $KeepToken) {
        try { [void](Invoke-ArmRequest -Method PATCH -Path "${hp}?api-version=$api" -Body @{ properties = @{ registrationInfo = @{ registrationTokenOperation = 'Delete' } } }); Write-Host 'Registration token revoked.' -ForegroundColor Green }
        catch { Write-Warning "Could not revoke the registration token: $_ . Revoke it manually, it is valid until $exp." }
    }
    $token = $null
}
