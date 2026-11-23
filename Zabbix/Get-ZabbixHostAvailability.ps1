#Requires -Version 5.1
<#
.SYNOPSIS
    Collects availability evidence for one host over a period (typically a quarter) from Zabbix trends and events.

.DESCRIPTION
    Evidence for an availability or SLA statement, built only from what Zabbix stored:
      1. agent.ping trend per hour: `num` is the number of samples that hour (60 expected at a 1 minute interval).
         Hours with fewer samples are "short hours"; the missing samples approximate the minutes the host did not report.
      2. system.boottime trend: a changed value between hours marks a reboot (the value is the boot time, epoch).
         Windows templates have no system.boottime, and system.uptime usually keeps no trends (short history only).
         For such hosts the reboots come from the "has been restarted" trigger events instead, plus a look-back
         window before the period that finds the boot the period starts from.
      3. Peer check: for every short hour, how many other hosts monitored through the SAME proxy were also short or
         silent. If most peers are short too, the gap is a platform, proxy or network problem, not a host outage.
      4. Trigger events for the agent-unavailable and restarted triggers, and server events that mention the proxy.
      5. Platform events around every short hour (from 30 minutes before to 90 minutes after) whose name mentions
         the proxy, the Zabbix server or a version change: the evidence for the "cause" column of a gap table.
    Everything is written to one JSON evidence file; a summary object is returned.

    Loud failures: the host must exist exactly once, agent.ping must exist, and every trend fetched must be non-empty;
    a host without system.boottime must have a restart trigger and a restart event in the look-back window.
    Missing triggers (template renamed) give a warning, not silence.

.PARAMETER HostName
    The Zabbix technical host name (the `host` field).

.PARAMETER From
    Start of the period, DateTimeOffset with an explicit offset (a quarter in a local zone starts at local midnight).

.PARAMETER To
    End of the period (exclusive), DateTimeOffset. Both are floored to the hour.

.PARAMETER ExpectedPerHour
    Expected agent.ping samples per hour. Default 60. The item's own delay is printed; if it is not 1m, set this.

.PARAMETER PeerShare
    A short hour is attributed to the platform when at least this share of the peers was short or silent. Default 0.5.

.PARAMETER TriggerSearch
    Trigger description fragments for agent-unavailable and restart events. Defaults are the standard template names.

.PARAMETER BootLookbackDays
    Days before From searched for restart events when the host has no system.boottime item. Default 40.
    Zero restarts in that window is an error: without it the period has no known starting boot.

.PARAMETER PlatformEventSearch
    Event name fragments collected around each short hour. Default: proxy, Zabbix server, Version has changed.

.PARAMETER OutFile
    Evidence JSON path. Default: .\availability-<host>-<yyyyMMdd>.json.

.EXAMPLE
    .\Get-ZabbixHostAvailability.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -HostName SRV01 `
        -From 2026-07-01T00:00:00+03:00 -To 2026-10-01T00:00:00+03:00

.NOTES
    Read-only; needs read access to the host, its proxy, the peers' agent.ping items and events.
    Port of an ad-hoc extraction script. trend.get time_till is inclusive, so To is passed as To - 1 second.
    Proxy field differs by version: `proxyid` (7.0+) or `proxy_hostid` (6.4); a host monitored by the server directly
    has no proxy and the peer check is skipped with a warning. This is evidence of reporting gaps, not a root cause:
    a host that was up but unable to reach its proxy looks identical to a host that was down.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][DateTimeOffset]$From,
    [Parameter(Mandatory)][DateTimeOffset]$To,
    [int]$ExpectedPerHour = 60,
    [double]$PeerShare = 0.5,
    [string[]]$TriggerSearch = @('Zabbix agent is not available', 'has been restarted'),
    [ValidateRange(1, 365)][int]$BootLookbackDays = 40,
    [string[]]$PlatformEventSearch = @('proxy', 'Zabbix server', 'Version has changed'),
    [string]$OutFile,
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
if ($To -le $From) { throw 'To must be after From.' }
. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

function Get-Trends($ItemIds, [long]$T0, [long]$T1) {
    $out = @()
    $ItemIds = @($ItemIds)
    for ($i = 0; $i -lt $ItemIds.Count; $i += 20) {
        $end = [Math]::Min($i + 19, $ItemIds.Count - 1)
        $out += Invoke-ZabbixApi -Method trend.get -AllowEmpty -Params @{
            itemids = @($ItemIds[$i..$end]); time_from = $T0; time_till = $T1 - 1
            output = @('itemid', 'clock', 'num', 'value_min', 'value_max') }
    }
    $out
}
function Get-Events($Params) {
    # Assign, then emit: Invoke-ZabbixApi returns ONE array object, and @(Get-Events) must see the rows, not a nested array.
    $r = Invoke-ZabbixApi -Method event.get -AllowEmpty -Params ($Params + @{ source = 0; object = 0
        output = @('eventid', 'clock', 'value', 'name', 'r_eventid', 'objectid'); sortfield = @('clock') })
    $r
}

# Floor to the hour so every bucket lines up with Zabbix's hourly trend clock.
$t0 = [long]([Math]::Floor($From.ToUnixTimeSeconds() / 3600) * 3600)
$t1 = [long]([Math]::Floor($To.ToUnixTimeSeconds() / 3600) * 3600)
if ($t0 -ne $From.ToUnixTimeSeconds()) { Write-Warning 'From was not on a full hour; floored.' }

$hostRows = Invoke-ZabbixApi -Method host.get -Params @{ filter = @{ host = @($HostName) }; output = 'extend' }
if ($hostRows.Count -ne 1) { throw "Expected exactly one host named '$HostName', got $($hostRows.Count)." }
$hostRow = $hostRows[0]
$proxyId = $null
foreach ($f in 'proxyid', 'proxy_hostid') {
    if ($hostRow.PSObject.Properties.Name -contains $f -and $hostRow.$f -and $hostRow.$f -ne '0') { $proxyId = [string]$hostRow.$f; break }
}

$itemRows = Invoke-ZabbixApi -Method item.get -Params @{ hostids = $hostRow.hostid; filter = @{ key_ = @('system.boottime', 'agent.ping') }; output = @('itemid', 'key_', 'delay', 'trends', 'history') }
$items = @{}; foreach ($i in $itemRows) { $items[[string]$i.key_] = $i }
if (-not $items.ContainsKey('agent.ping')) { throw "Item agent.ping is missing on $HostName (found: $($items.Keys -join ', '))." }
# Windows templates have no system.boottime: reboots then come from the restart trigger (see below), never silence.
$hasBoot = $items.ContainsKey('system.boottime')
if (-not $hasBoot) { Write-Warning "No system.boottime item on $HostName (typical for Windows): reboots are taken from the restart trigger events." }
if ($items['agent.ping'].delay -ne '1m' -and $ExpectedPerHour -eq 60) {
    Write-Warning "agent.ping delay is '$($items['agent.ping'].delay)', not 1m: the expected 60 samples per hour is probably wrong. Set -ExpectedPerHour."
}

$boot = @()
if ($hasBoot) {
    $boot = @(Get-Trends @($items['system.boottime'].itemid) $t0 $t1)
    if ($boot.Count -eq 0) { throw 'EMPTY RESULT: system.boottime trends in the period (trend storage 0, or the period is older than retention).' }
}
$ping = @(Get-Trends @($items['agent.ping'].itemid) $t0 $t1)
if ($ping.Count -eq 0) { throw 'EMPTY RESULT: agent.ping trends in the period (trend storage 0, or the period is older than retention).' }

# Hour table: an hour with no trend row has 0 samples.
$hours = [ordered]@{}
for ($h = $t0; $h -lt $t1; $h += 3600) { $hours[[string]$h] = 0 }
foreach ($r in $ping) { if ($hours.Contains([string]$r.clock)) { $hours[[string]$r.clock] = [int]$r.num } }
$short = @($hours.Keys | Where-Object { $hours[$_] -lt $ExpectedPerHour })

# Peers on the same proxy
$peerGap = @(); $proxy = $null; $peerItems = @()
if ($proxyId) {
    $proxyRows = Invoke-ZabbixApi -Method proxy.get -Params @{ proxyids = $proxyId; output = 'extend' }
    $proxy = $proxyRows[0]
    $peers = Invoke-ZabbixApi -Method host.get -Params @{ proxyids = $proxyId; output = @('hostid', 'host'); filter = @{ status = '0' } }
    $peerIds = @($peers | Where-Object { $_.hostid -ne $hostRow.hostid } | ForEach-Object { $_.hostid })
    if ($peerIds.Count -gt 0) {
        $peerItems = @((Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ hostids = $peerIds; filter = @{ key_ = 'agent.ping' }; output = @('itemid', 'hostid') }))
    }
    if ($peerItems.Count -eq 0) { Write-Warning 'No peer agent.ping items on the same proxy: the host-versus-platform split is not available.' }
    elseif ($short.Count -gt 200) { Write-Warning "$($short.Count) short hours: the peer check issues one query per hour and will be slow." }
    $peerItemIds = @($peerItems | ForEach-Object { $_.itemid })
    foreach ($h in $short) {
        $hStart = [long]$h
        $peerShort = 0; $silent = 0
        if ($peerItemIds.Count -gt 0) {
            $rows = @(Get-Trends $peerItemIds $hStart ($hStart + 3600))
            $reporting = @($rows | ForEach-Object { $_.itemid } | Sort-Object -Unique)
            $peerShort = @($rows | Where-Object { [int]$_.num -lt $ExpectedPerHour }).Count
            $silent = $peerItemIds.Count - $reporting.Count     # no samples at all in that hour
        }
        $gap = $peerShort + $silent
        $share = if ($peerItemIds.Count -gt 0) { $gap / $peerItemIds.Count } else { $null }
        $peerGap += [pscustomobject]@{
            HourUtc = [DateTimeOffset]::FromUnixTimeSeconds($hStart).ToString('u'); HostSamples = $hours[$h]
            PeersTotal = $peerItemIds.Count; PeersShort = $gap
            Attribution = $(if ($null -eq $share) { 'unknown' } elseif ($share -ge $PeerShare) { 'platform-or-proxy' } else { 'host' }) }
    }
} else {
    Write-Warning 'The host is not monitored through a proxy; the peer check is skipped.'
}

# Triggers and events
$trigRows = @((Invoke-ZabbixApi -Method trigger.get -AllowEmpty -Params @{ hostids = $hostRow.hostid; output = @('triggerid', 'description', 'expression'); expandExpression = $true
    search = @{ description = $TriggerSearch }; searchByAny = $true }))
if ($trigRows.Count -eq 0) { Write-Warning "No triggers matching: $($TriggerSearch -join ' | '). Event evidence is empty (template renamed?)." }
$trigEvents = if ($trigRows.Count) { @(Get-Events @{ objectids = @($trigRows | ForEach-Object { $_.triggerid }); time_from = $t0; time_till = $t1 - 1 }) } else { @() }
$restartTrig = @($trigRows | Where-Object { $_.description -like '*restarted*' })
$restartBefore = @()
if (-not $hasBoot) {
    if ($restartTrig.Count -eq 0) { throw "No system.boottime item and no 'has been restarted' trigger on ${HostName}: reboots cannot be shown." }
    # Problem events only (value 1): each restart also logs a recovery minutes later, which is not a boot.
    $restartBefore = @(Get-Events @{ objectids = @($restartTrig | ForEach-Object { $_.triggerid }); time_from = $t0 - $BootLookbackDays * 86400; time_till = $t0 - 1 } |
        Where-Object { [string]$_.value -eq '1' })
    if ($restartBefore.Count -eq 0) { throw "EMPTY RESULT: no restart event in the $BootLookbackDays days before the period, so the boot the period starts from is unknown. Raise -BootLookbackDays." }
}
# Platform events around each short hour: what the monitoring side itself reported when the gap happened.
$platformEvents = @{}
foreach ($h in $short) {
    foreach ($e in @((Invoke-ZabbixApi -Method event.get -AllowEmpty -Params @{ source = 0; object = 0
                time_from = [long]$h - 1800; time_till = [long]$h + 5400; search = @{ name = $PlatformEventSearch }; searchByAny = $true
                output = @('eventid', 'clock', 'value', 'name'); selectHosts = @('host'); sortfield = @('clock') }))) {
        $platformEvents[[string]$e.eventid] = $e
    }
}
$platformEvents = @($platformEvents.Values | Sort-Object { [long]$_.clock })
$proxyEvents = @()
if ($proxy) {
    $proxyName = if ($proxy.PSObject.Properties.Name -contains 'name') { $proxy.name } else { $proxy.host }
    $proxyEvents = @(Get-Events @{ time_from = $t0; time_till = $t1 - 1; search = @{ name = $proxyName } })
}

# Reboots: boot time changes between consecutive hourly rows
$bootSorted = @($boot | Sort-Object { [long]$_.clock })
$bootValues = @($bootSorted | ForEach-Object { [long][double]$_.value_min; [long][double]$_.value_max } | Sort-Object -Unique)
if (-not $hasBoot) {
    # Restart trigger problem events (value 1) mark a boot within the trigger window (uptime < 10 min on the standard template).
    $restartIds = @($restartTrig | ForEach-Object { [string]$_.triggerid })
    $bootValues = @(@($restartBefore | Select-Object -Last 1) + @($trigEvents | Where-Object { $restartIds -contains [string]$_.objectid -and [string]$_.value -eq '1' }) |
        Where-Object { $_ } | ForEach-Object { [long]$_.clock } | Sort-Object -Unique)
}
$reboots = @($bootValues | ForEach-Object { [DateTimeOffset]::FromUnixTimeSeconds($_).ToString('u') })

$missingSamples = ($short | ForEach-Object { $ExpectedPerHour - $hours[$_] } | Measure-Object -Sum).Sum
if ($null -eq $missingSamples) { $missingSamples = 0 }
$totalSamples = $hours.Count * $ExpectedPerHour
$evidence = [ordered]@{
    host = $hostRow; proxy = $proxy; period = [ordered]@{ fromUtc = [DateTimeOffset]::FromUnixTimeSeconds($t0).ToString('u'); toUtc = [DateTimeOffset]::FromUnixTimeSeconds($t1).ToString('u') }
    items = $items; triggers = $trigRows
    pingHours = @($hours.Keys | ForEach-Object { [ordered]@{ hour = [long]$_; samples = $hours[$_] } })
    peerGapHours = $peerGap; bootValues = $reboots
    rebootSource = $(if ($hasBoot) { 'system.boottime' } else { 'restart trigger events' })
    triggerEvents = $trigEvents; restartEventsBeforePeriod = $restartBefore; proxyEvents = $proxyEvents
    platformEvents = $platformEvents
    extractedAt = (Get-Date).ToUniversalTime().ToString('o')
}
if (-not $OutFile) { $OutFile = Join-Path (Get-Location) ('availability-{0}-{1}.json' -f ($HostName -replace '[^A-Za-z0-9_.-]', '_'), (Get-Date -Format 'yyyyMMdd')) }
$evidence | ConvertTo-Json -Depth 20 | Out-File -FilePath $OutFile -Encoding utf8

[pscustomobject]@{
    Host = $HostName
    Hours = $hours.Count
    ShortHours = $short.Count
    MissingSamples = $missingSamples
    ReportingPercent = [Math]::Round(100 * (1 - $missingSamples / $totalSamples), 3)
    ShortHoursPlatform = @($peerGap | Where-Object { $_.Attribution -eq 'platform-or-proxy' }).Count
    ShortHoursHost = @($peerGap | Where-Object { $_.Attribution -eq 'host' }).Count
    DistinctBootTimes = $bootValues.Count
    TriggerEvents = $trigEvents.Count
    ProxyEvents = $proxyEvents.Count
    PlatformEvents = $platformEvents.Count
    Evidence = $OutFile
}
