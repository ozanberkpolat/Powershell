#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Split storage transactions by authentication type (shared key vs OAuth vs SAS), read-only.

.DESCRIPTION
    Answers "what breaks if I set allowSharedKeyAccess to false?". For each storage account and service
    (blob, file, queue, table) it reads the Transactions metric split by the Authentication dimension
    (AccountKey, SAS, OAuth, Anonymous, ...) at daily grain and prints totals, active days and the first
    and last day each type was seen. An account with AccountKey or SAS traffic is not ready for shared
    key disable; one with only OAuth is.

    Optional -SplitByApi adds the ApiName dimension for the shared key rows so you can see which operations
    (for example GetBlob, PutBlob, ListContainers) the key is used for.

.PARAMETER StorageAccountName
    Only these accounts. Default: every storage account the identity can read via Resource Graph.
.PARAMETER Subscription
    Subscription IDs to search. Default: all enabled.
.PARAMETER Days
    Look-back window, 1 to 89 days. Default 30. Metrics keep 93 days.
.PARAMETER SplitByApi
    For AccountKey and SAS rows, also break down by ApiName.
.PARAMETER OutCsv
    CSV path. Default ./storage-auth-mix-<timestamp>.csv

.EXAMPLE
    ./Get-StorageAuthMix.ps1 -Days 60 -SplitByApi

.NOTES
    Role: Reader (Monitoring Reader also works). Modules: Az.Accounts.
    Traps kept:
      - Use the SERVICE namespace (Microsoft.Storage/storageAccounts/blobServices) with the resource ID
        ending in /blobServices/default. The account level aggregates all services and would double count.
      - A service that does not exist on the account kind (for example file on a BlobStorage account, or
        queue/table on premium) answers 400/404: reported as n/a, not as zero traffic.
      - Metrics are sampled by Azure Monitor: no rows at all for an account means no traffic OR no
        metrics emitted; compare with the activity of the account before trusting "zero".
      - Transactions counts every request, including failed ones with ResponseType AuthorizationFailure.
        Use Get-StorageKeyUsage.ps1 for who fetches keys, and storage logs (KQL) for caller IPs.
#>
[CmdletBinding()]
param(
    [string[]]$StorageAccountName,
    [string[]]$Subscription,
    [ValidateRange(1, 89)][int]$Days = 30,
    [switch]$SplitByApi,
    [string]$OutCsv = "./storage-auth-mix-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }

$kql = "resources | where type =~ 'microsoft.storage/storageaccounts' | project name, id, resourceGroup, subscriptionId, kind, sku = tostring(sku.name), sharedKey = tostring(properties.allowSharedKeyAccess)"
if ($StorageAccountName) { $kql += " | where name in~ (" + (($StorageAccountName | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")" }
$accts = @(if ($Subscription) { Search-Graph -Query $kql -Subscription $Subscription } else { Search-Graph -Query $kql })
if (-not $accts.Count) { throw 'No storage account found in the readable subscriptions.' }

$start = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:00:00Z')
$end = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:00:00Z')
$services = 'blobServices', 'fileServices', 'queueServices', 'tableServices'
$rows = New-Object System.Collections.ArrayList
$na = 0; $queries = 0

function Get-Day($v) { if ($v -is [datetime]) { $v.ToString('yyyy-MM-dd') } else { ([datetimeoffset]::Parse("$v", [cultureinfo]::InvariantCulture)).ToString('yyyy-MM-dd') } }
function Get-Series($rid, $ns, $filter) {
    $q = "$rid/providers/Microsoft.Insights/metrics?metricnames=Transactions&metricnamespace=$ns&aggregation=Total&interval=P1D" +
         "&timespan=$start/$end&`$filter=$([uri]::EscapeDataString($filter))"
    $m = Invoke-Arm -Path $q -ApiVersion '2023-10-01'
    $m | ForEach-Object { $_.timeseries } | Where-Object { $_ }
}

foreach ($a in $accts) {
    foreach ($svc in $services) {
        $rid = "$($a.id)/$svc/default"
        $ns = "Microsoft.Storage/storageAccounts/$svc"
        $queries++
        try { $series = @(Get-Series $rid $ns "Authentication eq '*'") }
        catch { $na++; Write-Host ("  {0,-30} {1,-14} n/a ({2})" -f $a.name, $svc, (("$_" -split "`n")[0]).Substring(0, [Math]::Min(90, ("$_" -split "`n")[0].Length))) -ForegroundColor DarkGray; continue }
        foreach ($ts in $series) {
            $auth = ($ts.metadatavalues | Where-Object { $_.name.value -eq 'authentication' }).value
            $pts = @($ts.data | Where-Object { $_.total -gt 0 })
            $sum = ($pts | Measure-Object -Property total -Sum).Sum
            if (-not $sum) { continue }
            [void]$rows.Add([pscustomobject]@{
                Account = $a.name; Subscription = $a.subscriptionId; Service = ($svc -replace 'Services$', ''); Auth = $auth; Api = ''
                Transactions = [long]$sum; ActiveDays = $pts.Count
                FirstDay = (Get-Day ($pts | Select-Object -First 1).timeStamp)
                LastDay = (Get-Day ($pts | Select-Object -Last 1).timeStamp)
                SharedKeyAllowed = $a.sharedKey
            })
        }
        if ($SplitByApi) {
            foreach ($auth in 'AccountKey', 'SAS') {
                $ser = @(Get-Series $rid $ns "Authentication eq '$auth' and ApiName eq '*'")
                foreach ($ts in $ser) {
                    $api = ($ts.metadatavalues | Where-Object { $_.name.value -eq 'apiname' }).value
                    $pts = @($ts.data | Where-Object { $_.total -gt 0 }); $sum = ($pts | Measure-Object -Property total -Sum).Sum
                    if (-not $sum) { continue }
                    [void]$rows.Add([pscustomobject]@{
                        Account = $a.name; Subscription = $a.subscriptionId; Service = ($svc -replace 'Services$', ''); Auth = "$auth"; Api = $api
                        Transactions = [long]$sum; ActiveDays = $pts.Count
                        FirstDay = (Get-Day ($pts | Select-Object -First 1).timeStamp)
                        LastDay = (Get-Day ($pts | Select-Object -Last 1).timeStamp)
                        SharedKeyAllowed = $a.sharedKey
                    })
                }
            }
        }
    }
    Write-Host "done: $($a.name)"
}

if ($na -eq $queries) { throw 'Every metrics query failed. Check Reader/Monitoring Reader on the accounts.' }
if (-not $rows.Count) { Write-Warning "No transactions at all in $Days days across $($accts.Count) account(s). Verify the metrics are emitted before concluding the accounts are idle." ; return }
$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8

"`n=== Transactions by authentication, last $Days days ==="
$rows | Where-Object { -not $_.Api } | Sort-Object Account, Service, @{ e = 'Transactions'; Descending = $true } |
    Format-Table Account, Service, Auth, Transactions, ActiveDays, FirstDay, LastDay, SharedKeyAllowed -AutoSize

"=== Verdict per account ==="
foreach ($g in ($rows | Where-Object { -not $_.Api } | Group-Object Account)) {
    $keyed = @($g.Group | Where-Object { $_.Auth -in 'AccountKey', 'SAS' })
    $verdict = if ($keyed.Count) { 'IN USE (' + (($keyed | ForEach-Object { "$($_.Service)/$($_.Auth)" } | Sort-Object -Unique) -join ', ') + '), not ready to disable shared key' } else { 'no shared key or SAS traffic seen' }
    '{0,-32} {1}' -f $g.Name, $verdict
}
$silent = $accts.name | Where-Object { $_ -notin $rows.Account }
if ($silent) { "`nAccounts with no transactions in the window: $($silent -join ', ')" }
Write-Host "`nCSV: $OutCsv"
