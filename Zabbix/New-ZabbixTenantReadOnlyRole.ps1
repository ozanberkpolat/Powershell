#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a Zabbix user role that sees only one tenant's business services (by service tag), moves the tenant's users
    onto it, and optionally puts them in a user group and removes service visibility from shared roles.

.DESCRIPTION
    Keeps one tenant's service tree (Set-ZabbixServiceTree.ps1) away from other tenants on a shared Zabbix:

      1. Role: a copy of -TemplateRoleName (all its UI, API, module and action rules) with the services rules changed
         to "read-only access to services with tag <ServiceTag>=<ServiceTagValue>" and no write access. A service that
         matches the tag also gives access to its child services, so tag the ROOT of the tenant's subtree.
         An existing role with -RoleName is reused, not changed.
      2. Users (-UserName): moved onto the role (user.update roleid). Every named user must exist, or nothing is written.
      3. Optional user group (-UserGroupName): created when missing, with read permission on -HostGroupName, and the
         users added to it (existing members are kept).
      4. Optional (-RestrictSharedRole): the named shared, non-admin roles lose service read access (services.read.mode
         = list, empty list, no tag). This affects every user on those roles, tenant or not, so it is opt-in and
         asked for separately (ShouldProcess per role).

    Role rules are read in full (selectRules extend) and sent back with ONLY the services keys changed: role.update
    with a partial rules object would reset the rest. Before/after snapshots go to .\evidence.

.PARAMETER RoleName
    Name of the tenant role, for example 'Contoso Read Only'.

.PARAMETER TemplateRoleName
    Existing role to copy (usually a read-only User-type role).

.PARAMETER ServiceTag
    Service tag name that marks the tenant's services. Default 'tenant'.

.PARAMETER ServiceTagValue
    Tag value of this tenant, for example 'contoso'.

.PARAMETER UserName
    Usernames (the login name, `username` field) to move onto the role.

.PARAMETER UserGroupName
    Optional user group for the tenant's users.

.PARAMETER HostGroupName
    Host groups the user group gets READ permission on (only with -UserGroupName).

.PARAMETER RestrictSharedRole
    Shared role names whose service read access is switched off.

.PARAMETER EvidenceDir
    Folder for the before/after JSON snapshots. Default .\evidence.

.PARAMETER Url
    Zabbix front end URL. Default: env ZABBIX_URL.

.PARAMETER TokenFile
    File with the API token. Default: env ZABBIX_TOKEN_FILE.

.PARAMETER Token
    API token as SecureString (alternative to TokenFile).

.EXAMPLE
    .\New-ZabbixTenantReadOnlyRole.ps1 -RoleName 'Contoso Read Only' -TemplateRoleName 'Read-only user' `
        -ServiceTagValue contoso -UserName 'contoso.viewer' -WhatIf

.EXAMPLE
    .\New-ZabbixTenantReadOnlyRole.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token `
        -RoleName 'Contoso Read Only' -TemplateRoleName 'Read-only user' -ServiceTagValue contoso `
        -UserName 'contoso.viewer' -UserGroupName 'Contoso viewers' -HostGroupName 'Contoso-Servers'

.NOTES
    WRITE. Run with -WhatIf first. Needs a Super admin token (roles and users are Super admin objects). Zabbix 6.0+.
    services.read.mode: 0 = only the services in services.read.list or with services.read.tag, 1 = all services.
    A Super admin role always sees everything; this cannot limit one.
    The role's `readonly` property is returned by role.get but is read-only in the API; it is not sent on create.
    UNTESTED: the user group step (usergroup.get/create/update with hostgroup_rights, Zabbix 6.2+; older versions use
    `rights`). The role, user move and shared-role steps are ports of a run that was applied in production; verify the
    user group step with -WhatIf and one test user first.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$RoleName,
    [Parameter(Mandatory)][string]$TemplateRoleName,
    [string]$ServiceTag = 'tenant',
    [Parameter(Mandatory)][string]$ServiceTagValue,
    [string[]]$UserName,
    [string]$UserGroupName,
    [string[]]$HostGroupName,
    [string[]]$RestrictSharedRole,
    [string]$EvidenceDir = (Join-Path (Get-Location) 'evidence'),
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
if ($HostGroupName -and -not $UserGroupName) { throw '-HostGroupName needs -UserGroupName.' }
if ($RestrictSharedRole -contains $RoleName) { throw "-RestrictSharedRole must not name the tenant role itself." }

. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

function Get-Roles([string[]]$Names) {
    $r = Invoke-ZabbixApi -Method role.get -AllowEmpty -Params @{ filter = @{ name = $Names }; output = 'extend'; selectRules = 'extend' }
    $r   # emit the rows, not the single array object
}
function Get-ServiceOnlyRules($Rules, $Tag) {
    # Full rule set back, only the services keys changed. Unknown keys are kept as returned.
    $h = [ordered]@{}
    foreach ($p in $Rules.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h['services.read.mode'] = '0'
    $h['services.read.list'] = @()
    $h['services.read.tag'] = $(if ($Tag) { $Tag } else { @{ tag = ''; value = '' } })
    $h['services.write.mode'] = '0'
    $h['services.write.list'] = @()
    $h['services.write.tag'] = @{ tag = ''; value = '' }
    $h
}

$roleNames = @($TemplateRoleName, $RoleName) + @($RestrictSharedRole | Where-Object { $_ })
$existing = @{}; foreach ($r in (Get-Roles $roleNames)) { $existing[[string]$r.name] = $r }
$missing = @(@($TemplateRoleName) + @($RestrictSharedRole | Where-Object { $_ }) | Where-Object { -not $existing.ContainsKey($_) })
if ($missing.Count) { throw "Role(s) not found: $($missing -join ', '). Nothing was changed." }

$users = @()
if ($UserName) {
    $users = @((Invoke-ZabbixApi -Method user.get -AllowEmpty -Params @{ filter = @{ username = $UserName }; output = @('userid', 'username', 'roleid') }))
    $notFound = @($UserName | Where-Object { @($users | ForEach-Object { $_.username }) -notcontains $_ })
    if ($notFound.Count) { throw "User(s) not found: $($notFound -join ', '). Found: $((@($users | ForEach-Object { $_.username })) -join ', '). Nothing was changed." }
}
$hostGroupIds = @($HostGroupName | Where-Object { $_ } | ForEach-Object { Resolve-ZabbixHostGroup -Name $_ })
Write-Host "Before snapshot: $(Save-ZabbixEvidence -Name 'tenant-role-before' -Object @{ roles = @($existing.Values); users = $users } -Dir $EvidenceDir)"

# 1. role
$tag = @{ tag = $ServiceTag; value = $ServiceTagValue }
$roleId = $null
if ($existing.ContainsKey($RoleName)) {
    $roleId = [string]$existing[$RoleName].roleid
    $cur = $existing[$RoleName].rules
    Write-Host "= role '$RoleName' exists ($roleId); services.read.mode=$($cur.'services.read.mode') tag=$($cur.'services.read.tag'.tag)=$($cur.'services.read.tag'.value). Not changed."
} else {
    $tpl = $existing[$TemplateRoleName]
    Write-Host "+ role '$RoleName': copy of '$TemplateRoleName', services read-only by tag $ServiceTag=$ServiceTagValue"
    if ($PSCmdlet.ShouldProcess($RoleName, 'role.create')) {
        $r = Invoke-ZabbixApi -Method role.create -Params @{ name = $RoleName; type = $tpl.type; rules = (Get-ServiceOnlyRules $tpl.rules $tag) }
        $roleId = [string]$r[0].roleids[0]
    }
}

# 2. users
foreach ($u in $users) {
    if ($roleId -and [string]$u.roleid -eq $roleId) { Write-Host "= user $($u.username) already on the role"; continue }
    Write-Host "~ user $($u.username): roleid $($u.roleid) -> $(if ($roleId) { $roleId } else { '<new role>' })"
    if ($roleId -and $PSCmdlet.ShouldProcess($u.username, "user.update roleid $roleId")) {
        [void](Invoke-ZabbixApi -Method user.update -Params @{ userid = $u.userid; roleid = $roleId })
    }
}

# 3. user group (UNTESTED, see NOTES)
if ($UserGroupName) {
    $grp = @((Invoke-ZabbixApi -Method usergroup.get -AllowEmpty -Params @{ filter = @{ name = $UserGroupName }; output = @('usrgrpid', 'name'); selectUsers = @('userid') }))
    $grpId = $null; $members = @()
    if ($grp.Count) {
        $grpId = [string]$grp[0].usrgrpid
        $members = @($grp[0].users | ForEach-Object { [string]$_.userid })
        Write-Host "= user group '$UserGroupName' exists ($grpId); host group rights not changed."
    } else {
        Write-Host "+ user group '$UserGroupName' with READ on: $(if ($HostGroupName) { $HostGroupName -join ', ' } else { '(no host groups)' })"
        if ($PSCmdlet.ShouldProcess($UserGroupName, 'usergroup.create')) {
            $p = @{ name = $UserGroupName }
            if ($hostGroupIds.Count) { $p['hostgroup_rights'] = @($hostGroupIds | ForEach-Object { @{ id = $_; permission = 2 } }) }   # 2 = read
            $grpId = [string](Invoke-ZabbixApi -Method usergroup.create -Params $p)[0].usrgrpids[0]
        }
    }
    $add = @($users | Where-Object { $members -notcontains [string]$_.userid })
    if ($add.Count) {
        Write-Host "~ user group '$UserGroupName': add $((@($add | ForEach-Object { $_.username })) -join ', ')"
        # usergroup.update `users` REPLACES the member list: send existing members plus the new ones.
        if ($grpId -and $PSCmdlet.ShouldProcess($UserGroupName, 'usergroup.update users')) {
            $all = @($members + @($add | ForEach-Object { [string]$_.userid }) | Sort-Object -Unique)
            [void](Invoke-ZabbixApi -Method usergroup.update -Params @{ usrgrpid = $grpId; users = @($all | ForEach-Object { @{ userid = $_ } }) })
        }
    }
}

# 4. shared roles (opt-in)
foreach ($name in @($RestrictSharedRole | Where-Object { $_ })) {
    $r = $existing[$name]
    Write-Host "~ role '$name': services.read.mode $($r.rules.'services.read.mode') -> 0 with no list and no tag (no services visible)"
    if ($PSCmdlet.ShouldProcess($name, 'role.update: remove service read access for every user on this role')) {
        [void](Invoke-ZabbixApi -Method role.update -Params @{ roleid = $r.roleid; rules = (Get-ServiceOnlyRules $r.rules $null) })
    }
}

if (-not $WhatIfPreference) {
    $after = @{ roles = @(Get-Roles (@($RoleName) + @($RestrictSharedRole | Where-Object { $_ })))
                users = @(if ($UserName) { Invoke-ZabbixApi -Method user.get -AllowEmpty -Params @{ filter = @{ username = $UserName }; output = @('userid', 'username', 'roleid') } }) }
    Write-Host "After snapshot: $(Save-ZabbixEvidence -Name 'tenant-role-after' -Object $after -Dir $EvidenceDir)"
}
