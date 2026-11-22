#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Month-over-month Azure cost per service, resource group or resource, per subscription (read-only).

.DESCRIPTION
    Queries Cost Management (Microsoft.CostManagement/query) once per subscription and month, then pivots the
    result: one row per service / resource group / resource, one column per month, plus the change between the first
    and last month. Supersedes Get-AzureCostAnalysis.ps1: no az CLI token, no hard-coded language, honours throttling,
    follows nextLink and says which subscriptions failed instead of printing a partial bill as if it were complete.

    Cost Management bills queries in QPUs and throttles on several windows at once, each with its own retry header
    (qpu, client, entity, tenant scope). They disagree, and the LARGEST one is the gate, so the helper waits for the
    maximum (floor 30 s, ceiling 180 s). Taking the first match made earlier retries useless: four attempts waited
    15 s, 0 s, 13 s, 3 s and every one returned 429.

.PARAMETER Month
    Months as yyyy-MM. Default: the two last complete months. Each month is its own bounded call (comparing January
    with December in one custom window would break the one-year limit).
.PARAMETER GroupBy
    Service (default), ResourceGroup or Resource.
.PARAMETER Subscription
    Subscription IDs. Default: all enabled.
.PARAMETER CostType
    ActualCost (default) or AmortizedCost (spreads reservation purchases over their term; use it to see real run cost).
.PARAMETER OutCsv
    Optional CSV of the pivot.
.PARAMETER TimeBudgetMinutes
    Stop waiting on throttles after this long and report what was read. Default 20.

.EXAMPLE
    ./Get-MonthlyCostByService.ps1 -Month 2026-09,2026-10 -GroupBy ResourceGroup -OutCsv ./cost.csv

.EXAMPLE
    ./Get-MonthlyCostByService.ps1 -GroupBy Resource -CostType AmortizedCost

.NOTES
    Role: Cost Management Reader (or Reader; Reader covers Microsoft.CostManagement/query). Modules: Az.Accounts.
    Traps kept:
      - On EA / MCA billing accounts the setting "Allow Azure subscription users to view and optimize costs" gates every
        subscription-scope cost read regardless of RBAC. It shows up here as a per-subscription failure.
      - A subscription's rows are published only if EVERY month succeeded. A sub that fails on the second month would
        otherwise leave its first month in the totals and every service in it would read as a huge fake decrease.
      - Resource-level grouping really pages; follow nextLink to the end or the bill is under-reported.
      - A subscription throttled while its siblings were spending quota often reads fine after a cooldown, so 429
        subscriptions get one more pass after 60 s. Permission errors are not retried.
      - Several currencies in one result would add unlike amounts: the script stops and says so.
      - Cost data lags: the current month is incomplete. The default months are complete months.
      - Never fabricate zero: a service absent in one month is shown as 0 in the pivot only because the API returned
        no row for it; a failed subscription is listed under "Not read".
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d{4}-\d{2}$')][string[]]$Month,
    [ValidateSet('Service', 'ResourceGroup', 'Resource')][string]$GroupBy = 'Service',
    [string[]]$Subscription,
    [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = 'ActualCost',
    [string]$OutCsv,
    [int]$TimeBudgetMinutes = 20
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }

if (-not $Month) {
    $first = (Get-Date -Day 1).Date
    $Month = @($first.AddMonths(-2).ToString('yyyy-MM'), $first.AddMonths(-1).ToString('yyyy-MM'))
}
$Month = @($Month | Sort-Object -Unique)
$apiVersion = '2023-03-01'
$deadline = (Get-Date).AddMinutes($TimeBudgetMinutes)
$subs = if ($Subscription) { @($Subscription | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $_ } }) } else { @(Get-EnabledSubscription) }

$dims = switch ($GroupBy) {
    'Service' { @('ServiceName') }
    'ResourceGroup' { @('ResourceGroupName') }
    'Resource' { @('ServiceName', 'ResourceGroupName', 'ResourceId') }
}

function Get-MonthWindow([string]$m) {
    $from = [datetime]::ParseExact("$m-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    @{ from = $from.ToString('yyyy-MM-ddT00:00:00Z'); to = $from.AddMonths(1).AddSeconds(-1).ToString('yyyy-MM-ddTHH:mm:ssZ') }
}
function Get-ColIndex($cols, $names) {
    foreach ($n in $names) { for ($i = 0; $i -lt $cols.Count; $i++) { if ("$($cols[$i].name)" -eq $n) { return $i } } }
    -1
}

function Get-SubRows($sub) {
    # Buffer per subscription; publish only when every month worked.
    $local = New-Object System.Collections.ArrayList
    foreach ($m in $Month) {
        $w = Get-MonthWindow $m
        $body = @{
            type = $CostType; timeframe = 'Custom'; timePeriod = @{ from = $w.from; to = $w.to }
            dataset = @{
                granularity = 'None'
                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                grouping = @($dims | ForEach-Object { @{ type = 'Dimension'; name = $_ } })
            }
        }
        try {
            if ((Get-Date) -gt $deadline) { throw 'out of time budget (429 quota exhausted), retry later' }
            $path = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=$apiVersion"
            $pages = New-Object System.Collections.ArrayList
            $guard = 0
            while ($path) {
                # POST again to nextLink with the same body (Cost Management paging contract).
                $page = Invoke-ArmRequest -Method POST -Path $path -Body $body -MaxRetries 3 -MinWaitSeconds 30 -MaxWaitSeconds 180
                if ($null -eq $page) { break }
                [void]$pages.Add($page)
                $path = $page.properties.nextLink
                if (++$guard -gt 100) { throw "still paging after $guard pages" }
            }
        } catch { return @{ rows = @(); error = "$_" } }
        foreach ($pg in $pages) {
            $cols = @($pg.properties.columns)
            if (-not $cols.Count) { continue }
            $iAmt = Get-ColIndex $cols @('Cost', 'PreTaxCost', 'totalCost', 'CostUSD')
            $iCur = Get-ColIndex $cols @('Currency', 'BillingCurrency', 'CurrencyCode')
            $iSvc = Get-ColIndex $cols @('ServiceName'); $iRg = Get-ColIndex $cols @('ResourceGroupName', 'ResourceGroup'); $iRid = Get-ColIndex $cols @('ResourceId', 'InstanceId')
            if ($iAmt -lt 0) { return @{ rows = @(); error = "unexpected response columns: $(($cols.name) -join ', ')" } }
            foreach ($r in @($pg.properties.rows)) {
                $key = switch ($GroupBy) {
                    'Service' { "$($r[$iSvc])" }
                    'ResourceGroup' { "$($r[$iRg])".ToLower() }
                    'Resource' { "$($r[$iRid])".ToLower() }
                }
                [void]$local.Add([pscustomobject]@{
                    Key = $key; Month = $m; Cost = [double]$r[$iAmt]; Currency = $(if ($iCur -ge 0) { "$($r[$iCur])" } else { '' })
                    Service = $(if ($iSvc -ge 0) { "$($r[$iSvc])" } else { '' }); ResourceGroup = $(if ($iRg -ge 0) { "$($r[$iRg])" } else { '' })
                })
            }
        }
    }
    @{ rows = $local; error = $null }
}

$pulled = @{}
foreach ($s in $subs) {
    Write-Host "Reading $($s.Name) ($($s.Id))" -ForegroundColor Yellow
    $pulled[$s.Id] = Get-SubRows $s
    if ($pulled[$s.Id].error) { Write-Warning "$($s.Name): $($pulled[$s.Id].error)" }
}
$again = @($subs | Where-Object { "$($pulled[$_.Id].error)" -match '429' })
if ($again.Count -and (Get-Date) -lt $deadline) {
    Write-Warning "Retrying $($again.Count) throttled subscription(s) after a 60 s cooldown"
    Start-Sleep -Seconds 60
    foreach ($s in $again) {
        if ((Get-Date) -ge $deadline) { break }
        $r = Get-SubRows $s
        if ($r.error) { Write-Warning "$($s.Name) (retry): $($r.error)"; continue }
        $pulled[$s.Id] = $r
    }
}
$failed = @($subs | Where-Object { $pulled[$_.Id].error })
if ($failed.Count -eq $subs.Count) { throw "No subscription returned cost data. First error: $($pulled[$subs[0].Id].error)" }

$all = foreach ($s in $subs) { foreach ($r in $pulled[$s.Id].rows) { $r } }
if (-not $all) { throw 'Cost queries succeeded but returned no rows. Verify the months and that costs exist for them.' }
$cur = @($all.Currency | Where-Object { $_ } | Sort-Object -Unique)
if ($cur.Count -gt 1) { throw "Several currencies returned ($($cur -join ', ')); pivoting would add unlike amounts. Query the subscriptions separately." }

$pivot = foreach ($g in $all | Group-Object Key) {
    $o = [ordered]@{ $GroupBy = $g.Name }
    if ($GroupBy -eq 'Resource') { $o.Service = ($g.Group | Select-Object -First 1).Service; $o.ResourceGroup = ($g.Group | Select-Object -First 1).ResourceGroup }
    foreach ($m in $Month) { $o[$m] = [Math]::Round((($g.Group | Where-Object Month -eq $m | Measure-Object Cost -Sum).Sum), 2) }
    $a = $o[$Month[0]]; $b = $o[$Month[-1]]
    $o.Change = [Math]::Round($b - $a, 2)
    $o.ChangePct = if ($a) { [Math]::Round(100 * ($b - $a) / $a, 1) } else { $null }
    [pscustomobject]$o
}
$pivot = @($pivot | Sort-Object { $_.($Month[-1]) } -Descending)
$tot = [ordered]@{ $GroupBy = 'TOTAL' }
foreach ($m in $Month) { $tot[$m] = [Math]::Round((($pivot | Measure-Object -Property $m -Sum).Sum), 2) }
$tot.Change = [Math]::Round($tot[$Month[-1]] - $tot[$Month[0]], 2)
$tot.ChangePct = if ($tot[$Month[0]]) { [Math]::Round(100 * $tot.Change / $tot[$Month[0]], 1) } else { $null }

"`n=== $CostType by $GroupBy, $($Month -join ' / '), currency $($cur -join ',') ==="
$pivot | Select-Object -First 40 | Format-Table -AutoSize
[pscustomobject]$tot | Format-Table -AutoSize
if ($pivot.Count -gt 40) { Write-Host "(showing top 40 of $($pivot.Count); use -OutCsv for all)" }
if ($failed.Count) {
    Write-Warning ("PARTIAL BILL. Not read: " + (($failed | ForEach-Object { "$($_.Name): $($pulled[$_.Id].error)" }) -join ' | '))
}
if ($OutCsv) { $pivot + [pscustomobject]$tot | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8; Write-Host "CSV: $OutCsv" }
if ($failed.Count) { exit 2 }
