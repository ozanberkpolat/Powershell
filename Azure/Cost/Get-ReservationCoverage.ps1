#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Reserved VM instance coverage per region x instance size flexibility group (read-only).

.DESCRIPTION
    A reservation is a POOL: buy one D2s_v5 and any machine in that flexibility group can draw on it, scaled by
    the instance size flexibility (ISF) ratio. So the honest question is per region x group, in ISF units:

        reserved units = sum(quantity x ratio) over the reservations you own
        running units  = sum(count x ratio)    over the VMs that bill compute

        difference = running - reserved      (+ short, bills at pay-as-you-go;  - surplus, paying for nothing)

    Inputs:
      1. Running inventory from Resource Graph (VMs, plus non-Flexible scale sets with sku.capacity).
      2. ISF ratios per region from the reservation catalog (Microsoft.Capacity/catalogs).
      3. Owned reservations from Get-Reservations.ps1 (same folder).

    The math is deliberately simple. Azure applies the benefit hour by hour, first come first served, so no tool
    can say which machine was covered without billing records. Per-instance attribution was tried and gave answers
    that were harder to trust. Report the shortfall per family and act on it.

    If a size has no catalog ratio the group degrades to exact-size matching (ratio 1) and the row is marked
    Degraded: group math did not run for it. If inventory or reservations cannot be read, the comparison is
    withheld and the script says so; it never prints a clean result on partial data.

.PARAMETER Region
    Only these regions (for example germanywestcentral).
.PARAMETER OutCsv
    Optional CSV path.

.EXAMPLE
    ./Get-ReservationCoverage.ps1 -OutCsv ./coverage.csv

.NOTES
    Roles: Reader on the subscriptions (inventory, catalog) and Reservations Reader or a billing reader role (reservations).
    Modules: Az.Accounts.
    Traps kept:
      - Units are RAW ISF ratios. Microsoft does not normalise to 1 for the smallest SKU in a group (a Ddsv5 group starts
        at 2). Both sides use the same scale, so do not normalise.
      - Billable power: a VM consumes the reservation unless it is DEALLOCATED. Stopped but not deallocated still bills
        compute and still consumes it. Unknown power state counts as running (errs toward "no spare capacity").
      - Spot VMs and A-series (not Av2) / G / GS-series can never draw a reservation. They are excluded and counted,
        otherwise you invent a shortfall nobody can buy away.
      - Flexible-orchestration scale sets are excluded; their members already appear as individual VMs (double count).
      - ARG KQL cannot reference a projected alias in a later `where`; the two inventory queries filter on the full
        expression before projecting and are concatenated here.
      - The catalog pages with $skip/$take and returns no nextLink: ask for $take=2000. The reservedResourceType value
        is spelled VirtualMachines in one reference and VirtualMachine in another; try both, a wrong one returns empty.
        A 200 with no rows carrying the autofit properties is NOT success.
      - Catalog flexibility group names are per OS ("Virtual Machines Dsv6-series Linux"). Reservations cover compute
        regardless of OS, so strip prefix and OS suffix: one pool per family.
      - Flat floor of 0.5 unit: a percentage floor hides a whole missing VM in a big pool (2 percent of 118 units = 2.4).
      - RETIRED SERIES: reservations for retired VM series (Dv3, Dsv3, Ev3, Esv3 for both terms; Dv2, Dsv2, DS, D, F, Fs,
        Fsv2, Av2, Amv2, Bv1, G, GS, L, Ls, Lsv2 for the 1-year term) cannot be purchased or renewed since 2026-07-01.
        Auto-renew stays on and silently does nothing, so an expiring reservation there drops to pay-as-you-go. They are
        flagged in the output. Savings plans are a different provider and are not modelled: a family reading "nothing
        reserved" may be covered by one (Get-Reservations.ps1 lists them).
#>
[CmdletBinding()]
param(
    [string[]]$Region,
    [string]$OutCsv
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
$EPS = 0.01; $FLOOR = 0.5
$gaps = New-Object System.Collections.ArrayList

function Test-Eligible([string]$Size, [string]$Priority) {
    if ("$Priority" -match '(?i)spot') { return $false }
    if ($Size -match '(?i)^(Basic|Standard)_A\d+[a-z]*$') { return $false }   # A-series; Av2 ends _v2
    if ($Size -match '(?i)^Standard_GS?\d+') { return $false }               # G / GS
    $true
}
function Format-Group([string]$g) { (("$g" -replace '(?i)^virtual machines\s+', '') -replace '(?i)\s+(linux|windows)$', '').Trim() }

# ---- 1. inventory (two queries, not a union; see NOTES) -------------------------
$kqlVm = @"
resources
| where type =~ 'microsoft.compute/virtualmachines'
| where isnotempty(tostring(properties.hardwareProfile.vmSize))
| project id, name, size=tostring(properties.hardwareProfile.vmSize), power=tostring(properties.extended.instanceView.powerState.code), prio=tostring(properties.priority), loc=location, sub=subscriptionId
"@
$kqlSs = @"
resources
| where type =~ 'microsoft.compute/virtualmachinescalesets'
| where tostring(properties.orchestrationMode) != 'Flexible'
| where isnotempty(tostring(sku.name)) and toint(sku.capacity) > 0
| project id, name, size=tostring(sku.name), cap=toint(sku.capacity), prio=tostring(properties.virtualMachineProfile.priority), loc=location, sub=subscriptionId
"@
$vmRows = Search-Graph -Query $kqlVm
$ssRows = Search-Graph -Query $kqlSs
$inst = @()
$inst += foreach ($v in $vmRows) { [pscustomobject]@{ Name = $v.name; Size = $v.size; Power = $v.power; Loc = "$($v.loc)".ToLower(); Sub = $v.sub; Count = 1; Prio = $v.prio } }
$inst += foreach ($s in $ssRows) { [pscustomobject]@{ Name = $s.name; Size = $s.size; Power = 'PowerState/running'; Loc = "$($s.loc)".ToLower(); Sub = $s.sub; Count = [int]$s.cap; Prio = $s.prio } }
if (-not $inst.Count) { throw 'Resource Graph returned no VM at all. Check access; a comparison on an empty inventory would report only surplus.' }
$bad = @($inst | Where-Object { -not (Test-Eligible $_.Size $_.Prio) })
if ($bad.Count) { $inst = @($inst | Where-Object { Test-Eligible $_.Size $_.Prio }); [void]$gaps.Add("$($bad.Count) instance(s) excluded as ineligible for any reservation (Spot or A/G-series).") }
if ($Region) { $inst = @($inst | Where-Object { $_.Loc -in ($Region | ForEach-Object { $_.ToLower() }) }) }

# ---- 2. ISF ratios per region -------------------------------------------------------
$subs = @(Get-EnabledSubscription | Select-Object -First 3)
$regions = @($inst.Loc | Where-Object { $_ } | Sort-Object -Unique)
$ratios = @{}
foreach ($rg in $regions) {
    $got = $false; $lastErr = $null
    foreach ($s in $subs) {
        foreach ($rrt in 'VirtualMachines', 'VirtualMachine') {
            try {
                $cat = Invoke-Arm -ApiVersion '2022-11-01' -Path "/subscriptions/$($s.Id)/providers/Microsoft.Capacity/catalogs?reservedResourceType=$rrt&location=$rg&`$take=2000"
                foreach ($c in $cat) {
                    if (-not $c.name) { continue }
                    $grp = $null; $ratio = $null
                    foreach ($p in @($c.skuProperties)) {
                        switch -Regex ("$($p.name)") {
                            '(?i)^(ReservationsAutofitGroup|InstanceSizeFlexibilityGroup)$' { $grp = "$($p.value)" }
                            '(?i)^(ReservationsAutofitRatio|InstanceSizeFlexibilityRatio)$' { $ratio = "$($p.value)" }
                        }
                    }
                    if (-not $grp -or -not $ratio) { continue }
                    if (-not $ratios.ContainsKey($rg)) { $ratios[$rg] = @{} }
                    $ratios[$rg]["$($c.name)".ToLower()] = @{ Group = $grp; Ratio = [double]::Parse($ratio, [cultureinfo]::InvariantCulture) }
                }
                if ($ratios.ContainsKey($rg) -and $ratios[$rg].Count) { $got = $true; break }
            } catch { $lastErr = "$_" }
        }
        if ($got) { break }
    }
    if (-not $got) { [void]$gaps.Add("No ISF ratios for $rg, exact-size matching used there (rows marked Degraded)." + $(if ($lastErr) { " Last error: $lastErr" })) }
}

# ---- 3. reservations ---------------------------------------------------------------
$res = & (Join-Path $PSScriptRoot 'Get-Reservations.ps1') -PassThru -Quiet
$res = @($res | Where-Object { $_.ReservedResourceType -eq 'VirtualMachines' })
if ($Region) { $res = @($res | Where-Object { $_.Location -in ($Region | ForEach-Object { $_.ToLower() }) }) }

# ---- fold into region x group -------------------------------------------------------
function Get-Isf($loc, $size) {
    $l = "$loc".ToLower(); $s = "$size".ToLower()
    if ($ratios.ContainsKey($l) -and $ratios[$l].ContainsKey($s)) { return @{ Group = Format-Group $ratios[$l][$s].Group; Ratio = $ratios[$l][$s].Ratio; Degraded = $false } }
    @{ Group = "$size"; Ratio = 1.0; Degraded = $true }
}
$groups = @{}
function Get-Row($loc, $grp) {
    $k = "$loc|$grp".ToLower()
    if (-not $groups.ContainsKey($k)) { $groups[$k] = [pscustomobject]@{ Region = $loc; Group = $grp; Reserved = 0.0; Running = 0.0; Deallocated = 0.0; Degraded = $false; Sizes = @{}; Reservations = @(); Retired = @() } }
    $groups[$k]
}
foreach ($i in $inst) {
    $x = Get-Isf $i.Loc $i.Size; $row = Get-Row $i.Loc $x.Group
    $u = $x.Ratio * $i.Count
    if ($x.Degraded) { $row.Degraded = $true }
    if ("$($i.Power)" -notmatch '(?i)deallocat') { $row.Running += $u; $row.Sizes[$i.Size] = [double]$row.Sizes[$i.Size] + $i.Count } else { $row.Deallocated += $u }
}
foreach ($r in $res) {
    $x = Get-Isf $r.Location $r.Sku; $row = Get-Row $r.Location $x.Group
    if ($x.Degraded) { $row.Degraded = $true }
    $row.Reserved += $x.Ratio * $r.Quantity
    $row.Reservations += "$($r.Name): $($r.Quantity) x $($r.Sku)"
    if ($r.RetiredSeries) { $row.Retired += "$($r.Name) ($($r.RetiredSeries), expires $($r.Expiry))" }
}
if (-not $groups.Count) { throw 'No coverage rows produced.' }

$out = foreach ($g in $groups.Values | Sort-Object Region, Group) {
    $diff = $g.Running - $g.Reserved
    $verdict = if ($g.Degraded) { 'WITHHELD (no ISF ratio for a size; exact-size matching)' }
               elseif ($diff -gt $FLOOR) { 'SHORT: running exceeds reserved, the difference bills pay-as-you-go' }
               elseif ($diff -lt -$FLOOR -and $g.Reserved -gt $EPS) { 'SURPLUS: reserved capacity nothing uses' }
               else { 'OK' }
    [pscustomobject]@{
        Region = $g.Region; Group = $g.Group
        ReservedUnits = [Math]::Round($g.Reserved, 2); RunningUnits = [Math]::Round($g.Running, 2); DeallocatedUnits = [Math]::Round($g.Deallocated, 2)
        Difference = [Math]::Round($diff, 2); Verdict = $verdict
        Running = (($g.Sizes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Value)x $($_.Key -replace '(?i)^Standard_','')" }) -join ', ')
        Reservations = ($g.Reservations -join '; ')
        RetiredSeriesNote = ($g.Retired -join '; ')
    }
}
$out | Format-Table Region, Group, ReservedUnits, RunningUnits, Difference, Verdict -AutoSize -Wrap
$ret = @($out | Where-Object RetiredSeriesNote)
if ($ret.Count) { Write-Warning ("Reservations on RETIRED series cannot be renewed (auto-renew does nothing since 2026-07-01):`n  " + (($ret | ForEach-Object { "$($_.Region)/$($_.Group): $($_.RetiredSeriesNote)" }) -join "`n  ")) }
if ($gaps.Count) { Write-Warning ("Caveats:`n  " + ($gaps -join "`n  ")) }
if ($OutCsv) { $out | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8; Write-Host "CSV: $OutCsv" }
