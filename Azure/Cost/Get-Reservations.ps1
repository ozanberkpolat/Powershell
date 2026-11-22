#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    List Azure reservations, reservation orders and savings plans with expiry, utilization and renew flag (read-only).

.DESCRIPTION
    Merges every route that can see reservations, because they do not always agree:

      1. Microsoft.Capacity/reservations (ListAll, tenant wide, honours reservation RBAC roles)
      2. Microsoft.Capacity/reservationOrders walk, each order's reservations (cross-check and fallback)
      3. Microsoft.Billing/billingAccounts/<id>/reservations (honours EA/MCA BILLING roles)

    The union is de-duplicated on orderId/reservationId. Reservations come in two authorization worlds:
    reservation RBAC roles (Home > Reservations in the portal) and billing roles (Cost Management + Billing
    > Reservations). A billing reader can see every reservation in the portal while Microsoft.Capacity
    answers 403 for the same one. The script prints which routes contributed and how many each returned,
    so "the portal shows more than this script" is answerable.

    Also lists savings plan orders (Microsoft.BillingBenefits), which are NOT reservations and would
    otherwise make a family look unreserved.

    Output columns: Name, Sku, Location, Quantity, Term, State, Expiry, DaysLeft, Scope, AutoRenew,
    Utilization (best grain: 30, 7 or 1 day), UtilGrain, RetiredSeries, ReservedResourceType, Id.

.PARAMETER ExpiringWithinDays
    Only keep reservations expiring within N days (and savings plans likewise). Default: keep all.
.PARAMETER IncludeInactive
    Keep Expired, Cancelled, Split, Merged and Failed reservations too.
.PARAMETER OutCsv
    Optional CSV path for the reservation rows.
.PARAMETER PassThru
    Return the reservation objects (used by Get-ReservationCoverage.ps1).
.PARAMETER Quiet
    No table output (with -PassThru).

.EXAMPLE
    ./Get-Reservations.ps1 -ExpiringWithinDays 90

.NOTES
    Roles: Reservations Reader at tenant scope (Azure RBAC, elevate in the portal under Reservations, or
    a reservation-level Reader) and/or an EA / MCA billing reader role. Azure Reader on subscriptions does
    NOT show reservations. Modules: Az.Accounts.
    Traps kept:
      - Unreadable is not empty. If no route returns anything the script throws with the roles needed; it never
        prints a clean "no reservations".
      - Do not wrap the ListAll result in an extra array when you port this; one nested array turned 46
        reservations into 1.
      - expiryDateTime carries 7 fraction digits; parse with [datetimeoffset], not string slicing.
      - AutoRenew (properties.renew) says nothing for RETIRED VM series: since 2026-07-01 the retired series
        cannot be purchased or renewed, auto-renew stays true and silently does nothing, and the reservation drops to
        pay-as-you-go at expiry. The RetiredSeries column names such a series so you can plan a replacement.
        Retired for both terms: Dv3, Dsv3, Ev3, Esv3. Retired for the 1-year term only: Dv2, Dsv2, DS, D, F, Fs, Fsv2,
        Av2, Amv2, Bv1, G, GS, L, Ls, Lsv2. (Check the current Microsoft retirement notice before relying on the list.)
      - Pattern order matters when matching series: D4s_v3 must hit Dsv3 before Dv3.
      - Changing auto-renew is a write and is not done here: portal Reservations > the reservation > Renewal.
#>
[CmdletBinding()]
param(
    [int]$ExpiringWithinDays = 0,
    [switch]$IncludeInactive,
    [string]$OutCsv,
    [switch]$PassThru,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }

$api = '2022-11-01'
$DEAD = 'Expired', 'Cancelled', 'Split', 'Merged', 'Failed'
$gaps = New-Object System.Collections.ArrayList
$byKey = @{}
$routes = [ordered]@{}

# Retired series (explicit patterns; derived ones swallow the s: D4s_v3 matched Dv3).
$RETIRED_ALL = [ordered]@{ 'Dsv3' = '^D\d+(-\d+)?s_v3$'; 'Dv3' = '^D\d+(-\d+)?_v3$'; 'Esv3' = '^E\d+(-\d+)?s_v3$'; 'Ev3' = '^E\d+(-\d+)?_v3$' }
$RETIRED_1Y = [ordered]@{
    'Dsv2' = '^D\d+(-\d+)?s_v2$'; 'Dv2' = '^D\d+(-\d+)?_v2$'; 'Ds' = '^DS\d+(-\d+)?$'; 'D' = '^D\d+$'
    'Fsv2' = '^F\d+s_v2$'; 'Fs' = '^F\d+s$'; 'F' = '^F\d+$'; 'Amv2' = '^A\d+m_v2$'; 'Av2' = '^A\d+m?_v2$'
    'Bv1' = '^B\d+m?s$'; 'Gs' = '^GS\d+$'; 'G' = '^G\d+$'; 'Lsv2' = '^L\d+s_v2$'; 'Ls' = '^L\d+s$'
}
function Get-RetiredSeries([string]$Sku, [string]$Term) {
    $n = "$Sku" -replace '(?i)^(Standard|Basic)_', ''
    foreach ($k in $RETIRED_ALL.Keys) { if ($n -match ('(?i)' + $RETIRED_ALL[$k])) { return $k } }
    if ($Term -eq 'P1Y') { foreach ($k in $RETIRED_1Y.Keys) { if ($n -match ('(?i)' + $RETIRED_1Y[$k])) { return $k } } }
    $null
}
function ConvertTo-Utc($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    [datetimeoffset]::Parse("$v", [cultureinfo]::InvariantCulture).UtcDateTime
}
function Add-Res($rows, $label) {
    $n = 0
    foreach ($x in @($rows)) {
        if (-not $x -or -not $x.properties) { continue }
        $k = if ("$($x.id)" -match '(?i)reservationOrders/([^/]+)/reservations/([^/]+)') { "$($Matches[1])/$($Matches[2])".ToLower() } else { "$($x.id)".ToLower() }
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = $x; $n++ }
    }
    $routes[$label] = $n
}

# Assign then use: never wrap an Invoke-Arm result in another @().
try { $la = Invoke-Arm -Path '/providers/Microsoft.Capacity/reservations?$take=200' -ApiVersion $api; Add-Res $la 'Capacity ListAll' }
catch { [void]$gaps.Add("Capacity reservations ListAll unreadable: $_") }
try {
    $orders = Invoke-Arm -Path '/providers/Microsoft.Capacity/reservationOrders' -ApiVersion $api
    $walk = @()
    foreach ($o in $orders) {
        if (-not $o.name) { continue }
        try { $w1 = Invoke-Arm -Path "/providers/Microsoft.Capacity/reservationOrders/$($o.name)/reservations" -ApiVersion $api; foreach ($w in $w1) { $walk += $w } }
        catch { [void]$gaps.Add("Reservations of order $($o.name) unreadable: $_") }
    }
    Add-Res $walk 'Capacity order walk'
} catch { [void]$gaps.Add("Capacity reservationOrders unreadable: $_") }
try {
    $bas = Invoke-Arm -Path '/providers/Microsoft.Billing/billingAccounts' -ApiVersion '2024-04-01'
    foreach ($ba in $bas) {
        if (-not $ba.name) { continue }
        try { $br = Invoke-Arm -Path "/providers/Microsoft.Billing/billingAccounts/$($ba.name)/reservations" -ApiVersion '2024-04-01'; Add-Res $br "Billing account $($ba.name)" }
        catch { [void]$gaps.Add("Billing account reservations unreadable for $($ba.name): $_") }
    }
} catch { [void]$gaps.Add("Billing accounts unreadable, billing-role-visible reservations may be missed: $_") }

if (-not $byKey.Count) {
    throw ("No reservation readable by any route. Needs Reservations Reader at tenant scope (Azure RBAC) or an EA/MCA billing reader role. Details: " + ($gaps -join ' | '))
}

$now = (Get-Date).ToUniversalTime()
$rows = foreach ($r in $byKey.Values) {
    $p = $r.properties
    $state = "$($p.provisioningState)"
    if (-not $IncludeInactive -and $state -in $DEAD) { continue }
    if ("$($p.archived)" -eq 'True' -and -not $IncludeInactive) { continue }
    $exp = ConvertTo-Utc $(if ($p.expiryDateTime) { $p.expiryDateTime } else { $p.expiryDate })
    $days = if ($exp) { [int][Math]::Floor(($exp - $now).TotalDays) } else { $null }
    if ($ExpiringWithinDays -gt 0 -and ($null -eq $days -or $days -gt $ExpiringWithinDays)) { continue }
    $util = $null; $grain = $null
    foreach ($want in 30, 7, 1) {
        $a = @($p.utilization.aggregates | Where-Object { $_ -and [int]$_.grain -eq $want })
        if ($a.Count) { $util = [double]$a[0].value; $grain = $want; break }
    }
    $scopes = @($p.appliedScopes)
    if (-not $scopes.Count -and $p.appliedScopeProperties) { $scopes = @($p.appliedScopeProperties | ForEach-Object { $_.subscriptionId } | Where-Object { $_ }) }
    $isf = if ($p.reservedResourceProperties -and $p.reservedResourceProperties.instanceFlexibility) { "$($p.reservedResourceProperties.instanceFlexibility)" } else { "$($p.instanceFlexibility)" }
    $retired = if ("$($p.reservedResourceType)" -eq 'VirtualMachines') { Get-RetiredSeries $r.sku.name "$($p.term)" } else { $null }
    [pscustomobject]@{
        Name = $(if ($p.displayName) { "$($p.displayName)" } else { "$($r.name)" })
        Sku = "$($r.sku.name)"; Location = "$($r.location)".ToLower(); Quantity = [double]$p.quantity
        Term = "$($p.term)"; State = $state
        Expiry = $(if ($exp) { $exp.ToString('yyyy-MM-dd') } else { $null }); DaysLeft = $days
        Scope = "$($p.appliedScopeType)"; Scopes = $scopes; AutoRenew = $p.renew
        Utilization = $util; UtilGrain = $grain; InstanceFlexibility = $isf
        RetiredSeries = $retired; ReservedResourceType = "$($p.reservedResourceType)"; Id = $r.id
    }
}
$rows = @($rows | Sort-Object { if ($null -eq $_.DaysLeft) { [int]::MaxValue } else { $_.DaysLeft } })

# savings plans: different provider, detect and list
$plans = @()
try {
    $sp = Invoke-Arm -Path '/providers/Microsoft.BillingBenefits/savingsPlanOrders' -ApiVersion $api
    foreach ($o in $sp) {
        $q = $o.properties; if (-not $q) { continue }
        $e = ConvertTo-Utc $q.expiryDateTime
        $d = if ($e) { [int][Math]::Floor(($e - $now).TotalDays) } else { $null }
        if ($ExpiringWithinDays -gt 0 -and ($null -eq $d -or $d -gt $ExpiringWithinDays)) { continue }
        $plans += [pscustomobject]@{ Name = $(if ($q.displayName) { $q.displayName } else { $o.name }); Term = $q.term; BillingPlan = $q.billingPlan; Expiry = $(if ($e) { $e.ToString('yyyy-MM-dd') }); DaysLeft = $d; Id = $o.id }
    }
} catch { [void]$gaps.Add("Savings plans unreadable, a family covered by one may look unreserved: $_") }

if (-not $Quiet) {
    Write-Host ("Routes: " + (($routes.GetEnumerator() | ForEach-Object { "$($_.Key) (+$($_.Value))" }) -join ' + ')) -ForegroundColor Cyan
    "`n=== Reservations ($($rows.Count)) ==="
    $rows | Format-Table Name, Sku, Location, Quantity, Term, State, Expiry, DaysLeft, AutoRenew, Utilization, UtilGrain, RetiredSeries -AutoSize
    $warn = @($rows | Where-Object { $_.RetiredSeries -and $_.AutoRenew })
    if ($warn.Count) { Write-Warning ("{0} reservation(s) on a RETIRED series have auto-renew on, which silently does nothing: {1}" -f $warn.Count, (($warn | ForEach-Object { "$($_.Name) ($($_.RetiredSeries), $($_.Expiry))" }) -join '; ')) }
    "`n=== Savings plans ($($plans.Count)) ==="
    if ($plans.Count) { $plans | Format-Table Name, Term, BillingPlan, Expiry, DaysLeft -AutoSize } else { 'none listed' }
    if ($gaps.Count) { Write-Warning ("Not everything was readable:`n  " + ($gaps -join "`n  ")) }
}
if ($OutCsv) { $rows | Select-Object * -ExcludeProperty Scopes | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8; if (-not $Quiet) { Write-Host "CSV: $OutCsv" } }
if ($PassThru) { , $rows }
