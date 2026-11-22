#Requires -Version 5.1
<#
.SYNOPSIS
    Fetches Zabbix trend.get data in chunks and streams it straight to a file.

.DESCRIPTION
    A fleet over two months is about a million trend rows; holding them in a PowerShell array costs gigabytes before
    ConvertTo-Json starts. This script requests -ChunkSize items per call, writes each row to the file as it arrives and
    keeps only a counter in memory.

    Output fields: itemid, clock (epoch seconds, start of the hour), num (samples in the hour), value_min, value_avg,
    value_max. Item IDs come from -ItemId or from the ItemId column of a CSV (for example the output of
    Get-ZabbixUtilizationItems.ps1 filtered to Trended = True, or Get-ZabbixWebScenarios.ps1).

    Zero rows in total is an error: the usual causes are an item whose trend storage is 0 (`trends` = 0 keeps no
    trends), a period older than the retention, a text/log item (trends exist for numeric items only) or a token
    without access to the item's host. Chunks that return nothing are counted and reported.

.PARAMETER ItemId
    Item IDs.

.PARAMETER ItemsFile
    CSV with an ItemId column (rows with an empty ItemId are ignored). If a Trended column exists only rows with Trended = True are used.

.PARAMETER From
    Start of the period (inclusive), DateTimeOffset. Give an explicit offset for non-UTC month windows,
    for example 2026-05-01T00:00:00+02:00.

.PARAMETER Till
    End of the period. trend.get treats time_till as inclusive; pass the first instant of the next period minus one second to avoid an extra hour row.

.PARAMETER OutFile
    Output path. .csv (default format) or .json (a streamed JSON array).

.PARAMETER ChunkSize
    Items per call. Default 50; web scenario items work with 150.

.EXAMPLE
    .\Get-ZabbixTrends.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -ItemsFile items.csv `
        -From 2026-05-01T00:00:00+02:00 -Till 2026-05-31T23:59:59+02:00 -OutFile trends.csv

.NOTES
    Read-only. Streamed with a .part file that is renamed on success, so a partial file is never mistaken for a result.
    Progress is shown with Write-Progress.
#>
[CmdletBinding()]
param(
    [string[]]$ItemId,
    [string]$ItemsFile,
    [Parameter(Mandatory)][DateTimeOffset]$From,
    [Parameter(Mandatory)][DateTimeOffset]$Till,
    [Parameter(Mandatory)][string]$OutFile,
    [ValidateRange(1, 500)][int]$ChunkSize = 50,
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
if ($Till -le $From) { throw 'Till must be after From.' }
$ids = @($ItemId)
if ($ItemsFile) {
    $csv = @(Import-Csv $ItemsFile)
    if ($csv.Count -eq 0) { throw "$ItemsFile has no rows." }
    if ($csv[0].PSObject.Properties.Name -contains 'Trended') { $csv = @($csv | Where-Object { $_.Trended -eq 'True' }) }
    $ids += @($csv | ForEach-Object { $_.ItemId } | Where-Object { $_ })
}
$ids = @($ids | Where-Object { $_ } | Sort-Object -Unique)
if ($ids.Count -eq 0) { throw 'No item IDs. Pass -ItemId or -ItemsFile.' }

. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

$t0 = $From.ToUnixTimeSeconds(); $t1 = $Till.ToUnixTimeSeconds()
$isJson = $OutFile -like '*.json'
$part = "$OutFile.part"
$enc = New-Object System.Text.UTF8Encoding($false)
$w = New-Object System.IO.StreamWriter($part, $false, $enc)
$n = 0; $emptyChunks = 0
try {
    if ($isJson) { $w.Write('[') } else { $w.WriteLine('itemid,clock,num,value_min,value_avg,value_max') }
    for ($i = 0; $i -lt $ids.Count; $i += $ChunkSize) {
        $end = [Math]::Min($i + $ChunkSize - 1, $ids.Count - 1)
        $done = [Math]::Min($i + $ChunkSize, $ids.Count)
        $rows = Invoke-ZabbixApi -Method trend.get -AllowEmpty -Params @{
            output = @('itemid', 'clock', 'num', 'value_min', 'value_avg', 'value_max'); itemids = @($ids[$i..$end]); time_from = $t0; time_till = $t1 }
        if (@($rows).Count -eq 0) { $emptyChunks++ }
        foreach ($r in $rows) {
            if ($isJson) {
                if ($n -gt 0) { $w.Write(',') }
                $w.Write('{"itemid":"' + $r.itemid + '","clock":"' + $r.clock + '","num":"' + $r.num + '","value_min":"' + $r.value_min + '","value_avg":"' + $r.value_avg + '","value_max":"' + $r.value_max + '"}')
            } else {
                $w.WriteLine(($r.itemid, $r.clock, $r.num, $r.value_min, $r.value_avg, $r.value_max) -join ',')
            }
            $n++
        }
        Write-Progress -Activity 'trend.get' -Status "$done / $($ids.Count) items, $n rows" -PercentComplete ([int](100 * $done / $ids.Count))
    }
    if ($isJson) { $w.Write(']') }
} finally {
    $w.Dispose()
    Write-Progress -Activity 'trend.get' -Completed
}
if ($n -eq 0) {
    Remove-Item $part -Force
    throw "trend.get returned 0 rows for $($ids.Count) item(s). Check item trend storage (trends=0), retention, item type and token access."
}
if ($emptyChunks -gt 0) { Write-Warning "$emptyChunks chunk(s) of $ChunkSize item(s) returned no rows. Some items have no trends in this period." }
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
Move-Item $part $OutFile
Write-Host "Wrote $n rows for $($ids.Count) item(s) to $OutFile"
