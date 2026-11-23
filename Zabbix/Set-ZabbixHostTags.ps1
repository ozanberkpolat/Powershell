#Requires -Version 5.1
<#
.SYNOPSIS
    Adds business-service tags to Zabbix hosts by merging them into the existing tag list, and reconciles the
    environment tag with the PROD / NONPROD template each host is linked to.

.DESCRIPTION
    host.update REPLACES the whole tag list. This script therefore reads every target host's tags, keeps the ones it
    does not manage, replaces tags of the same name, and only then writes. A host whose tags are already correct is
    not touched.

    Two inputs, use either or both:
      * -TagFile: CSV with columns Host, Tag, Value (technical host name). One row per tag; a second row with the same
        Host and Tag replaces the first. See examples\host-tags.example.csv.
      * -CensusGroupName: every host in these groups is checked: the environment tag value expected from its linked
        templates (first matching -TemplateEnvironmentMap entry) against the actual tag. Mismatches are listed; with
        -ReconcileEnvironment they are also fixed.

    Refuses to run when a target host carries AUTOMATIC (discovered) tags: sending them back through host.update would
    turn them into manual tags. Before/after snapshots go to .\evidence.

.PARAMETER TagFile
    CSV with Host, Tag, Value.

.PARAMETER CensusGroupName
    Host group(s) for the environment census.

.PARAMETER EnvironmentTag
    Name of the environment tag. Default 'environment'.

.PARAMETER TemplateEnvironmentMap
    Ordered 'pattern=value' pairs matched (case sensitive, substring) against the names of a host's linked templates.
    The FIRST match wins, so list the longer pattern first: the default is 'NONPROD=nonprod', 'PROD=prod' because
    "PROD" is a substring of "NONPROD".

.PARAMETER ReconcileEnvironment
    Also correct the environment tag of every census mismatch (otherwise they are only listed).

.PARAMETER EvidenceDir
    Folder for the before/after JSON snapshots. Default .\evidence.

.PARAMETER Url
    Zabbix front end URL. Default: env ZABBIX_URL.

.PARAMETER TokenFile
    File with the API token. Default: env ZABBIX_TOKEN_FILE.

.PARAMETER Token
    API token as SecureString (alternative to TokenFile).

.EXAMPLE
    .\Set-ZabbixHostTags.ps1 -TagFile .\examples\host-tags.example.csv -CensusGroupName 'Contoso-Servers' -WhatIf

.EXAMPLE
    .\Set-ZabbixHostTags.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -CensusGroupName 'Contoso-Servers' -ReconcileEnvironment

.NOTES
    UNTESTED: -ReconcileEnvironment is new (the source only listed census mismatches).
    WRITE. Run with -WhatIf first. Token role needs read-write access to the hosts (host group permission Read-write).
    A host named in the file that does not exist stops the run before anything is written (no partial apply).
    Tags set here are what business service leaves (Set-ZabbixServiceTree.ps1) match: host tags are inherited by the
    problems of that host's triggers.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TagFile,
    [string[]]$CensusGroupName,
    [string]$EnvironmentTag = 'environment',
    [string[]]$TemplateEnvironmentMap = @('NONPROD=nonprod', 'PROD=prod'),
    [switch]$ReconcileEnvironment,
    [string]$EvidenceDir = (Join-Path (Get-Location) 'evidence'),
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
if (-not $TagFile -and -not $CensusGroupName) { throw 'Give -TagFile, -CensusGroupName, or both.' }
if ($ReconcileEnvironment -and -not $CensusGroupName) { throw '-ReconcileEnvironment needs -CensusGroupName.' }

# Wanted tags per host: ordered so the output reads in file order.
$wanted = [ordered]@{}
if ($TagFile) {
    $rows = @(Import-Csv $TagFile)
    if ($rows.Count -eq 0) { throw "$TagFile has no rows." }
    foreach ($c in 'Host', 'Tag', 'Value') { if ($rows[0].PSObject.Properties.Name -notcontains $c) { throw "$TagFile has no '$c' column." } }
    foreach ($r in $rows) {
        if (-not $r.Host -or -not $r.Tag) { throw "$TagFile has a row without Host or Tag." }
        if (-not $wanted.Contains($r.Host)) { $wanted[$r.Host] = [ordered]@{} }
        $wanted[$r.Host][$r.Tag] = [string]$r.Value
    }
}
$map = @(foreach ($m in $TemplateEnvironmentMap) {
    $p = $m.Split('=', 2)
    if ($p.Count -ne 2 -or -not $p[0]) { throw "TemplateEnvironmentMap entry '$m' is not pattern=value." }
    , @($p[0], $p[1])
})

. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

# --- environment census ---------------------------------------------------------------------------
if ($CensusGroupName) {
    $gids = @($CensusGroupName | ForEach-Object { Resolve-ZabbixHostGroup -Name $_ })
    $census = Invoke-ZabbixApi -Method host.get -Params @{ groupids = $gids; output = @('host'); selectTags = 'extend'; selectParentTemplates = @('name') }
    $mismatch = @()
    foreach ($h in $census) {
        $names = (@($h.parentTemplates) | ForEach-Object { $_.name }) -join ' '
        $expected = $null
        foreach ($m in $map) { if ($names.Contains($m[0])) { $expected = $m[1]; break } }
        $actual = @(@($h.tags) | Where-Object { $_.tag -eq $EnvironmentTag } | ForEach-Object { $_.value })
        if ($expected -and ($actual.Count -ne 1 -or $actual[0] -ne $expected)) {
            $mismatch += [pscustomobject]@{ Host = $h.host; Tag = ($actual -join ','); Template = $expected }
        }
    }
    Write-Host "Environment census: $(@($census).Count) host(s), $($mismatch.Count) mismatch(es) against the template."
    foreach ($m in ($mismatch | Sort-Object Host)) {
        $note = if ($wanted.Contains($m.Host)) { '' } elseif ($ReconcileEnvironment) { '   <-- will be reconciled' } else { '   <-- not in the tag file' }
        Write-Host ("  {0}: tag=[{1}] template={2}{3}" -f $m.Host, $m.Tag, $m.Template, $note)
        if ($ReconcileEnvironment -and -not ($wanted.Contains($m.Host) -and $wanted[$m.Host].Contains($EnvironmentTag))) {
            if (-not $wanted.Contains($m.Host)) { $wanted[$m.Host] = [ordered]@{} }
            $wanted[$m.Host][$EnvironmentTag] = $m.Template
        }
    }
}
if ($wanted.Count -eq 0) { Write-Host 'Nothing to change.'; return }

# --- read targets, guard, plan --------------------------------------------------------------------
$names = @($wanted.Keys)
$hosts = Invoke-ZabbixApi -Method host.get -Params @{ filter = @{ host = $names }; output = @('hostid', 'host'); selectTags = 'extend' }
$missing = @($names | Where-Object { @($hosts | ForEach-Object { $_.host }) -notcontains $_ })
if ($missing.Count) { throw "Target host(s) not found (technical name expected): $($missing -join ', '). Nothing was changed." }
$automatic = @(foreach ($h in $hosts) { foreach ($t in @($h.tags)) {
    if ($t.PSObject.Properties.Name -contains 'automatic' -and [string]$t.automatic -eq '1') { "$($h.host):$($t.tag)" } } })
if ($automatic.Count) { throw "Automatic (discovered) tags present; host.update would turn them manual: $($automatic -join ', ')." }
Write-Host "Before snapshot: $(Save-ZabbixEvidence -Name 'host-tags-before' -Object $hosts -Dir $EvidenceDir)"

$changed = 0
foreach ($h in $hosts) {
    $want = $wanted[$h.host]
    $old = @(@($h.tags) | ForEach-Object { @{ tag = [string]$_.tag; value = [string]$_.value } })
    $new = @($old | Where-Object { -not $want.Contains($_.tag) }) + @($want.Keys | ForEach-Object { @{ tag = $_; value = $want[$_] } })
    $fmt = { param($l) (@($l | ForEach-Object { "$($_.tag)=$($_.value)" }) | Sort-Object) -join ', ' }
    if ((& $fmt $old) -eq (& $fmt $new)) { Write-Host "= $($h.host): already correct"; continue }
    Write-Host "~ $($h.host): [$(& $fmt $old)] -> [$(& $fmt $new)]"
    if ($PSCmdlet.ShouldProcess($h.host, 'host.update tags')) {
        [void](Invoke-ZabbixApi -Method host.update -Params @{ hostid = $h.hostid; tags = $new })
        $changed++
    }
}
if ($changed) {
    $after = Invoke-ZabbixApi -Method host.get -Params @{ filter = @{ host = $names }; output = @('hostid', 'host'); selectTags = 'extend' }
    Write-Host "Applied $changed host(s). After snapshot: $(Save-ZabbixEvidence -Name 'host-tags-after' -Object $after -Dir $EvidenceDir)"
}
