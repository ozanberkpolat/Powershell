#Requires -Version 5.1
<#
.SYNOPSIS
    Lists the Zabbix web scenario items (website uptime) of a host group, one row per item.

.DESCRIPTION
    Finds the items of every web scenario on the enabled hosts of the group and classifies them:
      web.test.fail[scenario]            Metric fail  (0 = ok, otherwise the failed step number)
      web.test.time[scenario,step,resp]  Metric resp  (response time)
      web.test.in[scenario,step,bps]     Metric speed (download speed)
    Prints what will be measured (scenario list) before any slow follow-up work, so you notice early that you are
    about to collect the wrong estate. Feed the ItemId column to Get-ZabbixTrends.ps1.

    Trap: web scenario items are type 9 and item.get EXCLUDES them unless `webitems = true` is passed. Without it
    the call silently returns nothing, which looks like "this host has no scenarios".

.PARAMETER GroupName
    Host group(s) holding the hosts that carry the web scenarios.

.PARAMETER OutFile
    Optional CSV path.

.EXAMPLE
    .\Get-ZabbixWebScenarios.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -GroupName 'Contoso-Websites' -OutFile web.csv

.NOTES
    Read-only. Zero scenarios is an error (wrong group, or the scenarios sit on hosts outside it).
    Scenario names containing commas or brackets cannot be parsed from the key and are reported as unparsed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$GroupName,
    [string]$OutFile,
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

$gids = @($GroupName | ForEach-Object { Resolve-ZabbixHostGroup -Name $_ })
$hosts = Invoke-ZabbixApi -Method host.get -Params @{ output = @('hostid', 'host', 'name'); groupids = $gids; filter = @{ status = '0' } }
$hname = @{}; foreach ($h in $hosts) { $hname[[string]$h.hostid] = [string]$h.name }

$raw = Invoke-ZabbixApi -Method item.get -Params @{
    output = @('itemid', 'hostid', 'key_'); hostids = @($hosts | ForEach-Object { $_.hostid })
    webitems = $true; search = @{ key_ = 'web.test.' } }

$rows = @(); $unparsed = @()
foreach ($it in $raw) {
    $k = [string]$it.key_
    $metric = $null; $scenario = $null; $step = ''
    if ($k -match '^web\.test\.fail\[(.+)\]$') { $metric = 'fail'; $scenario = $Matches[1] }
    elseif ($k -match '^web\.test\.time\[(.+),(.+),resp\]$') { $metric = 'resp'; $scenario = $Matches[1]; $step = $Matches[2] }
    elseif ($k -match '^web\.test\.in\[(.+),(.+),bps\]$') { $metric = 'speed'; $scenario = $Matches[1]; $step = $Matches[2] }
    else { $unparsed += $k; continue }
    $rows += [pscustomobject]@{
        HostId = [string]$it.hostid; Host = $hname[[string]$it.hostid]; Scenario = $scenario
        Metric = $metric; Step = $step; ItemId = [string]$it.itemid; Key = $k }
}
if ($unparsed.Count) { Write-Warning "$($unparsed.Count) web.test item(s) not parsed (other metric or unusual key), for example: $($unparsed[0])" }
if ($rows.Count -eq 0) { throw "No web scenario items found on any host in '$($GroupName -join ', ')'. Check the group and that the scenarios sit on hosts inside it." }

$sites = @($rows | Group-Object HostId, Scenario)   # @(): one group would otherwise report its item count as .Count
Write-Host "$($sites.Count) scenario(s):"
foreach ($s in ($sites | Sort-Object Name)) { Write-Host ('    {0} - {1}  ({2} items)' -f $s.Group[0].Host, $s.Group[0].Scenario, $s.Count) }
if ($OutFile) { $rows | Export-Csv $OutFile -NoTypeInformation -Encoding UTF8; Write-Host "Wrote $OutFile" }
$rows
