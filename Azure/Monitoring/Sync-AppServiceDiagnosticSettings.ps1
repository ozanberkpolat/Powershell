#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Audit and sync App Service diagnostic settings: where logs go, which categories are missing, repoint to the right workspace.

.DESCRIPTION
    Default run is a read-only AUDIT over every readable subscription (App Services only, Function Apps excluded):
      - destinations per app (Log Analytics, storage account, event hub, partner),
      - apps with NO diagnostic setting,
      - apps with PARTIAL logging: supported log categories minus enabled ones, with the 'allLogs' category group
        counted as full coverage (the 'audit' group is not),
      - apps whose logs go to a workspace other than the one wanted for their subscription.

    With -Sync the script also writes, one action per app (each guarded by ShouldProcess, so -WhatIf prints the plan):
      CREATE   no setting at all -> new setting to the subscription's target workspace, every supported log category.
      UPDATE   setting already goes to the target workspace but categories are missing -> enable all of them.
      REPOINT  a Log Analytics setting goes to a different (wrong) workspace -> move it to the target, all categories.
               Other destinations of that setting (storage, event hub) are carried over.
      OK       already as wanted, untouched.
      SKIP     no target for the subscription, no loggable categories, or the 5-settings-per-resource limit is reached.
    Optionally -CentralWorkspaceId adds a SECOND, separate setting that sends every category to a central workspace
    (for example a Sentinel workspace), next to the environment one.

    Metrics: existing metric settings are written back unchanged (a PUT replaces the whole setting). New settings
    send no metrics. Use -RemoveMetrics to drop metrics from the settings this script writes.

.PARAMETER WorkspaceMap
    Hashtable subscriptionId -> target Log Analytics workspace resource ID (needed for -Sync).
.PARAMETER CentralWorkspaceId
    Resource ID of a central workspace that should also receive every category through its own setting.
.PARAMETER DefaultSettingName
    Name for a newly created environment setting. Default diag-loganalytics-all.
.PARAMETER CentralSettingName
    Name for the central setting. Default diag-central.
.PARAMETER Subscription
    Limit to these subscription IDs.
.PARAMETER Sync
    Apply changes (still subject to -WhatIf / -Confirm).
.PARAMETER SkipRepoint
    Do not move settings that point at a wrong workspace (only fix categories).
.PARAMETER RemoveMetrics
    Drop metrics from the settings written.
.PARAMETER OutCsv
    CSV of the per-app result.

.EXAMPLE
    ./Sync-AppServiceDiagnosticSettings.ps1 -OutCsv ./appsvc-diag.csv

.EXAMPLE
    $map = @{ '00000000-0000-0000-0000-000000000000' = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-law/providers/Microsoft.OperationalInsights/workspaces/law-prod' }
    ./Sync-AppServiceDiagnosticSettings.ps1 -Sync -WorkspaceMap $map -WhatIf

.NOTES
    Roles: audit needs Reader plus Monitoring Reader. -Sync needs Monitoring Contributor (or Contributor) on the apps
    (Microsoft.Insights/diagnosticSettings/write) and read on the workspaces; activate PIM first. Modules: Az.Accounts.
    Traps kept:
      - Creating a setting is a PUT: calling it with an existing name replaces it completely, so the current metrics
        and non-workspace destinations are read and written back.
      - A log category cannot be sent to the same workspace from two different settings; the script therefore edits the
        setting that already points at a workspace instead of adding a second one, and only adds a separate setting for a
        DIFFERENT (central) workspace.
      - At most 5 diagnostic settings per resource. At the limit the app is SKIPped and reported, never half-done.
      - Supported categories come from the resource itself (diagnosticSettingsCategories), they differ per app kind
        (Linux, Windows, container). Do not hard-code the list.
      - An app whose category list cannot be read is SKIPped with a reason, not treated as fully covered.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [hashtable]$WorkspaceMap,
    [string]$CentralWorkspaceId,
    [string]$DefaultSettingName = 'diag-loganalytics-all',
    [string]$CentralSettingName = 'diag-central',
    [string[]]$Subscription,
    [switch]$Sync,
    [switch]$SkipRepoint,
    [switch]$RemoveMetrics,
    [string]$OutCsv
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
if ($Sync -and -not $WorkspaceMap -and -not $CentralWorkspaceId) { throw '-Sync needs -WorkspaceMap and/or -CentralWorkspaceId.' }
$api = '2021-05-01-preview'
$limit = 5

$subNames = @{}; foreach ($s in Get-EnabledSubscription) { $subNames[$s.Id] = $s.Name }
$kql = "resources | where type =~ 'microsoft.web/sites' and kind !contains 'functionapp' | project name, id, resourceGroup, subscriptionId | order by name asc"
$apps = @(if ($Subscription) { Search-Graph -Query $kql -Subscription $Subscription } else { Search-Graph -Query $kql })
if (-not $apps.Count) { throw 'No App Service found in the readable subscriptions.' }
Write-Host "$($apps.Count) App Service(s) to check. Mode: $(if ($Sync) { 'SYNC' } else { 'AUDIT (read-only)' })" -ForegroundColor Cyan

function Same-Id($a, $b) { $a -and $b -and ("$a".TrimEnd('/') -ieq "$b".TrimEnd('/')) }
function ConvertTo-LogList($cats) { @($cats | ForEach-Object { @{ category = $_; enabled = $true } }) }

function Write-Setting($appId, $name, $props) {
    $body = @{ properties = $props }
    Invoke-ArmRequest -Method PUT -Path "$appId/providers/Microsoft.Insights/diagnosticSettings/${name}?api-version=$api" -Body $body | Out-Null
}

$out = New-Object System.Collections.ArrayList
$i = 0
foreach ($app in $apps) {
    $i++
    Write-Progress -Activity 'App Service diagnostics' -Status "$($app.name) ($i/$($apps.Count))" -PercentComplete (100 * $i / $apps.Count)
    $subName = if ($subNames.ContainsKey($app.subscriptionId)) { $subNames[$app.subscriptionId] } else { $app.subscriptionId }
    $row = [ordered]@{ Subscription = $subName; AppService = $app.name; ResourceGroup = $app.resourceGroup; Destinations = ''; Coverage = ''; Missing = ''; Action = 'OK'; Detail = ''; Result = '-' }
    $add = { param($r) [void]$out.Add([pscustomobject]$r) }

    try {
        $catResp = Invoke-Arm -Path "$($app.id)/providers/Microsoft.Insights/diagnosticSettingsCategories" -ApiVersion $api
        $supported = @($catResp | Where-Object { $_.properties.categoryType -eq 'Logs' } | ForEach-Object name)
        $settings = @(Invoke-Arm -Path "$($app.id)/providers/Microsoft.Insights/diagnosticSettings" -ApiVersion $api | Where-Object { $_ })
    } catch { $row.Action = 'SKIP'; $row.Detail = "could not read categories/settings: $_"; & $add $row; continue }
    if (-not $supported.Count) { $row.Action = 'SKIP'; $row.Detail = 'resource reports no loggable categories'; & $add $row; continue }

    # destinations + coverage across ALL settings
    $dests = New-Object System.Collections.Generic.List[string]
    $enabled = New-Object System.Collections.Generic.List[string]; $allLogs = $false
    foreach ($s in $settings) {
        $p = $s.properties
        if ($p.workspaceId) { $dests.Add("LA:$(Split-Path $p.workspaceId -Leaf)") }
        if ($p.storageAccountId) { $dests.Add("SA:$(Split-Path $p.storageAccountId -Leaf)") }
        if ($p.eventHubName -or $p.eventHubAuthorizationRuleId) { $dests.Add('EH:' + $(if ($p.eventHubName) { $p.eventHubName } else { ($p.eventHubAuthorizationRuleId -split '/namespaces/')[-1].Split('/')[0] })) }
        if ($p.marketplacePartnerId) { $dests.Add("Partner:$(Split-Path $p.marketplacePartnerId -Leaf)") }
        foreach ($l in $p.logs) {
            if (-not $l.enabled) { continue }
            if ($l.category) { $enabled.Add($l.category) } elseif ($l.categoryGroup -eq 'allLogs') { $allLogs = $true }
        }
    }
    $missing = if ($allLogs) { @() } else { @($supported | Where-Object { $_ -notin $enabled }) }
    $row.Destinations = ($dests | Select-Object -Unique) -join ', '
    $row.Coverage = if (-not $settings.Count) { 'NO SETTING' } elseif ($allLogs -or -not $missing.Count) { 'full' } else { "partial $($supported.Count - $missing.Count)/$($supported.Count)" }
    $row.Missing = $missing -join ', '

    # plan: environment workspace
    $target = if ($WorkspaceMap) { $WorkspaceMap[$app.subscriptionId] } else { $null }
    $plans = @()
    if ($target) {
        $toTarget = $settings | Where-Object { Same-Id $_.properties.workspaceId $target } | Select-Object -First 1
        if ($toTarget) {
            $p = $toTarget.properties
            $en = @($p.logs | Where-Object { $_.enabled -and $_.category } | ForEach-Object category)
            $ag = @($p.logs | Where-Object { $_.enabled -and $_.categoryGroup -eq 'allLogs' }).Count -gt 0
            $mi = @($supported | Where-Object { $_ -notin $en })
            if ($ag -or -not $mi.Count) { $plans += @{ Action = 'OK'; Detail = 'already as wanted' } }
            else { $plans += @{ Action = 'UPDATE'; Name = $toTarget.name; Props = $p; Detail = "$($mi.Count) missing categories to enable" } }
        } else {
            $wrong = $settings | Where-Object { $_.properties.workspaceId -and -not (Same-Id $_.properties.workspaceId $CentralWorkspaceId) } | Select-Object -First 1
            if ($wrong -and -not $SkipRepoint) { $plans += @{ Action = 'REPOINT'; Name = $wrong.name; Props = $wrong.properties; Detail = "$(Split-Path $wrong.properties.workspaceId -Leaf) -> $(Split-Path $target -Leaf)" } }
            elseif ($wrong) { $plans += @{ Action = 'SKIP'; Detail = "wrong workspace ($(Split-Path $wrong.properties.workspaceId -Leaf)), -SkipRepoint set" } }
            elseif ($settings.Count -ge $limit) { $plans += @{ Action = 'SKIP'; Detail = "diagnostic setting limit reached ($($settings.Count)/$limit)" } }
            else { $plans += @{ Action = 'CREATE'; Name = $DefaultSettingName; Props = $null; Detail = "new setting -> $(Split-Path $target -Leaf)" } }
        }
    } elseif ($Sync -and $WorkspaceMap) { $plans += @{ Action = 'SKIP'; Detail = 'subscription not in -WorkspaceMap' } }

    if ($CentralWorkspaceId) {
        $cs = $settings | Where-Object { Same-Id $_.properties.workspaceId $CentralWorkspaceId } | Select-Object -First 1
        if ($cs) {
            $p = $cs.properties
            $en = @($p.logs | Where-Object { $_.enabled -and $_.category } | ForEach-Object category)
            $ag = @($p.logs | Where-Object { $_.enabled -and $_.categoryGroup -eq 'allLogs' }).Count -gt 0
            $mi = @($supported | Where-Object { $_ -notin $en })
            $mOn = @($p.metrics | Where-Object { $_.enabled }).Count -gt 0
            if (($ag -or -not $mi.Count) -and -not ($RemoveMetrics -and $mOn)) { $plans += @{ Action = 'OK'; Central = $true; Detail = 'central already as wanted' } }
            else { $plans += @{ Action = 'UPDATE'; Central = $true; Name = $cs.name; Props = $p; Detail = "central: $($mi.Count) missing categories" } }
        } elseif (($settings.Count + @($plans | Where-Object { $_.Action -eq 'CREATE' }).Count) -ge $limit) {
            $plans += @{ Action = 'SKIP'; Central = $true; Detail = "central: diagnostic setting limit reached ($($settings.Count)/$limit)" }
        } else { $plans += @{ Action = 'CREATE'; Central = $true; Name = $CentralSettingName; Props = $null; Detail = 'central: new setting' } }
    }

    if (-not $plans.Count) {
        $row.Action = if ($row.Coverage -eq 'full') { 'OK' } elseif ($row.Coverage -eq 'NO SETTING') { 'NO SETTING' } else { 'PARTIAL' }
        $row.Detail = 'audit only'; & $add $row; continue
    }

    foreach ($pl in $plans) {
        $r = [ordered]@{}; foreach ($k in $row.Keys) { $r[$k] = $row[$k] }
        $r.Action = $pl.Action; $r.Detail = $pl.Detail
        if ($pl.Action -in 'OK', 'SKIP' -or -not $Sync) { if (-not $Sync -and $pl.Action -notin 'OK', 'SKIP') { $r.Result = 'PLAN (audit)' }; & $add $r; continue }
        $wsId = if ($pl.Central) { $CentralWorkspaceId } else { $target }
        $props = @{ workspaceId = $wsId; logs = (ConvertTo-LogList $supported); metrics = @() }
        if ($pl.Props) {
            # PUT replaces: carry over non-workspace destinations and (unless removed) metrics.
            foreach ($k in 'storageAccountId', 'eventHubAuthorizationRuleId', 'eventHubName', 'marketplacePartnerId', 'serviceBusRuleId', 'logAnalyticsDestinationType') { if ($pl.Props.$k) { $props[$k] = $pl.Props.$k } }
            if (-not $RemoveMetrics) {
                $props.metrics = @($pl.Props.metrics | Where-Object { $_ -and $_.category } | ForEach-Object { $m = @{ category = $_.category; enabled = [bool]$_.enabled }; if ($_.timeGrain) { $m.timeGrain = $_.timeGrain }; $m })
            }
        }
        if ($PSCmdlet.ShouldProcess($app.name, "$($pl.Action) setting '$($pl.Name)' -> $(Split-Path $wsId -Leaf) (all log categories)")) {
            try { Write-Setting $app.id $pl.Name $props; $r.Result = 'DONE'; Write-Host "[$($pl.Action)] $($app.name)" -ForegroundColor Green }
            catch { $r.Result = "ERROR: $_"; Write-Warning "$($app.name): $_" }
        } else { $r.Result = 'PLANNED' }
        & $add $r
    }
}
Write-Progress -Activity 'App Service diagnostics' -Completed

$res = @($out)
"`n=== Summary ==="
$res | Group-Object Action | Sort-Object Name | ForEach-Object { '{0,-11}: {1}' -f $_.Name, $_.Count }
"`n=== Coverage ==="
$res | Group-Object Coverage | ForEach-Object { '{0,-20}: {1}' -f $_.Name, $_.Count }
$res | Where-Object { $_.Coverage -ne 'full' -or $_.Action -notin 'OK' } | Sort-Object Subscription, AppService |
    Format-Table Subscription, AppService, Destinations, Coverage, Action, Detail, Result -AutoSize -Wrap | Out-String -Width 4096 | Write-Host
if ($OutCsv) { $res | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8; Write-Host "CSV: $OutCsv" }
$errs = @($res | Where-Object { $_.Result -like 'ERROR*' })
if ($errs.Count) { throw "$($errs.Count) write(s) failed. See the table above." }
$res
