#Requires -Version 7.0
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Let an application (service principal or managed identity) use ONE mailbox only, with Exchange Online RBAC for Applications.

.DESCRIPTION
    Graph application permissions such as Mail.ReadWrite apply to every mailbox in the tenant. RBAC for Applications gives
    the same access limited to a scope. The script, in order:

      1. registers the service principal in Exchange (New-ServicePrincipal) unless it is already there,
      2. creates a management scope that matches exactly the target mailbox (New-ManagementScope, PrimarySmtpAddress filter),
      3. assigns the chosen application role(s) to the principal limited to that scope (New-ManagementRoleAssignment),
      4. tests: the target mailbox must report InScope True, and an optional control mailbox must report False.

    Idempotent: an existing principal, scope or assignment is reported and kept. Every create is guarded by ShouldProcess.

.PARAMETER AppId
    Application (client) ID of the service principal. For a managed identity this is its "Application ID".
.PARAMETER ServicePrincipalObjectId
    Object ID of the service principal in Entra (for a managed identity, the Principal ID).
.PARAMETER DisplayName
    Display name stored in Exchange for the principal.
.PARAMETER Mailbox
    Primary SMTP address of the only mailbox the app may reach.
.PARAMETER Role
    Application roles. Default 'Application Mail.Read'. Others: 'Application Mail.ReadWrite', 'Application Mail.Send',
    'Application Calendars.Read', 'Application Calendars.ReadWrite', 'Application Contacts.Read', ...
.PARAMETER ScopeName
    Management scope name. Default derived from the mailbox.
.PARAMETER ControlMailbox
    Another mailbox that must come back InScope False (proves the scoping).

.EXAMPLE
    Connect-ExchangeOnline
    ./Set-AppMailboxScope.ps1 -AppId <appId> -ServicePrincipalObjectId <oid> -DisplayName 'Robot identity' `
        -Mailbox robot-inbox@contoso.com -Role 'Application Mail.ReadWrite' -ControlMailbox someone@contoso.com -WhatIf

.NOTES
    Role: Exchange Administrator (Organization Management) activated through PIM. Modules: ExchangeOnlineManagement 3.x. Connect first with
    Connect-ExchangeOnline (under App Control / Constrained Language Mode see M365/Connect-ExoSigned.psm1 if present).
    Traps kept:
      - Do NOT also grant Graph Mail.* application roles in Entra: they win and open every mailbox. Remove them if present.
      - Changes can take from minutes up to about 2 hours to take effect in Exchange's authorization cache. Test-ServicePrincipalAuthorization
        reflects the configuration, the real Graph call may lag.
      - The management scope filter is a recipient filter on one address; it does not follow alias or address changes of that mailbox.
      - Mail.Send via RBAC for Applications still needs the mailbox to be able to send (not blocked, licensed).
      - New-ServicePrincipal takes the SAME ObjectId and AppId you see in Entra, not the Exchange-side ID.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$ServicePrincipalObjectId,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+$')][string]$Mailbox,
    [string[]]$Role = @('Application Mail.Read'),
    [string]$ScopeName,
    [string]$ControlMailbox
)

$ErrorActionPreference = 'Stop'
if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) { throw 'Not connected to Exchange Online. Run Connect-ExchangeOnline first.' }
if (-not $ScopeName) { $ScopeName = 'AppScope-' + (($Mailbox -replace '@.*$', '') -replace '[^A-Za-z0-9-]', '-') }

# 1. service principal in Exchange
$sp = Get-ServicePrincipal -Identity $ServicePrincipalObjectId -ErrorAction SilentlyContinue
if ($sp) { Write-Host "Service principal already in Exchange: $($sp.DisplayName)" -ForegroundColor DarkGray }
elseif ($PSCmdlet.ShouldProcess($DisplayName, 'New-ServicePrincipal')) {
    New-ServicePrincipal -AppId $AppId -ObjectId $ServicePrincipalObjectId -DisplayName $DisplayName | Out-Null
    Write-Host 'Service principal registered.' -ForegroundColor Green
}

# 2. scope = exactly one mailbox
$filter = "PrimarySmtpAddress -eq '$($Mailbox -replace "'", "''")'"
$scope = Get-ManagementScope -Identity $ScopeName -ErrorAction SilentlyContinue
if ($scope) {
    if ($scope.RecipientFilter -notmatch [regex]::Escape($Mailbox)) { throw "Scope '$ScopeName' exists with a different filter ($($scope.RecipientFilter)). Pick another -ScopeName." }
    Write-Host "Scope '$ScopeName' already exists." -ForegroundColor DarkGray
} elseif ($PSCmdlet.ShouldProcess($ScopeName, "New-ManagementScope ($filter)")) {
    New-ManagementScope -Name $ScopeName -RecipientRestrictionFilter $filter | Out-Null
    Write-Host "Scope '$ScopeName' created." -ForegroundColor Green
}

# 3. role assignments limited to the scope
$have = @(Get-ManagementRoleAssignment -RoleAssignee $ServicePrincipalObjectId -ErrorAction SilentlyContinue)
foreach ($r in $Role) {
    if ($have | Where-Object { $_.Role -eq $r -and $_.CustomResourceScope -eq $ScopeName }) { Write-Host "'$r' already assigned on '$ScopeName'." -ForegroundColor DarkGray; continue }
    if ($PSCmdlet.ShouldProcess("$DisplayName", "New-ManagementRoleAssignment '$r' limited to $ScopeName")) {
        New-ManagementRoleAssignment -App $ServicePrincipalObjectId -Role $r -CustomResourceScope $ScopeName | Out-Null
        Write-Host "Assigned '$r'." -ForegroundColor Green
    }
}
$unscoped = @($have | Where-Object { -not $_.CustomResourceScope -and $_.Role -like 'Application *' })
if ($unscoped.Count) { Write-Warning "This principal also has UNSCOPED application roles ($($unscoped.Role -join ', ')): it can reach every mailbox. Remove them." }

# 4. test
if (-not $WhatIfPreference) {
    $t = Test-ServicePrincipalAuthorization -Identity $ServicePrincipalObjectId -Resource $Mailbox
    $t | Format-Table RoleName, GrantedPermissions, AllowedResourceScope, ScopeType, InScope -AutoSize
    if (-not @($t | Where-Object InScope).Count) { throw "Target mailbox $Mailbox is not InScope. Check the filter and roles; Exchange can also take a while to apply them." }
    if ($ControlMailbox) {
        $c = Test-ServicePrincipalAuthorization -Identity $ServicePrincipalObjectId -Resource $ControlMailbox
        if (@($c | Where-Object InScope).Count) { throw "Control mailbox $ControlMailbox is InScope: scoping is NOT effective (an unscoped role or Graph Mail.* permission exists)." }
        Write-Host "Control mailbox is out of scope, as it should be." -ForegroundColor Green
    }
}
