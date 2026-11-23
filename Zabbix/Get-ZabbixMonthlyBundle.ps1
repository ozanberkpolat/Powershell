#Requires -Version 5.1
<#
.SYNOPSIS
    Collects one monthly report bundle from Zabbix: VM utilisation (hosts, chosen items, trends) and, optionally,
    web scenario uptime (scenario items, trends), cut on whole-month boundaries in a given time zone.

.DESCRIPTION
    Orchestrates the read scripts in this folder and writes their output into one folder (optionally zipped):

        hosts.csv        Get-ZabbixHostsByGroup.ps1      enabled hosts of the VM group(s), with OS
        items.csv        Get-ZabbixUtilizationItems.ps1  one CPU / memory / core / filesystem item per purpose
        vm-trends.csv    Get-ZabbixTrends.ps1            hourly trends of the Trended = True items (chunk 50)
        web.csv          Get-ZabbixWebScenarios.ps1      web.test.fail / time / in items      (only with -WebGroupName)
        web-trends.csv   Get-ZabbixTrends.ps1            hourly trends of the web items (chunk 150)  (only with -WebGroupName)
        manifest.json    this script                     window (epoch, local, UTC), time zone, groups, row counts

    The split that makes the bundle useful: this script FETCHES AND SELECTS items, nothing else. Item selection
    has to happen before the fetch (trends of every per-core CPU item on a 32-core host are 33 times the volume of
    the one aggregate item). Everything after that, business hours, thresholds, bands, availability, sizing, is
    meaning and belongs to whatever reads the bundle, so a stored bundle can be re-scored without another VPN
    session. The scoring rules used with this bundle are documented in report-rules.md.

    Month window: whole months in -TimeZone, from the first day of the first month 00:00 local to the first day of
    the month after -EndMonth 00:00 local. Each boundary gets its OWN UTC offset, so a window that crosses a
    daylight saving change is still exact (a fixed offset mis-buckets every hour on the far side of the change).
    trend.get treats time_till as inclusive, so the end passed on is the next month start minus one second.

.PARAMETER VmGroupName
    Host group(s) with the servers for the utilisation half. Required: on a shared Zabbix an unscoped collection
    pulls other customers' hosts into the report.

.PARAMETER WebGroupName
    Host group(s) holding the hosts that carry the web scenarios. Omit to skip the uptime half.

.PARAMETER TimeZone
    Time zone the months are cut in: a Windows ID ('Eastern Standard Time') or an IANA ID ('America/New_York').
    IANA IDs need pwsh 7 (.NET 6 or newer) on Windows; Windows PowerShell 5.1 accepts Windows IDs only.

.PARAMETER Months
    Number of whole months to collect, ending with EndMonth. Default 1. A two-month fleet is about a million trend rows.

.PARAMETER EndMonth
    Last month to include, 'yyyy-MM'. Default: the last complete month in TimeZone.

.PARAMETER OutDir
    Output folder. Default: .\zabbix-bundle-<EndMonth>. An existing non-empty folder is refused unless -Force.

.PARAMETER Zip
    Also write <OutDir>.zip.

.PARAMETER Force
    Allow writing into an existing non-empty OutDir (files with the same name are replaced).

.PARAMETER Url
    Zabbix front end URL. Default: env ZABBIX_URL.

.PARAMETER TokenFile
    File with the API token. Default: env ZABBIX_TOKEN_FILE.

.PARAMETER Token
    API token as SecureString (alternative to TokenFile).

.EXAMPLE
    .\Get-ZabbixMonthlyBundle.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token `
        -VmGroupName 'Contoso-Servers' -WebGroupName 'Contoso-Websites' -TimeZone 'Eastern Standard Time'

.EXAMPLE
    # three months ending with May 2026, UK months, zipped
    .\Get-ZabbixMonthlyBundle.ps1 -VmGroupName 'Contoso-Servers' -TimeZone 'GMT Standard Time' -Months 3 -EndMonth 2026-05 -Zip

.NOTES
    Read-only. API token with read access to the host groups, their items and trends. Uses Invoke-ZabbixApi.ps1 and the
    four Get-Zabbix* scripts from this folder; each of them connects on its own, so a dropped VPN fails at the step
    that was running and the files already written stay valid (the trend files are written as .part and renamed).
    Every step fails loud on an empty result: no hosts, no items, no scenarios or zero trend rows stop the run.
    Typical run time for 50 hosts and one month: a few minutes, most of it trend.get.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$VmGroupName,
    [string[]]$WebGroupName,
    [Parameter(Mandatory)][string]$TimeZone,
    [ValidateRange(1, 12)][int]$Months = 1,
    [ValidatePattern('^\d{4}-(0[1-9]|1[0-2])$')][string]$EndMonth,
    [string]$OutDir,
    [switch]$Zip,
    [switch]$Force,
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$collector = 'Get-ZabbixMonthlyBundle 1.0'

# --- time zone and window ------------------------------------------------------------------------
$tz = $null
try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZone) } catch {
    $winId = $null
    # .NET 6+ converts IANA to Windows IDs; Windows PowerShell 5.1 has no such method.
    $m = [System.TimeZoneInfo].GetMethod('TryConvertIanaIdToWindowsId', [type[]]@([string], [string].MakeByRefType()))
    if ($m) { $args2 = @($TimeZone, $null); if ($m.Invoke($null, $args2)) { $winId = $args2[1] } }
    if ($winId) { try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($winId) } catch { $tz = $null } }
}
if (-not $tz) { throw "Time zone '$TimeZone' not found on this machine. Use a Windows ID (Get-TimeZone -ListAvailable | Select Id) or an IANA ID on pwsh 7." }

if (-not $EndMonth) {
    $nowLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
    $EndMonth = (New-Object datetime $nowLocal.Year, $nowLocal.Month, 1).AddMonths(-1).ToString('yyyy-MM')
}
$endStart = [datetime]::ParseExact($EndMonth, 'yyyy-MM', [cultureinfo]::InvariantCulture)
$endLocal = [datetime]::SpecifyKind($endStart.AddMonths(1), [System.DateTimeKind]::Unspecified)   # exclusive end
$startLocal = $endLocal.AddMonths(-$Months)

function ConvertTo-ZoneOffset([datetime]$Local) {
    # Own offset per boundary (DST-safe). ConvertTimeToUtc throws on a local time that does not exist in the zone.
    $utc = [System.TimeZoneInfo]::ConvertTimeToUtc($Local, $tz)
    ([DateTimeOffset]::new([datetime]::SpecifyKind($utc, [System.DateTimeKind]::Utc))).ToOffset($tz.GetUtcOffset($utc))
}
$from = ConvertTo-ZoneOffset $startLocal
$endExcl = ConvertTo-ZoneOffset $endLocal
$till = $endExcl.AddSeconds(-1)     # trend.get time_till is inclusive
if ($endExcl.UtcDateTime -gt [datetime]::UtcNow) { Write-Warning "The window ends in the future ($($endExcl.ToString('u'))): the last month is incomplete." }

if (-not $OutDir) { $OutDir = Join-Path (Get-Location) "zabbix-bundle-$EndMonth" }
if ((Test-Path $OutDir) -and @(Get-ChildItem $OutDir -Force).Count -gt 0 -and -not $Force) {
    throw "$OutDir exists and is not empty. Pass -Force to overwrite, or choose another -OutDir."
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

Write-Host ("Window: {0} .. {1} ({2}), {3} month(s)" -f $from.ToString('yyyy-MM-dd HH:mm zzz'), $till.ToString('yyyy-MM-dd HH:mm:ss zzz'), $tz.Id, $Months)
Write-Host "VM groups: $($VmGroupName -join ', ')   Web groups: $(if ($WebGroupName) { $WebGroupName -join ', ' } else { '(skipped)' })"

# --- collect: reuse the folder's scripts, do not re-implement their selection rules -------------
$z = @{}
foreach ($k in 'Url', 'TokenFile', 'Token') { if ($PSBoundParameters.ContainsKey($k)) { $z[$k] = $PSBoundParameters[$k] } }
$f = @{
    hosts = Join-Path $OutDir 'hosts.csv'; items = Join-Path $OutDir 'items.csv'; vmTrends = Join-Path $OutDir 'vm-trends.csv'
    web = Join-Path $OutDir 'web.csv'; webTrends = Join-Path $OutDir 'web-trends.csv'
}
$counts = [ordered]@{}
# Count lines instead of Import-Csv: a fleet-month trend file is about a million rows.
function Get-DataRowCount([string]$Path) { $n = -1; foreach ($l in [System.IO.File]::ReadLines($Path)) { $n++ }; [Math]::Max($n, 0) }

Write-Host '--- VM: hosts'
$hosts = @(& (Join-Path $PSScriptRoot 'Get-ZabbixHostsByGroup.ps1') @z -GroupName $VmGroupName -OutFile $f.hosts)
$counts['hosts'] = $hosts.Count
Write-Host '--- VM: item selection'
$items = @(& (Join-Path $PSScriptRoot 'Get-ZabbixUtilizationItems.ps1') @z -GroupName $VmGroupName -OutFile $f.items)
$counts['vm_items'] = $items.Count
$counts['vm_items_trended'] = @($items | Where-Object { $_.Trended }).Count
Write-Host '--- VM: trends'
& (Join-Path $PSScriptRoot 'Get-ZabbixTrends.ps1') @z -ItemsFile $f.items -From $from -Till $till -OutFile $f.vmTrends -ChunkSize 50
$counts['vm_trend_rows'] = Get-DataRowCount $f.vmTrends

if ($WebGroupName) {
    Write-Host '--- Web: scenario items'
    $web = @(& (Join-Path $PSScriptRoot 'Get-ZabbixWebScenarios.ps1') @z -GroupName $WebGroupName -OutFile $f.web)
    $counts['web_items'] = $web.Count
    $counts['web_scenarios'] = @($web | Group-Object HostId, Scenario).Count
    Write-Host '--- Web: trends'
    & (Join-Path $PSScriptRoot 'Get-ZabbixTrends.ps1') @z -ItemsFile $f.web -From $from -Till $till -OutFile $f.webTrends -ChunkSize 150
    $counts['web_trend_rows'] = Get-DataRowCount $f.webTrends
}

# --- manifest ------------------------------------------------------------------------------------
$manifest = [ordered]@{
    schema = 1; collector = $collector; collectedAtUtc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    zabbix = $(if ($z.ContainsKey('Url')) { $z['Url'] } else { $env:ZABBIX_URL })
    timeZone = $tz.Id; months = $Months; endMonth = $EndMonth
    window = [ordered]@{
        from = $from.ToUnixTimeSeconds(); till = $till.ToUnixTimeSeconds()
        fromLocal = $from.ToString('o'); tillLocal = $till.ToString('o'); note = 'till is inclusive (next month start - 1 s)'
    }
    vmGroups = @($VmGroupName); webGroups = @($WebGroupName | Where-Object { $_ })
    files = @(Get-ChildItem $OutDir -File -Filter *.csv | ForEach-Object { $_.Name })
    counts = $counts
}
$manifest | ConvertTo-Json -Depth 6 | Out-File (Join-Path $OutDir 'manifest.json') -Encoding utf8

Write-Host ''
Write-Host "Bundle: $OutDir"
$counts.GetEnumerator() | ForEach-Object { Write-Host ('  {0,-18} {1}' -f $_.Key, $_.Value) }
if ($Zip) {
    $zipPath = "$OutDir.zip"
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force
    Write-Host "Zip:    $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 2)) MB)"
}
