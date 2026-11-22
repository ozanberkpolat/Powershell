#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Give a managed identity (or any service principal) access to Microsoft 365: a Graph app role, a SharePoint folder or site, and optionally a Key Vault role.

.DESCRIPTION
    Managed identities cannot be given Graph application permissions in the portal. This script does it with Graph REST:

      1. App role assignment: assigns Graph application roles (for example Files.SelectedOperations.Selected or Sites.Selected)
         to the identity. Idempotent: an existing assignment is reported and left alone.
      2. SharePoint scoping (needed for the two *.Selected roles, which grant nothing on their own):
         - folder level (Files.SelectedOperations.Selected): resolves site, library and folder and adds a permission on the
           folder's list item with the role read or write for the identity;
         - site level (Sites.Selected): adds a site permission with the chosen role.
         Prints siteId, driveId and folderId for the process that will call Graph (a managed identity often cannot resolve
         site and library names itself).
      3. Optional Key Vault role (-KeyVaultName): Key Vault Secrets User by default, on a vault in RBAC mode.
      4. -VerifyOnHost: run ON the VM that owns the identity. Requests a token from IMDS and prints oid and roles.

    For mailbox access do NOT grant Graph Mail.* roles here: they apply to every mailbox in the tenant. Use
    M365/Set-AppMailboxScope.ps1 (Exchange RBAC for Applications, scoped to one mailbox).

.PARAMETER ServicePrincipalObjectId
    Object ID of the service principal (for a system-assigned managed identity this is the "Principal ID" of the VM / app).
.PARAMETER GraphAppRole
    Graph application role names to assign, for example Files.SelectedOperations.Selected, Sites.Selected.
.PARAMETER SiteUrl
    SharePoint site as host:/sites/name, for example contoso.sharepoint.com:/sites/Operations
.PARAMETER Library
    Document library display name (folder mode).
.PARAMETER FolderPath
    Folder path inside the library, for example Robot/Input (folder mode).
.PARAMETER SitePermission
    read or write at SITE level (Sites.Selected). Mutually exclusive with -FolderPath.
.PARAMETER FolderRole
    read or write on the folder. Default write.
.PARAMETER KeyVaultName
    Vault to give the identity a role on (needs the Az.KeyVault and Az.Resources modules and Connect-AzAccount).
.PARAMETER KeyVaultRole
    Built-in role name. Default 'Key Vault Secrets User' (role definition 4633458b-17de-408a-b874-0445c86b69e6).
.PARAMETER VerifyOnHost
    Verification mode, no writes. Run on the host that owns the managed identity.

.EXAMPLE
    ./Grant-ManagedIdentityM365Access.ps1 -ServicePrincipalObjectId <oid> -GraphAppRole Files.SelectedOperations.Selected `
        -SiteUrl contoso.sharepoint.com:/sites/Operations -Library Documents -FolderPath Robot/Input -FolderRole write -WhatIf

.EXAMPLE
    ./Grant-ManagedIdentityM365Access.ps1 -VerifyOnHost

.NOTES
    Who runs it: the app role assignment needs Global Administrator or Privileged Role Administrator (scopes
    AppRoleAssignment.ReadWrite.All, Application.Read.All). The SharePoint permission needs Sites.FullControl.All (consent as an
    admin). The Key Vault role needs Owner or User Access Administrator on the vault. Activate PIM first. Modules: Microsoft.Graph.Authentication
    (plus Az.KeyVault / Az.Resources for -KeyVaultName).
    Well-known IDs used: 00000003-0000-0000-c000-000000000000 is Microsoft Graph (first-party application ID).
    Traps kept:
      - The managed identity's token carries its roles at issue time and is cached. After granting, the process must get a NEW token
        (restart the process; cached tokens live up to 24 hours). Check the roles claim with -VerifyOnHost.
      - A server that talks through a proxy must exclude 169.254.169.254 (IMDS) from the proxy, otherwise token requests fail.
        The verify code uses -NoProxy for that reason.
      - A *.Selected role with no folder/site permission can read nothing. Break permission inheritance on the folder if only that
        folder may be reachable.
      - The same identity can exist twice (system-assigned and a shared user-assigned identity on many servers). Grant ONLY to the
        identity you mean: the oid claim in the verified token must equal -ServicePrincipalObjectId. Never grant to a shared identity.
      - Lookup of the app role must filter allowedMemberTypes -contains Application (some names exist as both delegated and application).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Grant')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Grant')][string]$ServicePrincipalObjectId,
    [Parameter(ParameterSetName = 'Grant')][string[]]$GraphAppRole = @(),
    [Parameter(ParameterSetName = 'Grant')][string]$SiteUrl,
    [Parameter(ParameterSetName = 'Grant')][string]$Library,
    [Parameter(ParameterSetName = 'Grant')][string]$FolderPath,
    [Parameter(ParameterSetName = 'Grant')][ValidateSet('read', 'write')][string]$SitePermission,
    [Parameter(ParameterSetName = 'Grant')][ValidateSet('read', 'write')][string]$FolderRole = 'write',
    [Parameter(ParameterSetName = 'Grant')][string]$KeyVaultName,
    [Parameter(ParameterSetName = 'Grant')][string]$KeyVaultRole = 'Key Vault Secrets User',
    [Parameter(Mandatory, ParameterSetName = 'Verify')][switch]$VerifyOnHost
)

$ErrorActionPreference = 'Stop'
$GraphAppId = '00000003-0000-0000-c000-000000000000'   # Microsoft Graph, first-party application ID
$g = 'https://graph.microsoft.com/v1.0'

if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    $tok = Invoke-RestMethod -NoProxy -Headers @{ Metadata = 'true' } -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://graph.microsoft.com/"
    $p = $tok.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/'); while ($p.Length % 4) { $p += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    "oid   : $($claims.oid)  (must equal the identity you granted)"
    "roles : $(@($claims.roles) -join ', ')"
    if (-not $claims.roles) { Write-Warning 'No roles in the token: grant not effective yet, or this is a cached token. Get a new token after the grant.' }
    return
}

if (-not $GraphAppRole.Count -and -not $FolderPath -and -not $SitePermission -and -not $KeyVaultName) { throw 'Nothing to do: pass -GraphAppRole, -FolderPath/-SitePermission or -KeyVaultName.' }
if ($FolderPath -and $SitePermission) { throw 'Use -FolderPath (folder) or -SitePermission (site), not both.' }
if (($FolderPath -or $SitePermission) -and -not $SiteUrl) { throw '-SiteUrl is required for SharePoint scoping.' }
if ($FolderPath -and -not $Library) { throw '-Library is required with -FolderPath.' }

Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All', 'Sites.FullControl.All' -NoWelcome | Out-Null
$sp = Invoke-MgGraphRequest -Method GET -Uri "$g/servicePrincipals/$ServicePrincipalObjectId" -OutputType PSObject
if (-not $sp.id) { throw "Service principal $ServicePrincipalObjectId not found." }
Write-Host "Identity: $($sp.displayName) ($($sp.appId))" -ForegroundColor Cyan

# ---- 1. Graph app roles ------------------------------------------------------------
if ($GraphAppRole.Count) {
    $graphSp = (Invoke-MgGraphRequest -Method GET -Uri "$g/servicePrincipals?`$filter=appId eq '$GraphAppId'" -OutputType PSObject).value[0]
    $existing = @((Invoke-MgGraphRequest -Method GET -Uri "$g/servicePrincipals/$ServicePrincipalObjectId/appRoleAssignments" -OutputType PSObject).value)
    foreach ($name in $GraphAppRole) {
        $role = $graphSp.appRoles | Where-Object { $_.value -eq $name -and $_.allowedMemberTypes -contains 'Application' }
        if (-not $role) { throw "Graph has no application role named '$name'." }
        if ($existing | Where-Object { $_.appRoleId -eq $role.id -and $_.resourceId -eq $graphSp.id }) { Write-Host "Role $name already assigned." -ForegroundColor DarkGray; continue }
        if ($PSCmdlet.ShouldProcess($sp.displayName, "Assign Graph application role $name")) {
            Invoke-MgGraphRequest -Method POST -Uri "$g/servicePrincipals/$ServicePrincipalObjectId/appRoleAssignments" `
                -Body (@{ principalId = $ServicePrincipalObjectId; resourceId = $graphSp.id; appRoleId = $role.id } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
            Write-Host "Assigned $name" -ForegroundColor Green
        }
    }
    $after = (Invoke-MgGraphRequest -Method GET -Uri "$g/servicePrincipals/$ServicePrincipalObjectId/appRoleAssignments" -OutputType PSObject).value
    $after | ForEach-Object { $rid = $_.appRoleId; [pscustomobject]@{ Resource = $_.resourceDisplayName; Role = ($graphSp.appRoles | Where-Object id -eq $rid).value } } | Format-Table -AutoSize
}

# ---- 2. SharePoint scoping -------------------------------------------------------------
if ($SiteUrl -and ($FolderPath -or $SitePermission)) {
    $site = Invoke-MgGraphRequest -Method GET -Uri "$g/sites/$SiteUrl" -OutputType PSObject
    if (-not $site.id) { throw "Site '$SiteUrl' not found." }
    $grantee = @{ application = @{ id = $sp.appId; displayName = $sp.displayName } }
    if ($FolderPath) {
        $lists = (Invoke-MgGraphRequest -Method GET -Uri "$g/sites/$($site.id)/lists?`$filter=displayName eq '$($Library -replace "'", "''")'" -OutputType PSObject).value
        if (-not $lists) { throw "Library '$Library' not found on the site." }
        $list = $lists[0]
        $folder = Invoke-MgGraphRequest -Method GET -Uri "$g/sites/$($site.id)/lists/$($list.id)/drive/root:/$($FolderPath.Trim('/')):?`$expand=listItem" -OutputType PSObject
        if (-not $folder.listItem.id) { throw "Folder '$FolderPath' not found in '$Library'." }
        if ($PSCmdlet.ShouldProcess("$Library/$FolderPath", "Grant $FolderRole to $($sp.displayName)")) {
            Invoke-MgGraphRequest -Method POST -Uri "$g/sites/$($site.id)/lists/$($list.id)/items/$($folder.listItem.id)/permissions" `
                -Body (@{ roles = @($FolderRole); grantedToV2 = $grantee } | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
            Write-Host "Folder permission '$FolderRole' granted." -ForegroundColor Green
        }
        "`nIDs for the calling process:"
        "siteId   : $($site.id)"; "driveId  : $($folder.parentReference.driveId)"; "folderId : $($folder.id)"
    } else {
        if ($PSCmdlet.ShouldProcess($SiteUrl, "Grant site permission $SitePermission to $($sp.displayName)")) {
            Invoke-MgGraphRequest -Method POST -Uri "$g/sites/$($site.id)/permissions" `
                -Body (@{ roles = @($SitePermission); grantedToIdentities = @($grantee) } | ConvertTo-Json -Depth 6) -ContentType 'application/json' | Out-Null
            Write-Host "Site permission '$SitePermission' granted." -ForegroundColor Green
        }
    }
}

# ---- 3. Key Vault role -------------------------------------------------------------------
if ($KeyVaultName) {
    if (-not (Get-Module -ListAvailable Az.KeyVault) -or -not (Get-Module -ListAvailable Az.Resources)) { throw 'Az.KeyVault and Az.Resources are required for -KeyVaultName.' }
    if (-not (Get-AzContext)) { throw 'No Az context for the Key Vault role. Run Connect-AzAccount.' }
    $vault = Get-AzKeyVault -VaultName $KeyVaultName
    if (-not $vault) { throw "Key Vault '$KeyVaultName' not found." }
    if (-not $vault.EnableRbacAuthorization) { Write-Warning 'The vault uses access policies, not RBAC: a role assignment has no effect. Add an access policy instead.' }
    $have = Get-AzRoleAssignment -ObjectId $ServicePrincipalObjectId -RoleDefinitionName $KeyVaultRole -Scope $vault.ResourceId -ErrorAction SilentlyContinue
    if ($have) { Write-Host "$KeyVaultRole already assigned on $KeyVaultName." -ForegroundColor DarkGray }
    elseif ($PSCmdlet.ShouldProcess($vault.ResourceId, "Assign $KeyVaultRole")) {
        New-AzRoleAssignment -ObjectId $ServicePrincipalObjectId -RoleDefinitionName $KeyVaultRole -Scope $vault.ResourceId | Out-Null
        Write-Host "Assigned $KeyVaultRole on $KeyVaultName" -ForegroundColor Green
    }
}
Write-Host "`nDone. The identity needs a NEW token to see the new roles. Run with -VerifyOnHost on the host." -ForegroundColor Cyan
