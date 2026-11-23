#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Training lab: one resource group per participant, Contributor only on that group, deny policies for
    expensive resources, and a monthly budget alert. Dry run unless -Apply.

.DESCRIPTION
    For each participant (UPN):
      1. Resource group <Prefix>-<name> with tags <PurposeTagName>=<PurposeTagValue>, owner, delete-after date.
      2. Contributor on that resource group only (looked up in Entra ID; guests are found by UPN or mail).
      3. Two built-in Azure Policy assignments on the resource group:
           Allowed virtual machine size SKUs   (cccc23c7-8427-4f53-ad12-b6a63eb452b3, built-in)
           Not allowed resource types          (6c112d4e-5bc7-47ae-a041-ea2d9dccd749, built-in, effect Deny)
      4. A monthly cost budget on the resource group with an e-mail alert at -AlertThresholdPercent.

    Idempotent: what exists is reported and left alone. Without -Apply nothing is changed and the plan is
    printed; with -Apply every write also honours -WhatIf / -Confirm. Remove-LabResources.ps1 tears it down
    (same -Prefix and purpose tag defaults).

.PARAMETER UserPrincipalName
    Participant UPNs. Or -ParticipantFile.
.PARAMETER ParticipantFile
    Text file, one UPN per line; blank lines and lines starting with # are skipped.
.PARAMETER Location
    Region for the resource groups. Default westeurope.
.PARAMETER Prefix
    Resource group name prefix. Default rg-lab.
.PARAMETER BudgetAmount
    Monthly budget per participant in the billing currency. Default 40.
.PARAMETER AlertEmail
    Trainer address for budget alerts.
.PARAMETER AlertThresholdPercent
    Budget alert threshold. Default 80.
.PARAMETER AllowedVmSize
    VM sizes participants may create.
.PARAMETER DeniedResourceType
    Resource types participants may not create at all.
.PARAMETER ExpiryDays
    Written as the delete-after tag. Default 30.
.PARAMETER PurposeTagName
    Default purpose. Remove-LabResources.ps1 deletes only groups that carry this tag with -PurposeTagValue.
.PARAMETER PurposeTagValue
    Default training.
.PARAMETER Apply
    Make the changes. Without it the script only reads and prints the plan.

.EXAMPLE
    ./Azure/Subscription-Management/New-LabParticipant.ps1 -ParticipantFile ./participants.txt -AlertEmail trainer@contoso.com

.EXAMPLE
    Set-AzContext -Subscription '<lab subscription>'
    ./Azure/Subscription-Management/New-LabParticipant.ps1 -ParticipantFile ./participants.txt -AlertEmail trainer@contoso.com -Apply

.NOTES
    Role on the lab subscription: Owner, or Contributor + User Access Administrator (role assignments) +
    Resource Policy Contributor (policy assignments). Budgets need Cost Management Contributor. Activate PIM first.
    Modules: Az.Accounts, Az.Resources. Policy and budget calls use ARM REST (Azure/Common/Az-Helpers.ps1)
    because the Az policy cmdlets changed their output objects between major versions.
    UNTESTED: the built-in policy assignment path (the source used custom definitions with the same rules).
    Verify once in a test subscription: parameter names listOfAllowedSKUs, listOfResourceTypesNotAllowed and
    effect, and that a denied size is refused.
    Traps kept from real use:
      - Grant Contributor at the resource group scope only, never the subscription.
      - Guests have an #EXT# UPN in the tenant; a lookup by their home UPN fails, so mail is tried as well.
      - A budget start date must be the first day of a month and not before the current month.
      - Policy assignments on a resource group take a few minutes to apply; test a denied deployment after.
      - A dry run must not report "applied": the summary says "would create" until -Apply is given.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'ByFile')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByUpn')][string[]]$UserPrincipalName,
    [Parameter(Mandatory, ParameterSetName = 'ByFile')][string]$ParticipantFile,
    [string]$Location = 'westeurope',
    [ValidatePattern('^[A-Za-z0-9._()-]+$')][string]$Prefix = 'rg-lab',
    [int]$BudgetAmount = 40,
    [Parameter(Mandatory)][string]$AlertEmail,
    [ValidateRange(1, 1000)][int]$AlertThresholdPercent = 80,
    [string[]]$AllowedVmSize = @('Standard_B1s', 'Standard_B2s', 'Standard_B2ms', 'Standard_D2s_v5', 'Standard_D2as_v5'),
    [string[]]$DeniedResourceType = @(
        'Microsoft.Network/azureFirewalls', 'Microsoft.Network/expressRouteCircuits', 'Microsoft.Network/virtualNetworkGateways',
        'Microsoft.Network/applicationGateways', 'Microsoft.Sql/managedInstances', 'Microsoft.DBforPostgreSQL/serverGroupsv2',
        'Microsoft.Databricks/workspaces', 'Microsoft.Synapse/workspaces', 'Microsoft.HDInsight/clusters',
        'Microsoft.ContainerService/managedClusters', 'Microsoft.DesktopVirtualization/hostPools'),
    [int]$ExpiryDays = 30,
    [string]$PurposeTagName = 'purpose',
    [string]$PurposeTagValue = 'training',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount and Set-AzContext to the lab subscription.' }
$subId = $ctx.Subscription.Id
$subScope = "/subscriptions/$subId"

$upns = if ($PSCmdlet.ParameterSetName -eq 'ByFile') {
    if (-not (Test-Path -LiteralPath $ParticipantFile)) { throw "Participant file not found: $ParticipantFile" }
    @(Get-Content -LiteralPath $ParticipantFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
} else { @($UserPrincipalName) }
if (-not $upns.Count) { throw 'No participants.' }

# Built-in policy definitions (Microsoft-owned GUIDs, same in every tenant).
$PolicyAllowedSizes = '/providers/Microsoft.Authorization/policyDefinitions/cccc23c7-8427-4f53-ad12-b6a63eb452b3'   # Allowed virtual machine size SKUs
$PolicyDeniedTypes = '/providers/Microsoft.Authorization/policyDefinitions/6c112d4e-5bc7-47ae-a041-ea2d9dccd749'    # Not allowed resource types
$tags = @{ $PurposeTagName = $PurposeTagValue; owner = $AlertEmail; 'delete-after' = (Get-Date).AddDays($ExpiryDays).ToString('yyyy-MM-dd') }

Write-Host "Subscription : $($ctx.Subscription.Name) ($subId)"
Write-Host "Participants : $($upns.Count), region $Location, budget $BudgetAmount per participant"
if (-not $Apply) { Write-Host 'MODE         : DRY RUN. Nothing will change. Add -Apply to make the changes.' -ForegroundColor Yellow }

function Get-SafeName([string]$Upn) {
    # name@contoso.com -> name ; guest name_home.com#EXT#@tenant -> name-home-com
    $local = ($Upn -split '#EXT#')[0].Split('@')[0]
    (($local.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}
function Do-Step([string]$Target, [string]$Action, [scriptblock]$Work) {
    if (-not $Apply) { Write-Host "  [plan] $Action" -ForegroundColor DarkGray; return 'would create' }
    if (-not $PSCmdlet.ShouldProcess($Target, $Action)) { return 'skipped (WhatIf)' }
    & $Work | Out-Null
    Write-Host "  done   $Action" -ForegroundColor Cyan
    'created'
}

$summary = [System.Collections.Generic.List[object]]::new()
$errors = 0
foreach ($upn in $upns) {
    $name = Get-SafeName $upn
    $rgName = "$Prefix-$name"
    $rgScope = "$subScope/resourceGroups/$rgName"
    Write-Host "$upn -> $rgName"
    $row = [ordered]@{ Participant = $upn; ResourceGroup = $rgName; User = 'not found'; ResourceGroupState = ''; Role = ''; Policy = ''; Budget = ''; Error = '' }
    try {
        # 1. resource group
        $rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
        $row.ResourceGroupState = if ($rg) { 'exists' } else { Do-Step $rgName 'create resource group' { New-AzResourceGroup -Name $rgName -Location $Location -Tag $tags } }
        $rgReady = [bool]$rg -or ($Apply -and $row.ResourceGroupState -eq 'created')

        # 2. user + Contributor on the resource group only
        $user = Get-AzADUser -UserPrincipalName $upn -ErrorAction SilentlyContinue
        if (-not $user) { $user = Get-AzADUser -Mail $upn -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $user) {
            Write-Warning "  $upn not found in Entra ID (not invited yet?); no role assignment."
            $row.Role = 'skipped: user not found'
        } else {
            $row.User = $user.Id
            $has = if ($rgReady) { @(Get-AzRoleAssignment -ObjectId $user.Id -Scope $rgScope -RoleDefinitionName Contributor -ErrorAction SilentlyContinue | Where-Object { $_.Scope -eq $rgScope }) } else { @() }
            $row.Role = if ($has.Count) { 'exists' } else { Do-Step $rgName "Contributor for $upn (resource group scope)" { New-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName Contributor -Scope $rgScope } }
        }

        # 3. policy assignments (built-in definitions)
        $pol = @()
        foreach ($p in @(
                @{ Name = "lab-allowed-sizes-$name"; Def = $PolicyAllowedSizes; Display = 'Lab: allowed VM sizes only'; Params = @{ listOfAllowedSKUs = @{ value = $AllowedVmSize } } },
                @{ Name = "lab-denied-types-$name"; Def = $PolicyDeniedTypes; Display = 'Lab: expensive resource types denied'; Params = @{ listOfResourceTypesNotAllowed = @{ value = $DeniedResourceType }; effect = @{ value = 'Deny' } } })) {
            if ($p.Name.Length -gt 64) { throw "Policy assignment name '$($p.Name)' is longer than 64 characters; shorten -Prefix or the UPN part." }
            $path = "$rgScope/providers/Microsoft.Authorization/policyAssignments/$($p.Name)?api-version=2023-04-01"
            $exists = if ($rgReady) { Invoke-ArmRequest -Path $path -IgnoreNotFound } else { $null }
            $state = if ($exists) { 'exists' } else {
                $body = @{ properties = @{ displayName = $p.Display; policyDefinitionId = $p.Def; parameters = $p.Params } }
                Do-Step $rgName "policy assignment $($p.Name)" { Invoke-ArmRequest -Method PUT -Path $path -Body $body }
            }
            $pol += $state
        }
        $row.Policy = ($pol | Sort-Object -Unique) -join ','

        # 4. budget on the resource group
        $bPath = "$rgScope/providers/Microsoft.Consumption/budgets/budget-$name?api-version=2023-05-01"
        $bExists = if ($rgReady) { Invoke-ArmRequest -Path $bPath -IgnoreNotFound } else { $null }
        $row.Budget = if ($bExists) { 'exists' } else {
            $start = (Get-Date -Day 1).ToString('yyyy-MM-01T00:00:00Z')   # first day of the current month
            $end = (Get-Date -Day 1).AddMonths(6).ToString('yyyy-MM-01T00:00:00Z')
            $body = @{ properties = @{
                category = 'Cost'; amount = $BudgetAmount; timeGrain = 'Monthly'; timePeriod = @{ startDate = $start; endDate = $end }
                notifications = @{ "actual_$AlertThresholdPercent" = @{ enabled = $true; operator = 'GreaterThan'; threshold = $AlertThresholdPercent; thresholdType = 'Actual'; contactEmails = @($AlertEmail) } }
            } }
            Do-Step $rgName "budget $BudgetAmount/month, alert at $AlertThresholdPercent%" { Invoke-ArmRequest -Method PUT -Path $bPath -Body $body }
        }
    }
    catch {
        $errors++
        $row.Error = "$_"
        Write-Warning "  $upn failed: $_"
    }
    $summary.Add([pscustomobject]$row)
}

$summary | Format-Table Participant, ResourceGroup, ResourceGroupState, Role, Policy, Budget, Error -AutoSize -Wrap
if (-not $Apply) { Write-Host 'DRY RUN: nothing was changed. Run again with -Apply.' -ForegroundColor Yellow }
else { Write-Host "Done. At the end of the training run Remove-LabResources.ps1 -Prefix $Prefix." -ForegroundColor Green }
if ($errors) { Write-Error "$errors participant(s) failed." -ErrorAction Continue; exit 1 }
