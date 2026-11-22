#Requires -Version 5.1
<#
.SYNOPSIS
    Picks the right Zabbix items per host for a utilisation report: CPU utilisation, memory, CPU cores, filesystems.

.DESCRIPTION
    Zabbix hosts carry many look-alike items. This script chooses exactly one per purpose, with the rules that were
    needed to get a sane fleet report, and emits one flat row per chosen item. Feed the rows with Trended = True to
    Get-ZabbixTrends.ps1 (-ItemsFile), and use the Trended = False rows (capacity values) as denominators.

    Selection rules
      * CPU: exactly ONE aggregate item per host from `system.cpu.util*`. Per-mode items (idle, user, system,
        iowait, softirq, interrupt, nice, steal, guest) are not utilisation and are skipped; per-core items would
        multiply the trend fetch by the core count. Score: plain key 10, `,total` 8, other parameterless 6, any
        bracketed key 3.
      * Memory: `vm.memory.size[available]` beats `vm.memory.size[free]` beats `vm.memory.utilization` /
        `vm.memory.util` (percent). `vm.memory.size[total]` is never trended; it is the capacity denominator (lastvalue).
      * Cores: `system.cpu.num` lastvalue, else NumberOfLogicalProcessors, else the number of distinct per-core
        `system.cpu.util[N,...]` items already found. Zero cores stays 0 and is reported as a warning.
      * Filesystems: one winner per (host, mount) from `vfs.fs.size` and `vfs.fs.dependent.size`
        (`[mount,free|total|used|pused|pfree]`): `used` beats `free` beats `pused`; a NON-dependent item beats a
        dependent one outright because it carries the longer history. `total` rows become capacity values.

    Role column values: cpu_util, mem_available, mem_free, mem_util, mem_total, cores, disk_used, disk_free,
    disk_pused, disk_total.

.PARAMETER GroupName
    Host group(s) to cover (enabled hosts only).

.PARAMETER HostId
    Alternative to GroupName: explicit host IDs.

.PARAMETER Url
    Zabbix front end URL. Default: env ZABBIX_URL.

.PARAMETER TokenFile
    File with the API token. Default: env ZABBIX_TOKEN_FILE.

.PARAMETER Token
    API token as SecureString (alternative to TokenFile).

.PARAMETER OutFile
    Optional CSV path for the flat rows.

.EXAMPLE
    .\Get-ZabbixUtilizationItems.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -GroupName 'Contoso-Servers' -OutFile items.csv

.NOTES
    Read-only. Needs read access to the hosts and their items. A host with no CPU item or no memory item produces a warning.
    Item keys on non-standard templates can differ; the Key column shows what was chosen so you can check it.
#>
[CmdletBinding()]
param(
    [string[]]$GroupName,
    [string[]]$HostId,
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (-not $GroupName -and -not $HostId) { throw 'Give -GroupName or -HostId.' }
. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

if ($GroupName) {
    $gids = @($GroupName | ForEach-Object { Resolve-ZabbixHostGroup -Name $_ })
    $hostsRaw = Invoke-ZabbixApi -Method host.get -Params @{ output = @('hostid', 'name'); groupids = $gids; filter = @{ status = '0' }; sortfield = 'name' }
} else {
    $hostsRaw = Invoke-ZabbixApi -Method host.get -Params @{ output = @('hostid', 'name'); hostids = @($HostId); filter = @{ status = '0' } }
}
$hids = @($hostsRaw | ForEach-Object { [string]$_.hostid })
$name = @{}; foreach ($h in $hostsRaw) { $name[[string]$h.hostid] = [string]$h.name }
Write-Host "$($hids.Count) host(s)"

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$HostId, [string]$Role, [string]$ItemId, [string]$Key, [string]$Mount, $Value, [bool]$Trended) {
    $rows.Add([pscustomobject]@{ HostId = $HostId; Host = $name[$HostId]; Role = $Role; ItemId = $ItemId; Key = $Key; Mount = $Mount; Value = $Value; Trended = $Trended })
}

# --- CPU utilisation ---
$cpuRaw = Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ output = @('itemid', 'hostid', 'key_'); hostids = $hids; search = @{ key_ = 'system.cpu.util' } }
$cpuSkip = 'system\.cpu\.util\[.*,(idle|user|system|iowait|softirq|interrupt|nice|steal|guest)\]'
function Get-CpuScore([string]$k) {
    if ($k -eq 'system.cpu.util') { return 10 }
    if ($k -like '*,total*') { return 8 }
    if ($k -match '\[') { return 3 }
    return 6
}
$cpuByHost = @{}
foreach ($it in $cpuRaw) {
    if ([string]$it.key_ -match $cpuSkip) { continue }
    $h = [string]$it.hostid; $prev = $cpuByHost[$h]
    if (-not $prev -or (Get-CpuScore ([string]$it.key_)) -gt (Get-CpuScore ([string]$prev.key_))) { $cpuByHost[$h] = $it }
}
foreach ($h in $cpuByHost.Keys) { Add-Row $h 'cpu_util' ([string]$cpuByHost[$h].itemid) ([string]$cpuByHost[$h].key_) '' $null $true }

# --- Memory ---
$memRaw = Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ output = @('itemid', 'hostid', 'key_', 'lastvalue'); hostids = $hids; search = @{ key_ = 'vm.memory' } }
$memAvail = @{}; $memFree = @{}; $memUtil = @{}
foreach ($it in $memRaw) {
    $k = [string]$it.key_; $h = [string]$it.hostid
    if ($k -eq 'vm.memory.size[total]') { Add-Row $h 'mem_total' ([string]$it.itemid) $k '' ([double]$it.lastvalue) $false; continue }
    if ($k -eq 'vm.memory.size[available]') { $memAvail[$h] = $it; continue }
    if ($k -eq 'vm.memory.size[free]') { $memFree[$h] = $it; continue }
    if (($k -eq 'vm.memory.utilization' -or $k -eq 'vm.memory.util') -and -not $memUtil.ContainsKey($h)) { $memUtil[$h] = $it }
}
foreach ($h in $hids) {
    if ($memAvail.ContainsKey($h)) { Add-Row $h 'mem_available' ([string]$memAvail[$h].itemid) ([string]$memAvail[$h].key_) '' $null $true }
    elseif ($memFree.ContainsKey($h)) { Add-Row $h 'mem_free' ([string]$memFree[$h].itemid) ([string]$memFree[$h].key_) '' $null $true }
    elseif ($memUtil.ContainsKey($h)) { Add-Row $h 'mem_util' ([string]$memUtil[$h].itemid) ([string]$memUtil[$h].key_) '' $null $true }
}

# --- Cores ---
$cores = @{}
$cn = Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ output = @('hostid', 'lastvalue', 'itemid', 'key_'); hostids = $hids; search = @{ key_ = 'system.cpu.num' } }
foreach ($it in $cn) { if ([double]$it.lastvalue -gt 0) { $cores[[string]$it.hostid] = @{ n = [int][double]$it.lastvalue; id = [string]$it.itemid; key = [string]$it.key_ } } }
$missing = @($hids | Where-Object { -not $cores.ContainsKey($_) })
if ($missing.Count) {
    $nl = Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ output = @('hostid', 'lastvalue', 'itemid', 'key_'); hostids = $missing; search = @{ key_ = 'NumberOfLogicalProcessors' }; filter = @{ status = '0' } }
    foreach ($it in $nl) { if ([double]$it.lastvalue -gt 0 -and -not $cores.ContainsKey([string]$it.hostid)) { $cores[[string]$it.hostid] = @{ n = [int][double]$it.lastvalue; id = [string]$it.itemid; key = [string]$it.key_ } } }
}
# Last resort: count the distinct per-core util items already in hand.
$perCore = @{}
foreach ($it in $cpuRaw) {
    if ([string]$it.key_ -match 'system\.cpu\.util\[(\d+)') {
        $h = [string]$it.hostid
        if (-not $perCore.ContainsKey($h)) { $perCore[$h] = @{} }
        $perCore[$h][$Matches[1]] = $true
    }
}
foreach ($h in $perCore.Keys) { if (-not $cores.ContainsKey($h)) { $cores[$h] = @{ n = $perCore[$h].Count; id = ''; key = 'counted per-core util items' } } }
foreach ($h in $cores.Keys) { Add-Row $h 'cores' $cores[$h].id $cores[$h].key '' $cores[$h].n $false }

# --- Filesystems ---
$diskRaw = @()
foreach ($key in 'vfs.fs.size', 'vfs.fs.dependent.size') {
    $diskRaw += Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ output = @('itemid', 'hostid', 'key_', 'lastvalue', 'status'); hostids = $hids; search = @{ key_ = $key }; filter = @{ status = '0' } }
}
$fsRe = '^vfs\.fs(?:\.dependent)?\.size\[(.+),(free|total|used|pused|pfree)\]$'
$fsPri = @{ used = 3; free = 2; pused = 1 }
$diskWin = @{}
foreach ($it in $diskRaw) {
    $k = [string]$it.key_
    if ($k -notmatch $fsRe) { continue }
    $mount = $Matches[1]; $type = $Matches[2]; $h = [string]$it.hostid; $hm = "$h`t$mount"
    if ($type -eq 'total') { Add-Row $h 'disk_total' ([string]$it.itemid) $k $mount ([double]$it.lastvalue) $false; continue }
    if ($type -eq 'pfree') { continue }
    $pri = $fsPri[$type]
    if ($k -notlike '*.dependent.*') { $pri += 10 }
    if (-not $diskWin.ContainsKey($hm) -or $pri -gt $diskWin[$hm].pri) { $diskWin[$hm] = @{ pri = $pri; item = $it; mount = $mount; type = $type; h = $h } }
}
foreach ($w in $diskWin.Values) { Add-Row $w.h "disk_$($w.type)" ([string]$w.item.itemid) ([string]$w.item.key_) $w.mount $null $true }

# --- Loud about gaps ---
foreach ($h in $hids) {
    $roles = @($rows | Where-Object { $_.HostId -eq $h } | ForEach-Object { $_.Role })
    if ($roles -notcontains 'cpu_util') { Write-Warning "$($name[$h]): no CPU utilisation item found." }
    if (-not ($roles | Where-Object { $_ -like 'mem_*' -and $_ -ne 'mem_total' })) { Write-Warning "$($name[$h]): no memory item found." }
    if ($roles -notcontains 'cores') { Write-Warning "$($name[$h]): CPU core count unknown." }
}
if ($rows.Count -eq 0) { throw 'No utilisation items found on any host. Check item keys / template.' }

if ($OutFile) { $rows | Export-Csv $OutFile -NoTypeInformation -Encoding UTF8; Write-Host "Wrote $OutFile ($($rows.Count) rows)" }
$rows
