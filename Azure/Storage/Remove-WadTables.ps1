#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Delete the legacy WAD* diagnostic tables (Windows Azure Diagnostics) from a storage account. Report by default.

.DESCRIPTION
    The old Windows diagnostics extension (IaaSDiagnostics, "WAD") writes performance counters, event logs
    and metrics into tables named WAD* in a storage account (WADPerformanceCountersTable,
    WADWindowsEventLogsTable, WADMetricsPT1HP10DV2S<date>, ...). After moving to Azure Monitor Agent these
    tables are dead weight, often thousands of them.

    Default run lists the tables: how many in total, how many match the prefix, and which ones stay.
    It also looks for VMs and scale sets that still have the diagnostics extension pointing at the account:
    those would simply recreate the tables, so the script refuses to delete while one exists
    (override with -IgnoreActiveExtension).

    With -Apply every matching table is deleted (each guarded by ShouldProcess), the names are written to a
    log file BEFORE the first delete, and the account is listed again at the end.

    Works through the Storage resource provider (management plane), so it needs no data plane role, no
    shared key and no network line of sight to the table endpoint (a storage firewall does not block it).

    UNTESTED: this is a port of an az CLI data plane run to the management plane tables API
    (Microsoft.Storage/storageAccounts/tableServices/default/tables). Verify the list count against
    Storage browser on one account before the first -Apply.

.PARAMETER StorageAccountId
    Resource ID of the storage account. Or use -StorageAccountName (resolved through Resource Graph).
.PARAMETER StorageAccountName
    Storage account name.
.PARAMETER Prefix
    Table name prefix to delete. Default 'WAD'. Matching is case-sensitive, like the extension's names.
.PARAMETER Apply
    Delete. Without it the script only reports.
.PARAMETER IgnoreActiveExtension
    Delete even when a VM or scale set still writes to the account with the diagnostics extension.
.PARAMETER LogPath
    File that receives the names of the tables to delete. Default ./wad-tables-<account>-<timestamp>.txt

.EXAMPLE
    ./Remove-WadTables.ps1 -StorageAccountName stdiaglegacy01

.EXAMPLE
    ./Remove-WadTables.ps1 -StorageAccountName stdiaglegacy01 -Apply -Confirm:$false

.NOTES
    Role: Reader for the report. Storage Account Contributor (Microsoft.Storage/storageAccounts/tableServices/tables/delete)
    for -Apply; activate PIM first. Modules: Az.Accounts.
    Traps kept:
      - Irreversible: table storage has no soft delete and no versioning. Get the data owner's approval first.
      - Only names that START with the prefix are deleted. Other tables on the account (for example
        SchemasTable, or application tables) are listed as retained and never touched.
      - A failed list must not look like "0 tables": the list call throws on any error.
      - A VM that still runs the diagnostics extension recreates the tables within minutes; remove or
        repoint the extension first.
      - A table name cannot be reused for about 30 seconds after its delete; that does not matter here.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ById')][string]$StorageAccountId,
    [Parameter(Mandatory, ParameterSetName = 'ByName')][string]$StorageAccountName,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9]{0,62}$')][string]$Prefix = 'WAD',
    [switch]$Apply,
    [switch]$IgnoreActiveExtension,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
$api = '2023-05-01'

if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $hit = @(Search-Graph -Query "resources | where type =~ 'microsoft.storage/storageaccounts' and name =~ '$($StorageAccountName -replace "'", "''")' | project id")
    if ($hit.Count -ne 1) { throw "Storage account '$StorageAccountName' found $($hit.Count) times (need exactly 1). Pass -StorageAccountId." }
    $StorageAccountId = $hit[0].id
}
$acct = $StorageAccountId.TrimEnd('/').Split('/')[-1]
if (-not $LogPath) { $LogPath = "./wad-tables-$acct-$(Get-Date -Format yyyyMMdd-HHmmss).txt" }

function Get-TableName { @(Invoke-Arm -Path "$StorageAccountId/tableServices/default/tables" -ApiVersion $api | ForEach-Object name) }

$all = Get-TableName
# -clike: the extension writes 'WAD...'; a case-insensitive match would also catch an app table called 'wadsomething'.
$targets = @($all | Where-Object { $_ -clike "$Prefix*" } | Sort-Object)
$kept = @($all | Where-Object { $_ -cnotlike "$Prefix*" })
Write-Host "Account          : $acct"
Write-Host "Tables on account: $($all.Count)"
Write-Host "Match '$Prefix*'   : $($targets.Count)"
Write-Host "Retained         : $(if ($kept.Count) { $kept -join ', ' } else { '(none)' })"
if (-not $targets.Count) { Write-Warning "No table starts with '$Prefix'. Nothing to do."; return }

# Who still writes WAD data to this account?
$q = $acct -replace "'", "''"
$vmKql = "resources | where type =~ 'microsoft.compute/virtualmachines/extensions' | where tostring(properties.type) =~ 'IaaSDiagnostics' and tostring(properties.settings.StorageAccount) =~ '$q' | project id"
$vmssKql = "resources | where type =~ 'microsoft.compute/virtualmachinescalesets' | mv-expand e = properties.virtualMachineProfile.extensionProfile.extensions | where tostring(e.properties.type) =~ 'IaaSDiagnostics' and tostring(e.properties.settings.StorageAccount) =~ '$q' | project id"
$writers = @(Search-Graph -Query $vmKql) + @(Search-Graph -Query $vmssKql)
if ($writers.Count) {
    $writers | ForEach-Object { Write-Warning "Diagnostics extension still writes here: $($_.id)" }
    if ($Apply -and -not $IgnoreActiveExtension) { throw "$($writers.Count) resource(s) still run the diagnostics extension against $acct; they would recreate the tables. Remove the extension first or pass -IgnoreActiveExtension." }
}
if (-not $Apply) { Write-Host 'Report only. Re-run with -Apply to delete the matching tables (irreversible).'; return }

$targets | Set-Content -Path $LogPath -Encoding utf8 -WhatIf:$false   # record BEFORE deleting
Write-Host "Table names recorded at $LogPath"
$ok = 0; $failed = @()
for ($i = 0; $i -lt $targets.Count; $i++) {
    $t = $targets[$i]
    if (-not $PSCmdlet.ShouldProcess("$acct/$t", 'Delete table (irreversible)')) { continue }
    try { Invoke-ArmRequest -Method DELETE -Path "$StorageAccountId/tableServices/default/tables/$($t)?api-version=$api" -IgnoreNotFound | Out-Null; $ok++ }
    catch { $failed += "$t :: $(("$_" -split "`n")[0])" }
    if ((($i + 1) % 25) -eq 0) { Write-Host "  progress $($i + 1)/$($targets.Count)  ok=$ok failed=$($failed.Count)" }
}
$rem = Get-TableName
Write-Host "Deleted: $ok  Failed: $($failed.Count)  Remaining tables: $($rem.Count)"
$left = @($rem | Where-Object { $_ -clike "$Prefix*" })
if ($left.Count) { Write-Warning "$($left.Count) '$Prefix*' table(s) still present (failed, skipped or recreated): $(($left | Select-Object -First 10) -join ', ')" }
if ($failed.Count) { $failed | Select-Object -First 15 | ForEach-Object { Write-Warning $_ }; throw "$($failed.Count) table delete(s) failed." }
