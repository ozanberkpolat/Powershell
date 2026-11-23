#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a Zabbix business service tree from a JSON definition file, idempotently. Leaves map existing problems by
    problem tag; parents take their status from their children.

.DESCRIPTION
    A report-only service tree: no service actions and no SLA objects are created. Each node in the definition file
    becomes a Zabbix service (service.create):

      * Leaves carry problem tags. A leaf turns red when a problem with ALL its problem tags exists, so the leaves are
        only as good as the host, item and trigger tags behind them (see Set-ZabbixHostTags.ps1).
      * Parents use the "most critical of child services" algorithm by default.
      * Root nodes carry service tags (for example tenant = contoso). New-ZabbixTenantReadOnlyRole.ps1 limits a role to
        the services with that tag.

    Idempotent: a node whose name already exists under the same parent is kept as it is (reported with "="), never
    updated. A kept node whose problem tags differ from the file is reported as a warning so you can fix it by hand.
    When a parent does not exist yet and is not created (-WhatIf, or declined), its children are listed as "would
    create" and never looked up as roots.

    Evidence: before and after snapshots of every service go to .\evidence (Save-ZabbixEvidence).

    Definition file (JSON, see examples\service-tree.example.json):

        { "services": [ { "name": "...", "description": "...", "tags": { "tenant": "contoso" },
                          "algorithm": "mostCritical", "children": [ { "name": "...",
                          "problemTags": [ { "tag": "bsvc", "operator": "equals", "value": "shop-web" } ] } ] } ] }

      name         required, unique among its siblings
      description  optional (useful for "pending" nodes whose monitoring does not exist yet)
      tags         optional service tags (object of tag: value)
      problemTags  optional; operator "equals" (default) or "contains"
      algorithm    optional: mostCritical (default, 2), allChildren (1, problem only when all children have one), ok (0)
      children     optional array of nodes

.PARAMETER DefinitionFile
    Path of the JSON definition.

.PARAMETER EvidenceDir
    Folder for the before/after JSON snapshots. Default .\evidence.

.PARAMETER Url
    Zabbix front end URL. Default: env ZABBIX_URL.

.PARAMETER TokenFile
    File with the API token. Default: env ZABBIX_TOKEN_FILE.

.PARAMETER Token
    API token as SecureString (alternative to TokenFile).

.EXAMPLE
    .\Set-ZabbixServiceTree.ps1 -DefinitionFile .\examples\service-tree.example.json -WhatIf

.EXAMPLE
    .\Set-ZabbixServiceTree.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -DefinitionFile .\shop-tree.json

.NOTES
    UNTESTED: the problem-tag drift warning and the JSON definition reader are new; the create logic is a port of a run
    that was applied in production.
    WRITE. Run with -WhatIf first. Needs Zabbix 6.0 or newer (services with problem tags) and a token whose role has
    write access to services (Admin or Super admin role with "Read-write access to services").
    Traps kept from production use:
      * Problem tags match PROBLEM tags, which come from trigger, item, template and host tags. A leaf whose tags no
        problem carries stays green forever; tag the hosts first, then build the tree.
      * service.get filters by name across the whole server; the parent check is done here, so equal names under
        different parents are fine.
      * Nothing is deleted or updated. Renaming a node in the file creates a new node next to the old one.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DefinitionFile,
    [string]$EvidenceDir = (Join-Path (Get-Location) 'evidence'),
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'

$def = Get-Content $DefinitionFile -Raw | ConvertFrom-Json
if (-not ($def.PSObject.Properties.Name -contains 'services') -or @($def.services).Count -eq 0) {
    throw "$DefinitionFile has no 'services' array."
}

. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')     # also sets StrictMode Latest: optional fields go through Get-Field

function Get-Field($Obj, [string]$Name, $Default = $null) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $Name -and $null -ne $Obj.$Name) { return $Obj.$Name }
    $Default
}
$algorithms = @{ mostCritical = 2; allChildren = 1; ok = 0 }
$operators = @{ equals = 0; contains = 2 }

function Test-Node($Node, [string]$Path) {
    $name = [string](Get-Field $Node 'name' '')
    if (-not $name.Trim()) { throw "A node under '$Path' has no name." }
    $alg = [string](Get-Field $Node 'algorithm' 'mostCritical')
    if (-not $algorithms.ContainsKey($alg)) { throw "'$Path/$name': algorithm '$alg' is not one of $($algorithms.Keys -join ', ')." }
    foreach ($pt in @(Get-Field $Node 'problemTags' @())) {
        $op = [string](Get-Field $pt 'operator' 'equals')
        if (-not $operators.ContainsKey($op)) { throw "'$Path/$name': problem tag operator '$op' is not equals or contains." }
        if (-not (Get-Field $pt 'tag' '')) { throw "'$Path/$name': a problem tag has no tag name." }
    }
    $kids = @(Get-Field $Node 'children' @())
    if ($kids.Count -eq 0 -and @(Get-Field $Node 'problemTags' @()).Count -eq 0) {
        Write-Warning "'$Path/$name' is a leaf without problem tags: it will stay OK forever."
    }
    $dupes = @($kids | ForEach-Object { [string](Get-Field $_ 'name' '') } | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count) { throw "'$Path/$name' has duplicate child names: $(($dupes | ForEach-Object { $_.Name }) -join ', ')." }
    foreach ($k in $kids) { Test-Node $k "$Path/$name" }
}
foreach ($root in $def.services) { Test-Node $root '' }

Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token
$before = Invoke-ZabbixApi -Method service.get -AllowEmpty -Params @{ output = 'extend'; selectParents = @('serviceid') }
Write-Host "Before snapshot: $(Save-ZabbixEvidence -Name 'service-tree-before' -Object $before -Dir $EvidenceDir)"

function ConvertTo-ProblemTags($Node) {
    , @(@(Get-Field $Node 'problemTags' @()) | ForEach-Object {
        @{ tag = [string]$_.tag; operator = $operators[[string](Get-Field $_ 'operator' 'equals')]; value = [string](Get-Field $_ 'value' '') } })
}
function Format-ProblemTags($Tags) {
    (@($Tags) | ForEach-Object { '{0}{1}{2}' -f $_.tag, $(if ([int]$_.operator -eq 2) { '~' } else { '=' }), $_.value }) -join ' AND '
}

function Find-Service([string]$Name, $ParentId) {
    $rows = Invoke-ZabbixApi -Method service.get -AllowEmpty -Params @{
        filter = @{ name = $Name }; output = @('serviceid', 'name'); selectParents = @('serviceid'); selectProblemTags = 'extend' }
    foreach ($s in $rows) {
        $parents = @($s.parents | ForEach-Object { [string]$_.serviceid })
        if ((-not $ParentId -and $parents.Count -eq 0) -or ($ParentId -and $parents -contains [string]$ParentId)) { return $s }
    }
    $null
}

$stats = @{ created = 0; kept = 0; planned = 0 }
function Build-Node($Node, $ParentId, [int]$Depth, [bool]$ParentPlanned, [ref]$Order) {
    $name = [string]$Node.name
    $label = ('  ' * $Depth) + $name
    $pt = ConvertTo-ProblemTags $Node
    $ptText = if ($pt.Count) { "   [$(Format-ProblemTags $pt)]" } else { '' }
    $sid = $null
    $existing = if ($ParentPlanned) { $null } else { Find-Service $name $ParentId }
    if ($existing) {
        $sid = [string]$existing.serviceid
        $stats.kept++
        Write-Host "= $label (exists $sid)"
        $have = Format-ProblemTags @(Get-Field $existing 'problem_tags' @() | Sort-Object tag, value)
        $want = Format-ProblemTags @($pt | ForEach-Object { [pscustomobject]$_ } | Sort-Object tag, value)
        if ($have -ne $want) { Write-Warning "'$name' exists with different problem tags (server: [$have], file: [$want]). Not changed." }
    } else {
        $params = @{ name = $name; algorithm = $algorithms[[string](Get-Field $Node 'algorithm' 'mostCritical')]
                     sortorder = $Order.Value; description = [string](Get-Field $Node 'description' '') }
        if ($pt.Count) { $params['problem_tags'] = $pt }
        $tagObj = Get-Field $Node 'tags'
        if ($tagObj) { $params['tags'] = @($tagObj.PSObject.Properties | ForEach-Object { @{ tag = $_.Name; value = [string]$_.Value } }) }
        if ($ParentId) { $params['parents'] = @(@{ serviceid = [string]$ParentId }) }
        if (-not $ParentPlanned -and $PSCmdlet.ShouldProcess($name, 'service.create')) {
            $r = Invoke-ZabbixApi -Method service.create -Params $params
            $sid = [string]$r[0].serviceids[0]
            $stats.created++
            Write-Host "+ $label (created $sid)$ptText"
        } else {
            $stats.planned++
            Write-Host "+ $label (would create)$ptText"
        }
    }
    $Order.Value++
    foreach ($child in @(Get-Field $Node 'children' @())) {
        # A parent that was not created has no id: its children are planned too, never looked up as roots.
        Build-Node $child $sid ($Depth + 1) (-not $sid) $Order
    }
}

foreach ($root in $def.services) {
    $order = 0
    Build-Node $root $null 0 $false ([ref]$order)
}
Write-Host ("Created {0}, kept {1}, would create {2}." -f $stats.created, $stats.kept, $stats.planned)
if ($stats.created -gt 0) {
    $after = Invoke-ZabbixApi -Method service.get -Params @{ output = 'extend'; selectParents = @('serviceid'); selectChildren = @('serviceid')
        selectProblemTags = 'extend'; selectTags = 'extend' }
    Write-Host "After snapshot: $(Save-ZabbixEvidence -Name 'service-tree-after' -Object $after -Dir $EvidenceDir)"
}
