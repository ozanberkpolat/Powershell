#Requires -Version 5.1
<#
.SYNOPSIS
    Lists the enabled hosts of one or more Zabbix host groups with their operating system.

.DESCRIPTION
    Resolves each group name (a miss lists the group names that exist), reads the enabled hosts and their inventory
    OS field, and falls back to the latest value of system.sw.os / system.uname for hosts whose inventory is empty.
    Zero hosts is an error, not a clean result: a wrong group name or a token without access looks the same as an empty group.

.PARAMETER GroupName
    One or more host group names, exactly as in Zabbix.

.PARAMETER IncludeDisabled
    Also return disabled hosts.

.PARAMETER Url
    Zabbix front end URL. Default: env ZABBIX_URL.

.PARAMETER TokenFile
    File with the API token. Default: env ZABBIX_TOKEN_FILE.

.PARAMETER Token
    API token as SecureString (alternative to TokenFile).

.PARAMETER OutFile
    Optional .csv or .json output path.

.EXAMPLE
    .\Get-ZabbixHostsByGroup.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -GroupName 'Contoso-Servers'

.NOTES
    Read-only. API token needs read access to the host group. Uses Invoke-ZabbixApi.ps1 from this folder.
    Without a group filter the same call would return every customer's servers on a shared Zabbix; this script has no
    "all hosts" mode on purpose.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$GroupName,
    [switch]$IncludeDisabled,
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

$gids = @($GroupName | ForEach-Object { Resolve-ZabbixHostGroup -Name $_ })
$p = @{ output = @('hostid', 'host', 'name', 'status'); groupids = $gids; selectInventory = @('os'); selectHostGroups = @('name'); sortfield = 'name' }
if (-not $IncludeDisabled) { $p['filter'] = @{ status = '0' } }
$hostsRaw = Invoke-ZabbixApi -Method host.get -Params $p    # throws on zero hosts
$ids = @($hostsRaw | ForEach-Object { $_.hostid })
Write-Host "$($ids.Count) host(s) in: $($GroupName -join ', ')"

$osById = @{}
foreach ($h in $hostsRaw) {
    $os = ''
    if ($h.inventory -and $h.inventory.PSObject.Properties.Name -contains 'os' -and $h.inventory.os) { $os = [string]$h.inventory.os }
    $osById[[string]$h.hostid] = $os
}
foreach ($key in 'system.sw.os', 'system.uname') {
    $items = Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ output = @('hostid', 'lastvalue'); hostids = $ids; search = @{ key_ = $key } }
    foreach ($it in $items) {
        if (-not $osById[[string]$it.hostid] -and $it.lastvalue) { $osById[[string]$it.hostid] = [string]$it.lastvalue }
    }
}

$rows = foreach ($h in $hostsRaw) {
    [pscustomobject]@{
        HostId  = [string]$h.hostid
        Host    = $h.host
        Name    = $h.name
        Enabled = ($h.status -eq '0')
        OS      = $(if ($osById[[string]$h.hostid]) { $osById[[string]$h.hostid] } else { 'N/A' })
        Groups  = (($h.hostgroups | ForEach-Object { $_.name }) -join ';')
    }
}
if ($OutFile) {
    if ($OutFile -like '*.json') { $rows | ConvertTo-Json -Depth 5 | Out-File $OutFile -Encoding utf8 }
    else { $rows | Export-Csv $OutFile -NoTypeInformation -Encoding UTF8 }
    Write-Host "Wrote $OutFile"
}
$rows
