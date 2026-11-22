#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Find out who retrieves storage account keys or generates SAS tokens (read-only).

.DESCRIPTION
    Before you disable shared key access on a storage account you need to know who still uses it. Every
    listKeys, listServiceSas and listAccountSas call is written to the subscription Activity Log with
    the caller, the client IP and (for apps) the app ID. This script walks the Activity Log back in
    7-day slices (the Activity Log API is unreliable on long windows and truncates silently at a
    record cap), keeps those events, and prints a ranked summary plus a CSV of every event.

    Pair with Get-StorageAuthMix.ps1, which shows who actually USES keys on the data plane (metrics).
    This script shows who FETCHES them. Both are needed: an app may use a key that was fetched months ago.

.PARAMETER Subscription
    Subscription IDs. Default: every enabled subscription you can read.
.PARAMETER Days
    How far back to look. Default 28. The Activity Log keeps 90 days.
.PARAMETER SliceDays
    Slice size. Default 7.
.PARAMETER StorageAccountName
    Only these accounts (exact names).
.PARAMETER OutCsv
    CSV path. Default ./storage-key-usage-<timestamp>.csv

.EXAMPLE
    ./Get-StorageKeyUsage.ps1 -Days 35 -StorageAccountName stappdata01,stappdata02

.NOTES
    Role: Reader on the subscriptions (Activity Log read). Modules: Az.Accounts.
    Traps kept:
      - Each query returns Started and Succeeded rows for one operation; the summary counts Succeeded only
        (Started rows are kept in the CSV).
      - The service caps a page; slices that return a very large number of rows are flagged because
        events may be cut off. Shorten -SliceDays when that warning appears.
      - Zero events is a valid finding ("nobody fetches keys") only when the query itself worked. The script
        reports how many slices were read so you can tell the two cases apart.
      - Key regeneration events are not included here; add 'regenerateKey' to the pattern if you need them.
#>
[CmdletBinding()]
param(
    [string[]]$Subscription,
    [ValidateRange(1, 89)][int]$Days = 28,
    [ValidateRange(1, 14)][int]$SliceDays = 7,
    [string[]]$StorageAccountName,
    [string]$OutCsv = "./storage-key-usage-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
$subs = if ($Subscription) { $Subscription } else { (Get-EnabledSubscription).Id }
$pattern = 'listKeys|ListServiceSas|ListAccountSas'
$rows = New-Object System.Collections.ArrayList
$slicesRead = 0

foreach ($sid in $subs) {
    $now = (Get-Date).ToUniversalTime()
    $n = [Math]::Ceiling($Days / $SliceDays)
    for ($w = 0; $w -lt $n; $w++) {
        $end = $now.AddDays(-$SliceDays * $w)
        $start = $now.AddDays(-[Math]::Min($SliceDays * ($w + 1), $Days))
        $f = "eventTimestamp ge '{0}' and eventTimestamp le '{1}' and resourceProvider eq 'Microsoft.Storage'" -f $start.ToString('yyyy-MM-ddTHH:mm:ssZ'), $end.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $path = "/subscriptions/$sid/providers/Microsoft.Insights/eventtypes/management/values?`$filter=$([uri]::EscapeDataString($f))"
        $events = @(Invoke-Arm -Path $path -ApiVersion '2015-04-01' -MinWaitSeconds 10)
        $slicesRead++
        $hit = @($events | Where-Object { $_.operationName.value -match $pattern })
        Write-Host ("[{0}] {1:yyyy-MM-dd} .. {2:yyyy-MM-dd}: {3} storage events, {4} key/SAS" -f $sid.Substring(0, 8), $start, $end, $events.Count, $hit.Count)
        if ($events.Count -ge 4900) { Write-Warning "Slice returned $($events.Count) events: it may be truncated. Re-run with a smaller -SliceDays." }
        foreach ($e in $hit) {
            $acct = ($e.resourceId -split '/')[-1]
            if ($StorageAccountName -and $acct -notin $StorageAccountName) { continue }
            [void]$rows.Add([pscustomobject]@{
                Subscription = $sid; Account = $acct
                Operation = (($e.operationName.value -split '/')[-2]); Status = $e.status.value
                Caller = $e.caller; AppId = $e.claims.appid; ClientIp = $e.httpRequest.clientIpAddress
                Time = $e.eventTimestamp
            })
        }
    }
}

Write-Host "`nRead $slicesRead slice(s) over $($subs.Count) subscription(s), $Days day(s)."
if (-not $rows.Count) {
    Write-Warning 'NO listKeys / ListServiceSas / ListAccountSas events found. This is a valid result only if the slices above were read without errors and you hold Activity Log read on every subscription.'
    return
}
$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8
$ok = $rows | Where-Object Status -eq 'Succeeded'
"=== Key/SAS retrieval, Succeeded events, last $Days days ==="
$ok | Group-Object Account, Operation, Caller | Sort-Object Count -Descending | ForEach-Object {
    $p = $_.Name -split ', '
    $last = ($_.Group | Sort-Object Time | Select-Object -Last 1).Time
    '{0,5}  {1,-28} {2,-18} {3,-45} last={4}' -f $_.Count, $p[0], $p[1], $p[2], $last
}
Write-Host "`nAll events: $OutCsv ($($rows.Count) rows)"
