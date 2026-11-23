#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Send blob storage logs (StorageRead/Write/Delete) to a Log Analytics workspace: built-in DeployIfNotExists
    policy per subscription (default), or diagnostic settings written directly. Report by default.

.DESCRIPTION
    Two ways, one script:

    -Mode Policy (default)
        Assigns the built-in policy "Configure diagnostic settings for Blob Services to Log Analytics
        workspace" at each subscription, with a system-assigned identity, then gives that identity the roles
        the policy definition asks for (read from the definition at run time, not hard-coded) on the
        subscription and Log Analytics Contributor on the workspace, then starts a remediation task so
        existing accounts are covered too. New storage accounts are covered automatically from then on.

    -Mode Direct
        Writes a diagnostic setting on <account>/blobServices/default for every storage account in scope
        (StorageRead, StorageWrite, StorageDelete logs and the Transaction metric, resource-specific tables).
        Accounts that already send StorageRead to the same workspace are left alone. Use it when you cannot
        assign policy, or to cover existing accounts at once.

    Without -Apply the script only reports what it would do. With -Apply every write is guarded by
    ShouldProcess, so -Apply -WhatIf prints the plan.

    UNTESTED: the remediation task call (Microsoft.PolicyInsights/remediations) and the Direct mode REST body
    were written from Microsoft Learn; the original run used az CLI. Verify on one subscription first and
    check the remediation task in the portal (Policy > Remediation).

.PARAMETER WorkspaceResourceId
    Resource ID of the target Log Analytics workspace (for Sentinel, the Sentinel workspace).
.PARAMETER Subscription
    Subscriptions to cover. Default: every enabled subscription.
.PARAMETER Mode
    Policy (default) or Direct.
.PARAMETER AssignmentName
    Policy assignment name. Default 'blob-diag-to-law'.
.PARAMETER SettingName
    Diagnostic setting name for Direct mode. Default 'blob-logs-to-law'.
.PARAMETER ExcludeNamePattern
    Regex on storage account names to skip in Direct mode, for example 'asrcache$' for Site Recovery cache
    accounts (machine replication traffic: high volume, almost no security value). Not applied by the
    policy, which covers every account; add a policy exemption for those instead.
.PARAMETER NoRemediation
    Policy mode: do not start a remediation task (only new or updated accounts get the setting).
.PARAMETER Apply
    Make the changes. Without it the script only reports.

.EXAMPLE
    ./Set-BlobDiagnosticsPolicy.ps1 -WorkspaceResourceId $lawId                       # report, policy mode

.EXAMPLE
    ./Set-BlobDiagnosticsPolicy.ps1 -WorkspaceResourceId $lawId -Subscription $subA,$subB -Apply

.EXAMPLE
    ./Set-BlobDiagnosticsPolicy.ps1 -WorkspaceResourceId $lawId -Mode Direct -ExcludeNamePattern 'asrcache$' -Apply -WhatIf

.NOTES
    Role, Policy mode: Resource Policy Contributor to assign, plus User Access Administrator (or Owner) on
    each subscription AND on the workspace, because the script creates role assignments for the policy
    identity. Role, Direct mode: Monitoring Contributor on the storage accounts and Log Analytics
    Contributor on the workspace. Reader is enough for the report. Activate PIM first. Modules: Az.Accounts.
    Traps kept:
      - Policy definition ID b4fe1a3b-0715-4c6c-a5ea-ffc33cf823cb is the Microsoft built-in definition
        named above (well-known, the same in every tenant).
      - The policy identity needs the roles from the definition's roleDefinitionIds at the assignment scope,
        AND Log Analytics Contributor on the workspace when the workspace sits in another subscription,
        otherwise every deployment fails with an authorization error.
      - A role assignment for a brand-new identity can fail with PrincipalNotFound for a minute (directory
        replication); the script retries.
      - Remediation started before the roles have propagated fails for some resources; re-run the
        remediation (or the script) after a few minutes if the task shows failures.
      - Assign per subscription when you have no management group rights; a management group assignment is
        simpler where you have them.
      - Az policy cmdlets changed their output objects between major versions; this script uses ARM REST.
      - A diagnostic setting is a PUT that replaces the whole setting, at most 5 per resource, and the same
        category cannot go to the same workspace twice: Direct mode skips accounts that already send
        StorageRead to the workspace and accounts at the limit.
      - FileStorage (premium files) accounts have no blob service and are skipped.
      - StorageRead on busy accounts (Site Recovery cache, backup staging, data lake ingestion) can mean tens
        of GB per day of ingestion. Check volumes before covering everything.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [string[]]$Subscription,
    [ValidateSet('Policy', 'Direct')][string]$Mode = 'Policy',
    [string]$AssignmentName = 'blob-diag-to-law',
    [string]$SettingName = 'blob-logs-to-law',
    [string]$ExcludeNamePattern,
    [switch]$NoRemediation,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }

$policyDefId = '/providers/Microsoft.Authorization/policyDefinitions/b4fe1a3b-0715-4c6c-a5ea-ffc33cf823cb'   # built-in: Configure diagnostic settings for Blob Services to Log Analytics workspace
$laContributor = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'   # built-in role: Log Analytics Contributor
$ws = Invoke-ArmRequest -Path "$($WorkspaceResourceId.TrimEnd('/'))?api-version=2022-10-01" -IgnoreNotFound
if (-not $ws) { throw "Workspace not found or not readable: $WorkspaceResourceId" }
$wsId = $ws.id
$wsSub = $wsId.Split('/')[2]
if (-not $Subscription) { $Subscription = @((Get-EnabledSubscription).Id) }

function New-StableGuid([string]$Seed) {
    # Same seed -> same role assignment name, so a re-run is idempotent.
    $md5 = [System.Security.Cryptography.MD5]::Create()
    [guid]::new($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed))).ToString()
}

function Grant-Role([string]$Scope, [string]$PrincipalId, [string]$RoleGuid) {
    $roleDefId = "/subscriptions/$($Scope.Split('/')[2])/providers/Microsoft.Authorization/roleDefinitions/$RoleGuid"
    $name = New-StableGuid "$Scope|$PrincipalId|$RoleGuid"
    $body = @{ properties = @{ roleDefinitionId = $roleDefId; principalId = $PrincipalId; principalType = 'ServicePrincipal' } }
    for ($i = 1; $i -le 6; $i++) {
        try {
            Invoke-ArmRequest -Method PUT -Path "$Scope/providers/Microsoft.Authorization/roleAssignments/$($name)?api-version=2022-04-01" -Body $body | Out-Null
            Write-Host "    role $RoleGuid on $($Scope.Split('/')[-1]): ok"; return
        } catch {
            if ("$_" -match 'RoleAssignmentExists') { Write-Host "    role $RoleGuid on $($Scope.Split('/')[-1]): already there"; return }
            if ("$_" -match 'PrincipalNotFound' -and $i -lt 6) { Write-Warning "    identity not replicated yet, retry in 15s ($i/5)"; Start-Sleep 15; continue }
            throw
        }
    }
}

if ($Mode -eq 'Policy') {
    $def = Invoke-ArmRequest -Path "$($policyDefId)?api-version=2023-04-01"
    if ($def.properties.parameters.PSObject.Properties.Name -notcontains 'logAnalytics') {
        throw "Built-in definition no longer has a 'logAnalytics' parameter (version $($def.properties.metadata.version)). Check its parameters before assigning."
    }
    $roles = @($def.properties.policyRule.then.details.roleDefinitionIds | ForEach-Object { $_.Split('/')[-1] })
    if (-not $roles.Count) { throw 'Policy definition lists no roleDefinitionIds; cannot grant its identity.' }
    Write-Host "Policy: $($def.properties.displayName) v$($def.properties.metadata.version); identity roles: $($roles -join ', ')"

    $failed = 0
    foreach ($sub in $Subscription) {
        $scope = "/subscriptions/$sub"
        $path = "$scope/providers/Microsoft.Authorization/policyAssignments/$($AssignmentName)?api-version=2023-04-01"
        $cur = Invoke-ArmRequest -Path $path -IgnoreNotFound
        $curWs = $cur.properties.parameters.logAnalytics.value
        $state = if (-not $cur) { 'MISSING' } elseif ($curWs -ne $wsId) { "OTHER-WORKSPACE ($curWs)" } else { 'PRESENT' }
        Write-Host "== $sub  assignment: $state"
        if (-not $Apply) { continue }
        if (-not $PSCmdlet.ShouldProcess($scope, "Assign blob diagnostics policy to $($ws.name), grant its identity, remediate")) { continue }
        try {
            $body = @{
                location   = $ws.location
                identity   = @{ type = 'SystemAssigned' }
                properties = @{
                    displayName        = "Blob diagnostic logs to $($ws.name)"
                    policyDefinitionId = $policyDefId
                    parameters         = @{ logAnalytics = @{ value = $wsId } }
                }
            }
            $a = Invoke-ArmRequest -Method PUT -Path $path -Body $body
            $principalId = $a.identity.principalId
            if (-not $principalId) { throw 'Assignment returned no identity principalId.' }
            Write-Host "  assignment ok, identity $principalId"
            foreach ($r in $roles) { Grant-Role -Scope $scope -PrincipalId $principalId -RoleGuid $r }
            # Workspace in another subscription (or RG outside scope): the identity needs rights on it too.
            Grant-Role -Scope $wsId -PrincipalId $principalId -RoleGuid $laContributor
            if (-not $NoRemediation) {
                $rem = "$scope/providers/Microsoft.PolicyInsights/remediations/$AssignmentName-$(Get-Date -Format yyyyMMddHHmm)?api-version=2021-10-01"
                Invoke-ArmRequest -Method PUT -Path $rem -Body @{ properties = @{ policyAssignmentId = $a.id; resourceDiscoveryMode = 'ReEvaluateCompliance' } } | Out-Null
                Write-Host '  remediation task started (ReEvaluateCompliance)'
            }
        } catch { Write-Warning "  FAILED on ${sub}: $_"; $failed++ }
    }
    if (-not $Apply) { Write-Host 'Report only. Re-run with -Apply to assign.' }
    if ($failed) { throw "$failed subscription(s) failed." }
    return
}

# ---- Direct mode ----
$kql = "resources | where type =~ 'microsoft.storage/storageaccounts' | where kind != 'FileStorage' | project id, name | order by name asc"
$accts = @(Search-Graph -Query $kql -Subscription $Subscription)
if (-not $accts.Count) { throw 'No storage account with a blob service found in scope.' }
$diagApi = '2021-05-01-preview'
$body = @{ properties = @{
        workspaceId                 = $wsId
        logAnalyticsDestinationType = 'Dedicated'
        logs    = @(foreach ($c in 'StorageRead', 'StorageWrite', 'StorageDelete') { @{ category = $c; enabled = $true } })
        metrics = @(@{ category = 'Transaction'; enabled = $true })
    } }
$n = @{ create = 0; ok = 0; skip = 0; failed = 0 }
foreach ($sa in $accts) {
    if ($ExcludeNamePattern -and $sa.name -match $ExcludeNamePattern) { Write-Host "  SKIP (excluded): $($sa.name)"; $n.skip++; continue }
    $target = "$($sa.id)/blobServices/default"
    $existing = @(Invoke-Arm -Path "$target/providers/Microsoft.Insights/diagnosticSettings" -ApiVersion $diagApi)
    $covered = $existing | Where-Object { $_.properties.workspaceId -eq $wsId -and ($_.properties.logs | Where-Object { $_.category -eq 'StorageRead' -and $_.enabled }) }
    if ($covered) { Write-Host "  OK (already sends to workspace): $($sa.name)"; $n.ok++; continue }
    $mine = $existing | Where-Object name -eq $SettingName
    if (-not $mine -and $existing.Count -ge 5) { Write-Warning "  SKIP (5 diagnostic settings already): $($sa.name)"; $n.skip++; continue }
    if ($mine) { Write-Warning "  setting '$SettingName' exists on $($sa.name) with another destination: it will be replaced" }
    Write-Host "  CREATE: $($sa.name)"
    if (-not $Apply -or -not $PSCmdlet.ShouldProcess($sa.name, "Diagnostic setting $SettingName -> $($ws.name)")) { $n.create++; continue }
    try {
        Invoke-ArmRequest -Method PUT -Path "$target/providers/Microsoft.Insights/diagnosticSettings/$($SettingName)?api-version=$diagApi" -Body $body | Out-Null
        $n.create++
    } catch { Write-Warning "  FAILED $($sa.name): $_"; $n.failed++ }
}
Write-Host "Accounts: $($accts.Count)  create: $($n.create)  already ok: $($n.ok)  skipped: $($n.skip)  failed: $($n.failed)"
if (-not $Apply) { Write-Host 'Report only. Re-run with -Apply to write the settings.' }
if ($n.failed) { throw "$($n.failed) account(s) failed." }
