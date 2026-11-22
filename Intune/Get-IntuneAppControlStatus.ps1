#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Read-only probe of Intune App Control for Business policies, device configuration profiles and their assignment status.

.DESCRIPTION
    Answers "is the App Control policy really assigned to the devices I think it is" without touching the tenant.
    Only GET requests are sent. Evidence is written as JSON to -OutDir.

    Steps (each reports OK or FAIL; the script exits with an error if any step failed):
      1. Connect-MgGraph (interactive, process scope, read scopes only) and print account, tenant and scopes.
      2. Active Entra directory roles of the signed-in account (so "403" can be told apart from "no role").
      3. Optional (-CheckWriteConsent): is DeviceManagementConfiguration.ReadWrite.All already consented for the
         Microsoft Graph Command Line Tools app, for the whole tenant or for you. Measured, never requested.
      4. App Control policies: configurationPolicies with template family endpointSecurityApplicationControl
         (fallback: name filter over all policies). Zero policies is an error, not a clean result.
      5. Per policy: assignments (group names resolved, include/exclude, filters) and the settings tree. The policy
         XML is located inside the settings (plain or Base64), saved, and its PolicyID, BasePolicyID and PolicyType are
         read. A supplemental whose base is not among the tenant's base policies is flagged.
      6. Optional: managed devices by name (-DeviceName) with Entra group membership, and whether each device
         is in an include or exclude group of every base policy. A device that sits in two base policies' groups is flagged.
      7. Legacy profile and compliance counts (deviceConfigurations, deviceCompliancePolicies, managedDevices) as
         a Graph reachability check; an empty collection is flagged as "investigate".

.PARAMETER TenantId
    Tenant ID or domain to sign in to.

.PARAMETER PolicyNameFilter
    Wildcard on the policy name, applied after the template-family query. Default *.

.PARAMETER ExpectedBasePolicyId
    Optional GUID. Reported as matchesExpected when a base policy XML carries this PolicyID.

.PARAMETER DeviceName
    Managed device names whose group membership should be checked against the base policy assignments.

.PARAMETER OutDir
    Evidence folder. Default .\evidence.

.PARAMETER CheckWriteConsent
    Also measure whether write consent already exists (needs Directory.Read.All).

.EXAMPLE
    .\Get-IntuneAppControlStatus.ps1 -TenantId contoso.com -PolicyNameFilter 'Contoso_*' -DeviceName PC001, PC002

.NOTES
    Modules: Microsoft.Graph.Authentication. Delegated read scopes: DeviceManagementConfiguration.Read.All,
    DeviceManagementManagedDevices.Read.All, Group.Read.All, Directory.Read.All. Roles: Intune Administrator or
    Intune read-only roles (activate through PIM first). This script never escalates, never consents, never writes.
    A consent prompt for extra scopes should be cancelled, not approved. Interactive sign-in needs a window
    handle: run it in a real console, not from a hosted terminal.
    Trap: the App Control policy XML is stored inside a setting value; the encoding varies, so the script tries
    plain text, then Base64 as UTF-8 and UTF-16 before reporting "unknown". The templateFamily filter is a beta
    feature of the configurationPolicies endpoint and may change.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [string]$PolicyNameFilter = '*',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ExpectedBasePolicyId,
    [string[]]$DeviceName,
    [string]$OutDir = (Join-Path (Get-Location) 'evidence'),
    [switch]$CheckWriteConsent
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$steps = [ordered]@{}
$failed = 0
function Set-Step([string]$Name, [string]$Status, [string]$Detail) {
    $steps[$Name] = [ordered]@{ status = $Status; detail = $Detail }
    if ($Status -eq 'FAIL') { $script:failed++ }
    Write-Host ('[{0}] {1}: {2}' -f $Status, $Name, $Detail)
}
function Save-Json($Object, [string]$FileName) {
    $Object | ConvertTo-Json -Depth 100 | Out-File -FilePath (Join-Path $OutDir $FileName) -Encoding utf8
}
function Get-ErrText($Err) {
    $t = $Err.Exception.Message
    if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) { $t += ' | ' + $Err.ErrorDetails.Message }
    $t
}
function Enc([string]$s) { [uri]::EscapeDataString($s) }
function Has($o, [string]$name) { $null -ne $o -and $null -ne $o.PSObject.Properties[$name] }

# GET only. Follows @odata.nextLink for collections; returns the object itself for single entities.
function Get-Graph([string]$Uri) {
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $obj = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if (-not (Has $obj 'value')) { return $obj }
        foreach ($v in @($obj.value)) { $items.Add($v) }
        $next = if (Has $obj '@odata.nextLink') { $obj.'@odata.nextLink' } else { $null }
    }
    , $items.ToArray()
}

# Walks a settings tree; yields every string that is, or decodes to, App Control policy XML.
function Find-PolicyXml($Node, [string]$Path) {
    if ($null -eq $Node) { return }
    if ($Node -is [string]) {
        if ($Node -match '<SiPolicy') { [pscustomobject]@{ path = $Path; encoding = 'plain'; xml = $Node }; return }
        if ($Node.Length -gt 200 -and $Node -match '^[A-Za-z0-9+/=\s]+$') {
            try {
                $bytes = [Convert]::FromBase64String($Node)
                foreach ($e in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
                    $txt = $e.GetString($bytes)
                    if ($txt -match '<SiPolicy') { [pscustomobject]@{ path = $Path; encoding = "base64-$($e.WebName)"; xml = $txt }; return }
                }
                [pscustomobject]@{ path = $Path; encoding = 'base64-binary-or-unknown'; xml = $null }
            } catch { Write-Verbose "Not Base64 at $Path" }
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) { $i = 0; foreach ($n in $Node) { Find-PolicyXml $n "$Path[$i]"; $i++ }; return }
    if ($Node -is [pscustomobject]) { foreach ($p in $Node.PSObject.Properties) { Find-PolicyXml $p.Value "$Path.$($p.Name)" } }
}
function Get-DefinitionIds($Node) {
    if ($null -eq $Node -or $Node -is [string]) { return }
    if ($Node -is [System.Collections.IEnumerable]) { foreach ($n in $Node) { Get-DefinitionIds $n }; return }
    if ($Node -is [pscustomobject]) {
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name -eq 'settingDefinitionId' -and $p.Value -is [string]) { $p.Value } else { Get-DefinitionIds $p.Value }
        }
    }
}

$summary = [ordered]@{ runAt = (Get-Date).ToString('o'); tenant = $TenantId }
$scopes = @('DeviceManagementConfiguration.Read.All', 'DeviceManagementManagedDevices.Read.All', 'Group.Read.All')
if ($CheckWriteConsent) { $scopes += 'Directory.Read.All' }
$select = '$select=id,name,description,lastModifiedDateTime,templateReference,technologies,platforms'

try {
    # 1. Connect (interactive, this process only)
    Connect-MgGraph -TenantId $TenantId -Scopes $scopes -ContextScope Process -NoWelcome
    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Connect-MgGraph returned without a context' }
    $summary.context = [ordered]@{ account = $ctx.Account; tenantId = $ctx.TenantId; authType = "$($ctx.AuthType)"; clientId = $ctx.ClientId; scopes = @($ctx.Scopes | Sort-Object) }
    Save-Json $summary.context 'context.json'
    Set-Step '1-connect' 'OK' ('{0} / {1}' -f $ctx.Account, $ctx.TenantId)

    # 2. Active directory roles
    try {
        $me = Get-Graph '/v1.0/me?$select=id,userPrincipalName'
        $summary.meId = $me.id
        $roles = Get-Graph '/v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName'
        $summary.activeDirectoryRoles = @($roles | ForEach-Object { $_.displayName } | Sort-Object)
        Set-Step '2-active-roles' 'OK' ($(if ($summary.activeDirectoryRoles.Count) { $summary.activeDirectoryRoles -join ', ' } else { 'none active (activate Intune Administrator in PIM if calls return 403)' }))
    } catch { Set-Step '2-active-roles' 'FAIL' (Get-ErrText $_) }

    # 3. Write consent, measured without requesting it
    if ($CheckWriteConsent) {
        try {
            $graphCliAppId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools (first-party app)
            $sps = @(Get-Graph ('/v1.0/servicePrincipals?$filter=' + (Enc "appId eq '$graphCliAppId'") + '&$select=id'))
            if ($sps.Count -eq 0) { throw 'Microsoft Graph Command Line Tools service principal not found in this tenant' }
            $grants = @(Get-Graph ('/v1.0/oauth2PermissionGrants?$filter=' + (Enc "clientId eq '$($sps[0].id)'")))
            $allScopes = @($grants | Where-Object { $_.consentType -eq 'AllPrincipals' -or ($_.consentType -eq 'Principal' -and $_.principalId -eq $summary.meId) } |
                ForEach-Object { $_.scope -split '\s+' } | Where-Object { $_ } | Sort-Object -Unique)
            $summary.writeConsent = ($allScopes -contains 'DeviceManagementConfiguration.ReadWrite.All')
            Set-Step '3-write-consent' 'OK' ('ReadWrite already consented for you or the tenant: {0}' -f $summary.writeConsent)
        } catch { Set-Step '3-write-consent' 'FAIL' (Get-ErrText $_) }
    }

    # 4. App Control policies
    $policies = $null
    try {
        $policies = @(Get-Graph ('/beta/deviceManagement/configurationPolicies?$filter=' + (Enc "templateReference/templateFamily eq 'endpointSecurityApplicationControl'") + "&$select"))
        $summary.policyQueryMode = 'templateFamily filter'
    } catch {
        Set-Step '4-policies-filter' 'FAIL' ((Get-ErrText $_) + ' (falling back to a name filter over all policies)')
        $failed--   # the fallback below decides the outcome of this step
    }
    if ($null -eq $policies) {
        $all = @(Get-Graph "/beta/deviceManagement/configurationPolicies?$select")
        Save-Json $all 'configurationPolicies-all.json'
        $policies = @($all | Where-Object { $_.name -like $PolicyNameFilter })
        $summary.policyQueryMode = "all policies, name -like $PolicyNameFilter"
    } else {
        $policies = @($policies | Where-Object { $_.name -like $PolicyNameFilter })
    }
    Save-Json $policies 'appcontrol-policies.json'
    if ($policies.Count -eq 0) {
        Set-Step '4-policies' 'FAIL' "zero App Control policies match '$PolicyNameFilter': investigate (wrong filter, missing read role, or really none). Not a clean result."
    } else {
        Set-Step '4-policies' 'OK' ('{0} policies ({1})' -f $policies.Count, $summary.policyQueryMode)
    }

    # 5. Assignments and settings per policy
    $baseIds = @{}; $report = @()
    foreach ($p in ($policies | Sort-Object name)) {
        $row = [ordered]@{ name = $p.name; id = $p.id; lastModified = $p.lastModifiedDateTime; policyType = $null; policyId = $null; basePolicyId = $null; assignments = @() }
        try {
            $asg = @(Get-Graph "/beta/deviceManagement/configurationPolicies/$($p.id)/assignments")
            $row.assignments = @(foreach ($a in $asg) {
                $t = $a.target
                $gName = $null
                if ((Has $t 'groupId') -and $t.groupId) {
                    try { $gName = (Get-Graph "/v1.0/groups/$($t.groupId)?`$select=id,displayName").displayName } catch { $gName = 'UNRESOLVED: ' + (Get-ErrText $_) }
                }
                [ordered]@{ type = $t.'@odata.type'; groupId = $(if (Has $t 'groupId') { $t.groupId } else { $null }); groupName = $gName
                    mode = $(if ($t.'@odata.type' -match 'exclusion') { 'exclude' } else { 'include' }) }
            })
            if ($asg.Count -eq 0) { Write-Warning "Policy '$($p.name)' has NO assignments: it applies to no device." }
        } catch { Set-Step "5-assign-$($p.name)" 'FAIL' (Get-ErrText $_) }
        try {
            $settings = @(Get-Graph "/beta/deviceManagement/configurationPolicies/$($p.id)/settings")
            $xmls = @(Find-PolicyXml ($settings | ForEach-Object { $_.settingInstance }) 'settings')
            $row.settingDefinitionIds = @(Get-DefinitionIds ($settings | ForEach-Object { $_.settingInstance }) | Sort-Object -Unique)
            $i = 0
            foreach ($x in $xmls) {
                if (-not $x.xml) { $row.xmlEncoding = $x.encoding; continue }
                $safe = ($p.name -replace '[^A-Za-z0-9_.-]', '_')
                $x.xml | Out-File -FilePath (Join-Path $OutDir "$safe-policy-$i.xml") -Encoding utf8
                if ($x.xml -match '<PolicyID>\{?([0-9A-Fa-f-]{36})\}?</PolicyID>') { $row.policyId = $Matches[1].ToLower() }
                if ($x.xml -match '<BasePolicyID>\{?([0-9A-Fa-f-]{36})\}?</BasePolicyID>') { $row.basePolicyId = $Matches[1].ToLower() }
                if ($x.xml -match 'PolicyType="([^"]+)"') { $row.policyType = $Matches[1] }
                $i++
            }
            if ($row.policyType -eq 'Base Policy' -and $row.policyId) { $baseIds[$row.policyId] = $row }
        } catch { Set-Step "5-settings-$($p.name)" 'FAIL' (Get-ErrText $_) }
        $report += [pscustomobject]$row
    }
    $summary.policies = $report
    Save-Json $report 'appcontrol-report.json'
    if ($ExpectedBasePolicyId) {
        $summary.matchesExpectedBase = $baseIds.ContainsKey($ExpectedBasePolicyId.ToLower())
        Set-Step '5-expected-base' $(if ($summary.matchesExpectedBase) { 'OK' } else { 'FAIL' }) "base policy $ExpectedBasePolicyId present in the tenant: $($summary.matchesExpectedBase)"
    }
    foreach ($r in ($report | Where-Object { $_.policyType -eq 'Supplemental Policy' })) {
        if ($r.basePolicyId -and -not $baseIds.ContainsKey($r.basePolicyId)) {
            Write-Warning "Supplemental '$($r.name)' points to base $($r.basePolicyId), which is not among the policies matched by the filter."
        }
    }
    Set-Step '5-policy-detail' 'OK' ('{0} policy detail(s); {1} base policy(ies) identified' -f $report.Count, $baseIds.Count)

    # 6. Devices and group membership against the base assignments
    if ($DeviceName) {
        $baseIncl = @{}; $baseExcl = @{}
        foreach ($b in $baseIds.Values) {
            $baseIncl[$b.name] = @($b.assignments | Where-Object { $_.groupId -and $_.mode -eq 'include' } | ForEach-Object { $_.groupId })
            $baseExcl[$b.name] = @($b.assignments | Where-Object { $_.groupId -and $_.mode -eq 'exclude' } | ForEach-Object { $_.groupId })
        }
        $devRows = @()
        foreach ($dn in $DeviceName) {
            $row = [ordered]@{ deviceName = $dn }
            try {
                $md = @(Get-Graph ('/v1.0/deviceManagement/managedDevices?$filter=' + (Enc "deviceName eq '$dn'") + '&$select=id,deviceName,azureADDeviceId,lastSyncDateTime,osVersion,userPrincipalName'))
                if ($md.Count -ne 1) { throw "expected one managed device named $dn, found $($md.Count)" }
                $row.lastSync = $md[0].lastSyncDateTime; $row.osVersion = $md[0].osVersion
                $ent = @(Get-Graph ('/v1.0/devices?$filter=' + (Enc "deviceId eq '$($md[0].azureADDeviceId)'") + '&$select=id,displayName'))
                if ($ent.Count -ne 1) { throw "Entra device lookup returned $($ent.Count) objects" }
                $mem = @(Get-Graph "/v1.0/devices/$($ent[0].id)/transitiveMemberOf?`$select=id,displayName")
                $ids = @($mem | ForEach-Object { $_.id })
                $row.groups = @($mem | ForEach-Object { $_.displayName } | Sort-Object)
                $hits = @(foreach ($k in $baseIncl.Keys) {
                    if (@($baseIncl[$k] | Where-Object { $ids -contains $_ }).Count -gt 0 -and @($baseExcl[$k] | Where-Object { $ids -contains $_ }).Count -eq 0) { $k }
                })
                $row.baseIncludedBy = $hits
                if ($hits.Count -gt 1) { Write-Warning "$dn is targeted by $($hits.Count) base policies ($($hits -join ', ')): their rules intersect." }
                if ($hits.Count -eq 0) { Write-Warning "$dn is targeted by NO base policy." }
            } catch { $row.error = Get-ErrText $_; Set-Step "6-device-$dn" 'FAIL' $row.error }
            $devRows += [pscustomobject]$row
        }
        $summary.devices = $devRows
        Save-Json $devRows 'devices.json'
        Set-Step '6-devices' 'OK' ('{0} device(s) checked' -f $devRows.Count)
    }

    # 7. Reachability and counts
    foreach ($probe in @(
        @('managedDevices', '/v1.0/deviceManagement/managedDevices?$select=id'),
        @('deviceConfigurations', '/v1.0/deviceManagement/deviceConfigurations?$select=id'),
        @('deviceCompliancePolicies', '/v1.0/deviceManagement/deviceCompliancePolicies?$select=id'))) {
        try {
            $n = @(Get-Graph $probe[1]).Count
            Set-Step "7-$($probe[0])" 'OK' ("$n row(s)" + $(if ($n -eq 0) { ' <-- EMPTY, investigate' } else { '' }))
        } catch { Set-Step "7-$($probe[0])" 'FAIL' (Get-ErrText $_) }
    }
}
finally {
    try { if (Get-MgContext) { Disconnect-MgGraph | Out-Null } } catch { Write-Warning "Disconnect failed: $($_.Exception.Message)" }
    $summary.steps = $steps
    Save-Json $summary 'summary.json'
}
if ($failed -gt 0) { throw "$failed step(s) failed. See $OutDir\summary.json." }
Write-Host "Evidence: $OutDir"
