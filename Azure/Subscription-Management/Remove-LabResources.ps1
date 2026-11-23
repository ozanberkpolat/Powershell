#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Tear down a lab or training environment in the order Azure needs: locks, role assignments, backup
    vaults, diagnostic settings, policy assignments and budgets, resource groups, custom roles. Dry run unless -Apply.

.DESCRIPTION
    Selects resource groups whose name starts with -Prefix AND that carry <PurposeTagName>=<PurposeTagValue>
    (both conditions; a name prefix alone is never enough), plus any -ResourceGroupName you list (those
    must carry the tag too unless -SkipTagCheck). Then, in this order, because each step blocks the next:

      1. Management locks on the groups and their resources (a CanNotDelete lock fails the group delete).
      2. Role assignments scoped to the groups, including time-bound (PIM) assignments, which are removed
         with an AdminRemove schedule request rather than a plain delete. Optionally the subscription-scope
         assignments of -PrincipalObjectId (participants, trainer helper roles).
      3. Recovery Services vaults in the groups: undelete soft-deleted items, turn soft delete off, stop
         protection and delete backup data, delete the vault. A vault with soft delete "always on" or locked
         immutability cannot be emptied now: it is reported and its group is skipped.
      4. Optional subscription diagnostic setting (-SubscriptionDiagnosticSetting) and Log Analytics
         workspace (-WorkspaceResourceId, force delete so the same name can be reused at once).
      5. Policy assignments and budgets on the groups (they are listed so nothing is left behind).
      6. Resource group deletes, waiting until they are gone (or -NoWait).
      7. Optional custom role definitions (-CustomRoleName), retried while assignment removal propagates.

    Every step runs on; failures are collected and printed at the end, and the script exits 1 when any
    step failed. Without -Apply nothing is deleted and the plan is printed.

.PARAMETER Prefix
    Resource group name prefix. Default rg-lab (as New-LabParticipant.ps1).
.PARAMETER PurposeTagName
    Default purpose.
.PARAMETER PurposeTagValue
    Default training.
.PARAMETER ResourceGroupName
    Extra resource groups to remove (still tag-checked unless -SkipTagCheck).
.PARAMETER SkipTagCheck
    Remove -ResourceGroupName groups even without the purpose tag. Use with care.
.PARAMETER PrincipalObjectId
    Object IDs whose subscription-scope role assignments are removed too.
.PARAMETER SubscriptionDiagnosticSetting
    Name of a subscription Activity Log diagnostic setting created for the lab.
.PARAMETER WorkspaceResourceId
    Log Analytics workspace created for the lab (deleted with -ForceDelete).
.PARAMETER CustomRoleName
    Custom role definitions created for the lab.
.PARAMETER WaitMinutes
    How long to wait for resource group deletion. Default 40.
.PARAMETER NoWait
    Send the deletes and return.
.PARAMETER Apply
    Delete. Without it the script only reads and prints the plan. Deletion cannot be undone.

.EXAMPLE
    ./Azure/Subscription-Management/Remove-LabResources.ps1

.EXAMPLE
    ./Azure/Subscription-Management/Remove-LabResources.ps1 -Prefix rg-lab -CustomRoleName 'Lab Subnet Join' -Apply -Confirm:$false

.NOTES
    Role: Owner on the lab subscription (or Contributor + User Access Administrator; Backup Contributor for
    vaults). Activate PIM first. Modules: Az.Accounts, Az.Resources, Az.RecoveryServices (only when a vault exists),
    Az.OperationalInsights (only with -WorkspaceResourceId).
    UNTESTED: the vault and time-bound role steps have no PowerShell source (they ran with the Azure CLI).
    Verify on a disposable vault: Undo-AzRecoveryServicesBackupItemDeletion, Set-AzRecoveryServicesVaultProperty
    -SoftDeleteFeatureState Disable, Disable-AzRecoveryServicesBackupProtection -RemoveRecoveryPoints, and an
    AdminRemove roleAssignmentScheduleRequest at resource group scope.
    Traps kept from real use:
      - Order matters: locks before deletes, vault contents before the vault, the vault before its group,
        role assignments before custom role definitions.
      - A vault with soft delete always on keeps deleted items 14 days (free) and cannot be deleted before.
        Immutability must be Disabled (only possible while unlocked) before backup data can be deleted.
      - A custom role cannot be deleted while assignments exist, and assignment removal takes minutes to
        propagate (RoleDefinitionHasAssignments): retry.
      - Time-bound PIM assignments are schedule instances: a plain DELETE of the assignment does not end
        them; send an AdminRemove request.
      - Guest user objects may not be deletable with lab rights (403); remove guests separately in Entra ID.
      - Delete the lab workspace with force, or its name stays reserved for 14 days and a rebuild fails.
      - Only AzureVM backup items are handled; another workload type in a vault stops that vault loudly.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidatePattern('^[A-Za-z0-9._()-]+$')][string]$Prefix = 'rg-lab',
    [string]$PurposeTagName = 'purpose',
    [string]$PurposeTagValue = 'training',
    [string[]]$ResourceGroupName = @(),
    [switch]$SkipTagCheck,
    [string[]]$PrincipalObjectId = @(),
    [string]$SubscriptionDiagnosticSetting,
    [string]$WorkspaceResourceId,
    [string[]]$CustomRoleName = @(),
    [int]$WaitMinutes = 40,
    [switch]$NoWait,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount and Set-AzContext to the lab subscription.' }
$subId = $ctx.Subscription.Id
$subScope = "/subscriptions/$subId"
$errors = [System.Collections.Generic.List[string]]::new()

function Step([string]$Target, [string]$Action, [scriptblock]$Work) {
    if (-not $Apply) { Write-Host "  [plan] $Action" -ForegroundColor DarkGray; return $true }
    if (-not $PSCmdlet.ShouldProcess($Target, $Action)) { return $false }
    try { & $Work | Out-Null; Write-Host "  OK   $Action" -ForegroundColor Cyan; $true }
    catch { $errors.Add("${Action}: $_"); Write-Warning "  FAIL $Action : $_"; $false }
}

# ---- select resource groups: prefix AND tag ------------------------------------------------------
$all = @(Get-AzResourceGroup)
function Test-Tag($rg) { $rg.Tags -and $rg.Tags.ContainsKey($PurposeTagName) -and $rg.Tags[$PurposeTagName] -eq $PurposeTagValue }
$targets = @($all | Where-Object { $_.ResourceGroupName.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Tag $_) })
foreach ($n in $ResourceGroupName) {
    $rg = $all | Where-Object ResourceGroupName -eq $n
    if (-not $rg) { Write-Warning "Resource group $n not found (already deleted?)."; continue }
    if (-not $SkipTagCheck -and -not (Test-Tag $rg)) { throw "Resource group $n does not carry $PurposeTagName=$PurposeTagValue. Tag it or pass -SkipTagCheck." }
    $targets += $rg
}
$targets = @($targets | Sort-Object ResourceGroupName -Unique)

Write-Host "Subscription: $($ctx.Subscription.Name) ($subId)"
Write-Host ("Mode: {0}" -f $(if ($Apply) { 'APPLY (deletes cannot be undone)' } else { 'DRY RUN (nothing changes; add -Apply)' })) -ForegroundColor Yellow
if (-not $targets.Count) { Write-Host "No resource group matches prefix '$Prefix' with $PurposeTagName=$PurposeTagValue." -ForegroundColor Green }
foreach ($rg in $targets) {
    $n = @(Get-AzResource -ResourceGroupName $rg.ResourceGroupName).Count
    Write-Host ('  {0,-45} {1,4} resources  {2}' -f $rg.ResourceGroupName, $n, $rg.Location)
}
$skipRg = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

# ---- 1. locks ---------------------------------------------------------------------------------------
Write-Host "`n1. Locks"
foreach ($rg in $targets) {
    foreach ($l in @(Get-AzResourceLock -ResourceGroupName $rg.ResourceGroupName)) {
        $null = Step $rg.ResourceGroupName "remove lock $($l.Name) ($($l.Properties.level)) on $($l.ResourceId)" { Remove-AzResourceLock -LockId $l.LockId -Force }
    }
}

# ---- 2. role assignments --------------------------------------------------------------------------
Write-Host "`n2. Role assignments"
$scopes = @($targets | ForEach-Object { $_.ResourceId })
foreach ($scope in $scopes) {
    foreach ($a in @(Get-AzRoleAssignment -Scope $scope | Where-Object { $_.Scope -eq $scope })) {
        $null = Step $scope "remove $($a.RoleDefinitionName) for $($a.DisplayName) ($($a.ObjectType))" { Remove-AzRoleAssignment -InputObject $a }
    }
    # time-bound (PIM) assignments: end them with an AdminRemove schedule request
    $inst = @(Invoke-Arm -Path "$scope/providers/Microsoft.Authorization/roleAssignmentScheduleInstances" -ApiVersion '2020-10-01')
    foreach ($i in $inst | Where-Object { $_.properties.endDateTime -and $_.properties.scope -eq $scope }) {
        $p = $i.properties
        $body = @{ properties = @{ principalId = $p.principalId; roleDefinitionId = $p.roleDefinitionId; requestType = 'AdminRemove'; justification = 'lab teardown' } }
        $null = Step $scope "end time-bound role $($p.roleDefinitionId.Split('/')[-1]) for $($p.principalId)" {
            Invoke-ArmRequest -Method PUT -Path "$scope/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/$([guid]::NewGuid())?api-version=2020-10-01" -Body $body }
    }
}
foreach ($oid in $PrincipalObjectId) {
    foreach ($a in @(Get-AzRoleAssignment -ObjectId $oid -Scope $subScope | Where-Object { $_.Scope -eq $subScope })) {
        $null = Step $subScope "remove subscription-scope $($a.RoleDefinitionName) for $($a.DisplayName)" { Remove-AzRoleAssignment -InputObject $a }
    }
}

# ---- 3. Recovery Services vaults ------------------------------------------------------------------
Write-Host "`n3. Recovery Services vaults"
foreach ($rg in $targets) {
    $vaultIds = @(Get-AzResource -ResourceGroupName $rg.ResourceGroupName -ResourceType 'Microsoft.RecoveryServices/vaults' | ForEach-Object ResourceId)
    if (-not $vaultIds.Count) { continue }
    Import-Module Az.RecoveryServices -ErrorAction Stop
    foreach ($vid in $vaultIds) {
        $v = Get-AzRecoveryServicesVault -ResourceGroupName $rg.ResourceGroupName -Name $vid.Split('/')[-1]
        $prop = Get-AzRecoveryServicesVaultProperty -VaultId $v.ID
        $items = @(Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $v.ID)
        Write-Host "  $($v.Name): $($items.Count) VM item(s), soft delete $($prop.SoftDeleteFeatureState)"
        if ("$($prop.SoftDeleteFeatureState)" -match 'AlwaysON') {
            Write-Warning "  $($v.Name): soft delete is always on; items stay 14 days and the vault (and group $($rg.ResourceGroupName)) cannot be deleted before. Skipping the group."
            $null = $skipRg.Add($rg.ResourceGroupName); continue
        }
        if ("$($v.Properties.ImmutabilitySettings.ImmutabilityState)" -eq 'Locked') {
            Write-Warning "  $($v.Name): immutability is LOCKED; backup data cannot be deleted before retention ends. Skipping the group."
            $null = $skipRg.Add($rg.ResourceGroupName); continue
        }
        if ("$($v.Properties.ImmutabilitySettings.ImmutabilityState)" -eq 'Unlocked') {
            $null = Step $v.Name "$($v.Name): immutability Disabled" { Update-AzRecoveryServicesVault -ResourceGroupName $rg.ResourceGroupName -Name $v.Name -ImmutabilityState Disabled }
        }
        foreach ($it in $items | Where-Object { $_.DeleteState -eq 'ToBeDeleted' }) {
            $null = Step $v.Name "$($v.Name): undelete soft-deleted $($it.Name)" { Undo-AzRecoveryServicesBackupItemDeletion -Item $it -VaultId $v.ID -Force }
        }
        $null = Step $v.Name "$($v.Name): soft delete off" { Set-AzRecoveryServicesVaultProperty -VaultId $v.ID -SoftDeleteFeatureState Disable }
        foreach ($it in $items) {
            $null = Step $v.Name "$($v.Name): stop protection and delete data of $($it.Name)" {
                $fresh = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $v.ID | Where-Object Name -eq $it.Name
                Disable-AzRecoveryServicesBackupProtection -Item $fresh -VaultId $v.ID -RemoveRecoveryPoints -Force }
        }
        $other = @(Get-AzRecoveryServicesBackupContainer -ContainerType AzureSQL -VaultId $v.ID -ErrorAction SilentlyContinue) +
                 @(Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $v.ID -ErrorAction SilentlyContinue)
        if ($other.Count) {
            $errors.Add("$($v.Name): non-VM backup containers present ($($other.Count)); empty them by hand.")
            $null = $skipRg.Add($rg.ResourceGroupName); continue
        }
        $null = Step $v.Name "delete vault $($v.Name)" { Remove-AzRecoveryServicesVault -Vault $v }
    }
}

# ---- 4. subscription diagnostic setting and workspace -----------------------------------------------
Write-Host "`n4. Diagnostic setting and workspace"
if ($SubscriptionDiagnosticSetting) {
    $ds = Invoke-ArmRequest -Path "$subScope/providers/Microsoft.Insights/diagnosticSettings/$($SubscriptionDiagnosticSetting)?api-version=2021-05-01-preview" -IgnoreNotFound
    if ($ds) { $null = Step $subScope "delete subscription diagnostic setting $SubscriptionDiagnosticSetting" { Invoke-ArmRequest -Method DELETE -Path "$subScope/providers/Microsoft.Insights/diagnosticSettings/$($SubscriptionDiagnosticSetting)?api-version=2021-05-01-preview" } }
    else { Write-Host "  $SubscriptionDiagnosticSetting not found" }
}
if ($WorkspaceResourceId) {
    $ws = Invoke-ArmRequest -Path "$($WorkspaceResourceId)?api-version=2022-10-01" -IgnoreNotFound
    if ($ws) { $null = Step $WorkspaceResourceId 'force delete workspace (name reusable at once)' { Invoke-ArmRequest -Method DELETE -Path "$($WorkspaceResourceId)?api-version=2022-10-01&force=true" } }
    else { Write-Host '  workspace not found' }
}

# ---- 5. policy assignments and budgets -------------------------------------------------------------
Write-Host "`n5. Policy assignments and budgets"
foreach ($rg in $targets) {
    $scope = $rg.ResourceId
    foreach ($pa in @(Invoke-Arm -Path "$scope/providers/Microsoft.Authorization/policyAssignments" -ApiVersion '2023-04-01' | Where-Object { $_.properties.scope -eq $scope })) {
        $null = Step $scope "remove policy assignment $($pa.name)" { Invoke-ArmRequest -Method DELETE -Path "$($pa.id)?api-version=2023-04-01" }
    }
    foreach ($b in @(Invoke-Arm -Path "$scope/providers/Microsoft.Consumption/budgets" -ApiVersion '2023-05-01')) {
        $null = Step $scope "remove budget $($b.name)" { Invoke-ArmRequest -Method DELETE -Path "$($b.id)?api-version=2023-05-01" }
    }
}

# ---- 6. resource groups --------------------------------------------------------------------------
Write-Host "`n6. Resource groups"
$deleting = @()
foreach ($rg in $targets) {
    if ($skipRg.Contains($rg.ResourceGroupName)) { Write-Warning "  skipping $($rg.ResourceGroupName) (see above)"; continue }
    if (Step $rg.ResourceGroupName "delete resource group $($rg.ResourceGroupName)" { Remove-AzResourceGroup -Name $rg.ResourceGroupName -Force -AsJob }) { $deleting += $rg.ResourceGroupName }
}
if ($Apply -and $deleting.Count -and -not $NoWait) {
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    do {
        $left = @($deleting | Where-Object { Get-AzResourceGroup -Name $_ -ErrorAction SilentlyContinue })
        if (-not $left.Count) { Write-Host '  all deleted' -ForegroundColor Green; break }
        Write-Host ("  waiting ({0:HH:mm}): {1}" -f (Get-Date), ($left -join ', '))
        Start-Sleep -Seconds 60
    } while ((Get-Date) -lt $deadline)
    if ($left.Count) { $errors.Add("not deleted after $WaitMinutes min: $($left -join ', ') (check Get-Job and the Activity Log)") }
}

# ---- 7. custom roles --------------------------------------------------------------------------------
Write-Host "`n7. Custom roles"
foreach ($name in $CustomRoleName) {
    $def = Get-AzRoleDefinition -Name $name -ErrorAction SilentlyContinue
    if (-not $def -or -not $def.IsCustom) { Write-Host "  $name not found (or not custom)"; continue }
    $null = Step $subScope "delete custom role $name" {
        for ($i = 1; $i -le 10; $i++) {
            # Assignment removal propagates slowly: RoleDefinitionHasAssignments for a few minutes.
            try { Remove-AzRoleDefinition -Id $def.Id -Force; return }
            catch { if ($i -eq 10 -or "$_" -notmatch 'HasAssignments') { throw }; Start-Sleep -Seconds 30 }
        }
    }
}

if ($errors.Count) {
    Write-Host "`n$($errors.Count) ERROR(S):" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
if (-not $Apply) { Write-Host "`nDRY RUN: nothing was deleted. Run again with -Apply." -ForegroundColor Yellow }
else { Write-Host "`nDone. Check Cost Management the next day: consumption for these groups should drop to zero." -ForegroundColor Green }
