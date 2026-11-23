#Requires -Version 7.0
#Requires -Modules Az.Accounts, ImportExcel
<#
.SYNOPSIS
    Build an Environment + Criticality tag classification workbook (XLSX) from live Resource Graph data, for the
    application owners to confirm before any tag is written.

.DESCRIPTION
    Read-only. Queries Azure Resource Graph and writes an Excel workbook:

      Overview                 why, how to answer, colour legend, scope
      Application Criticality  one row per application group x environment (the fastest way to answer)
      Resource Groups          proposed Environment (subscription role + name tokens), draft Criticality, review flag
      Virtual Machines         per VM, with backup / replication / maintenance tags as protection signals
      In-Scope Resources       resource types that carry the classification (extensions and platform children excluded)
      Review Items             resource groups whose name gives no clear answer, with the question to ask
      Tag Standard             allowed values and what each one drives
      Current State            how many resources already carry the tags, layers, distributions
      Criticality Guidance     the rules behind every draft value, plus production VMs with no backup declared
      Next Steps               what happens once the workbook comes back (RG tags, inherit policy, audit)

    Grey columns are the derived proposal, yellow columns are for the owner, with drop-down validation.
    Raw query results are saved as JSON next to the workbook for traceability.

    Criticality is a yes/no business judgement: Yes = losing the resource stops or materially degrades a
    business service, or breaks a platform service every other service depends on. The draft comes from
    application grouping, environment and Site Recovery replication; the owner decides.

.PARAMETER Subscription
    Subscription IDs to include. Default: every enabled subscription you can read.
.PARAMETER SubscriptionRole
    Hashtable subscriptionId -> prod | nonprod | core. Default: guessed from the subscription name
    (core/hub/connectivity/identity/management/platform -> core, nonprod/dev/test/uat/qa -> nonprod, else prod).
.PARAMETER ApplicationGroupRule
    Ordered hashtable regex -> application group for YOUR applications, matched against the resource group
    name in order and BEFORE the built-in generic set (identity, network, security, monitoring, backup,
    management, avd, ai-workloads, apim, integration, appservices, sql). Unmatched groups become 'other'.
.PARAMETER CriticalApplicationGroup
    Application groups whose production/DR resource groups draft as Criticality Yes (business services).
.PARAMETER CriticalPlatformGroup
    Platform groups that draft as Yes in production, DR and core. Default identity, network, security, backup.
.PARAMETER SessionHostNamePattern
    VM name regex for pooled session hosts (drafted No: rebuilt from an image). Default '(?i)^(avd|vdi|sh)-'.
.PARAMETER RestoreTestPattern
    Resource group regex for restore and failover test environments (drafted No). Default '(?i)restore-?test'.
.PARAMETER BackupTag
    VM tag that says Azure Backup protects it (value Yes counts). Default BackupEnabled.
.PARAMETER BackupPolicyTag
    VM tag with the backup policy name, shown as-is. Default BackupPolicy.
.PARAMETER ReplicationTag
    VM tag that says Site Recovery replicates it (value Yes counts). Default ReplicationEnabled.
.PARAMETER MaintenanceTag
    VM tag with the maintenance configuration, shown as-is. Default MaintenanceConfiguration.
.PARAMETER EnvironmentTag
    Classification tag name for the environment. Default Environment.
.PARAMETER CriticalityTag
    Classification tag name for criticality. Default Criticality.
.PARAMETER OrganizationName
    Name shown on the Overview sheet and in the file properties. Default 'the organization'.
.PARAMETER OutputPath
    XLSX path. Default ./Tagging-Classification-Worksheet-<date>.xlsx.

.EXAMPLE
    Connect-AzAccount
    ./Azure/Tagging/Build-TaggingWorkbook.ps1 -OrganizationName Contoso

.EXAMPLE
    $role = @{ '<prod-sub-id>' = 'prod'; '<dev-sub-id>' = 'nonprod'; '<hub-sub-id>' = 'core' }
    $apps = [ordered]@{ '(?i)erp' = 'erp'; '(?i)crm' = 'crm'; '(?i)web' = 'website' }
    ./Azure/Tagging/Build-TaggingWorkbook.ps1 -Subscription @($role.Keys) -SubscriptionRole $role -ApplicationGroupRule $apps `
        -CriticalApplicationGroup erp,crm,website -OrganizationName Contoso

.NOTES
    Role: Reader on the subscriptions (Resource Graph). Writes nothing to Azure.
    Modules: Az.Accounts (Resource Graph through Azure/Common/Az-Helpers.ps1 Search-Graph, REST with
    $skipToken paging, so Az.ResourceGraph is not needed), ImportExcel.
    Traps kept from real use:
      - Resource Graph sees only the subscriptions you send; Search-Graph sends every readable one and pages.
      - Resource Graph KQL is a subset: tag counts use sum(iff(...)) rather than countif.
      - ImportExcel colours are passed as System.Drawing.Color objects; plain hex strings were not
        accepted for -BackgroundColor in every version.
      - Platform-created resource groups (AzureBackupRG_*, DefaultResourceGroup-*, NetworkWatcherRG ...)
        carry no business service: flagged for the owner, drafted No.
      - Keep the scope to resource types people create and pay for. Extensions, restore points, flow logs
        and other platform children are re-created by the services and their tags drift.
      - Do not plan a Deny policy on disks or NICs: Azure Backup restore and Site Recovery failover create
        untagged resources on your behalf, and a Deny would break them. Inherit-if-missing + audit is the
        safe enforcement.
      - The draft is for discussion. An empty answer column is not a decision.
#>
[CmdletBinding()]
param(
    [string[]]$Subscription,
    [hashtable]$SubscriptionRole = @{},
    [System.Collections.Specialized.OrderedDictionary]$ApplicationGroupRule,
    [string[]]$CriticalApplicationGroup = @(),
    [string[]]$CriticalPlatformGroup = @('identity', 'network', 'security', 'backup'),
    [string]$SessionHostNamePattern = '(?i)^(avd|vdi|sh)-',
    [string]$RestoreTestPattern = '(?i)restore-?test',
    [string]$BackupTag = 'BackupEnabled',
    [string]$BackupPolicyTag = 'BackupPolicy',
    [string]$ReplicationTag = 'ReplicationEnabled',
    [string]$MaintenanceTag = 'MaintenanceConfiguration',
    [string]$EnvironmentTag = 'Environment',
    [string]$CriticalityTag = 'Criticality',
    [string]$OrganizationName = 'the organization',
    [string]$OutputPath = "./Tagging-Classification-Worksheet-$(Get-Date -Format yyyy-MM-dd).xlsx"
)

$ErrorActionPreference = 'Stop'

$genericRules = [ordered]@{
    '(?i)identity|adds|entra|^rg-dc'           = 'identity'
    '(?i)network|connectivity|hub|vnet|firewall' = 'network'
    '(?i)security|sentinel|defender'           = 'security'
    '(?i)monitor|loganalytics|dcr|alert'       = 'monitoring'
    '(?i)backup|^rsv-|asr|siterecovery'        = 'backup'
    '(?i)management|automation|mgmt'           = 'management'
    '(?i)avd|wvd|vdi|desktop'                  = 'avd'
    '(?i)openai|foundry|cognitive|\bai\b'      = 'ai-workloads'
    '(?i)apim'                                 = 'apim'
    '(?i)logicapp|integration|servicebus'      = 'integration'
    '(?i)appservice|webapp|func'               = 'appservices'
    '(?i)sql|database|(^|-)db(-|$)'            = 'sql'
}
$AllRules = [ordered]@{}
if ($ApplicationGroupRule) { foreach ($k in $ApplicationGroupRule.Keys) { $AllRules[$k] = $ApplicationGroupRule[$k] } }
foreach ($k in $genericRules.Keys) { if (-not $AllRules.Contains($k)) { $AllRules[$k] = $genericRules[$k] } }

. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
Import-Module ImportExcel
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }

# ---------------------------------------------------------------- constants --
$subs = @(Get-EnabledSubscription)
if ($Subscription) { $subs = @($subs | Where-Object { $_.Id -in $Subscription }); if ($subs.Count -ne @($Subscription).Count) { throw 'Some -Subscription IDs are not readable or not enabled.' } }
$SubName = @{}; $SubKey = @{}
foreach ($s in $subs) {
    $SubName[$s.Id] = $s.Name
    $SubKey[$s.Id] = if ($SubscriptionRole.ContainsKey($s.Id)) { $SubscriptionRole[$s.Id] }
                     elseif ($s.Name -match '(?i)core|hub|connectivity|identity|management|platform') { 'core' }
                     elseif ($s.Name -match '(?i)non-?prod|dev|test|uat|qa|sandbox|lab') { 'nonprod' }
                     else { 'prod' }
}
$SubIds = @($subs.Id)
Write-Host ('Subscriptions: ' + (($subs | ForEach-Object { "$($_.Name)=$($SubKey[$_.Id])" }) -join ', '))

$EnvironmentValues = @('Production', 'NonProduction', 'Development', 'Test', 'UAT', 'DR', 'Core')
$CriticalityValues = @('Yes', 'No')
$YesNo = @('Yes', 'No')

$ScopePrefixes = @(
    'microsoft.compute/virtualmachines', 'microsoft.compute/disks', 'microsoft.compute/snapshots',
    'microsoft.compute/availabilitysets', 'microsoft.compute/images', 'microsoft.sqlvirtualmachine/',
    'microsoft.storage/storageaccounts',
    'microsoft.network/networkinterfaces', 'microsoft.network/networksecuritygroups',
    'microsoft.network/virtualnetworks', 'microsoft.network/routetables',
    'microsoft.network/publicipaddresses', 'microsoft.network/privateendpoints',
    'microsoft.network/loadbalancers', 'microsoft.network/applicationgateways',
    'microsoft.network/virtualnetworkgateways', 'microsoft.network/expressroutecircuits',
    'microsoft.network/ipgroups', 'microsoft.network/serviceendpointpolicies',
    'microsoft.network/publicipprefixes', 'microsoft.network/localnetworkgateways',
    'microsoft.network/connections', 'microsoft.network/azurefirewalls', 'microsoft.network/bastionhosts',
    'microsoft.web/sites', 'microsoft.web/serverfarms', 'microsoft.web/connections',
    'microsoft.logic/workflows', 'microsoft.datafactory/', 'microsoft.eventhub/', 'microsoft.servicebus/',
    'microsoft.apimanagement/', 'microsoft.appconfiguration/', 'microsoft.cognitiveservices/accounts',
    'microsoft.sql/', 'microsoft.dbforpostgresql/', 'microsoft.dbformysql/',
    'microsoft.operationalinsights/workspaces', 'microsoft.insights/components',
    'microsoft.insights/datacollectionrules', 'microsoft.insights/datacollectionendpoints',
    'microsoft.insights/actiongroups', 'microsoft.keyvault/vaults',
    'microsoft.recoveryservices/vaults', 'microsoft.automation/automationaccounts',
    'microsoft.desktopvirtualization/', 'microsoft.containerservice/managedclusters', 'microsoft.containerregistry/'
)
$PlatformRgPattern = '(?i)^(azurebackuprg_|defaultresourcegroup|loganalyticsdefaultresources|networkwatcherrg|visualstudioonline-|zonalmove-|azureapp-auto-alerts|resource-graph-queries|dashboards$|mc_|ma_)'

$Navy = [System.Drawing.ColorTranslator]::FromHtml('#1F3864')
$White = [System.Drawing.Color]::White
$InputFill = [System.Drawing.ColorTranslator]::FromHtml('#FFF2CC')    # owner fills these
$DerivedFill = [System.Drawing.ColorTranslator]::FromHtml('#F2F2F2')  # our draft
$Stamp = (Get-Date -Format 'yyyy-MM-dd HH:mm')

# ------------------------------------------------------------------ helpers --
function Get-Layer([string]$Type) {
    switch -Regex ($Type.ToLower()) {
        '^microsoft\.compute/|^microsoft\.sqlvirtualmachine/' { return 'Compute' }
        '^microsoft\.storage/' { return 'Storage' }
        '^microsoft\.network/' { return 'Network' }
        '^microsoft\.(sql|dbforpostgresql|dbformysql)/' { return 'Database' }
        '^microsoft\.desktopvirtualization/' { return 'AVD' }
        '^microsoft\.(operationalinsights|insights|automation|recoveryservices|keyvault)/' { return 'Monitoring & Vault' }
        default { return 'PaaS' }
    }
}
function Test-InScope([string]$Type) {
    $t = $Type.ToLower()
    if ($t -like '*/extensions' -or $t -like '*virtualclusters*') { return $false }
    foreach ($p in $ScopePrefixes) { if ($t.StartsWith($p)) { return $true } }
    $false
}
function Get-ProposedEnvironment([string]$SubscriptionKey, [string]$ResourceGroup) {
    $n = $ResourceGroup.ToLower()
    if ($SubscriptionKey -eq 'core') { return @('Core', 'core / platform subscription') }
    if ($n -match '-dr-|-dr$|-asr$') { return @('DR', 'disaster recovery token in name') }
    if ($n -match '-uat-|-uat$') { return @('UAT', 'UAT token in name') }
    if ($n -match '-dev-|-dev$') { return @('Development', 'dev token in name') }
    if ($n -match '-test-|-test$') { return @('Test', 'test token in name') }
    if ($SubscriptionKey -eq 'prod') { return @('Production', 'production subscription default') }
    @('NonProduction', 'non-production subscription default')
}
function Get-ApplicationGroup([string]$ResourceGroup) {
    if ($ResourceGroup -match $PlatformRgPattern) { return 'platform-generated' }
    if ($ResourceGroup -match $RestoreTestPattern) { return 'restore-test' }
    foreach ($k in $AllRules.Keys) { if ($ResourceGroup -match $k) { return $AllRules[$k] } }
    'other'
}
function Get-DraftCriticality([string]$Environment, [string]$ApplicationGroup) {
    if ($ApplicationGroup -eq 'platform-generated') { return @('No', 'service-created resource group, carries no business service') }
    if ($ApplicationGroup -eq 'restore-test') { return @('No', 'restore and failover test environment; it exists to be rebuilt') }
    if ($Environment -in 'Production', 'DR') {
        if ($ApplicationGroup -in $CriticalApplicationGroup) { return @('Yes', 'production business workload; an outage is visible to the business') }
        if ($ApplicationGroup -in $CriticalPlatformGroup) { return @('Yes', 'every other production service depends on it, or it is the recovery path itself') }
        return @('No', 'production supporting workload; an outage is disruptive but no business service stops')
    }
    if ($Environment -eq 'Core') {
        if ($ApplicationGroup -in $CriticalPlatformGroup) { return @('Yes', 'shared platform service every workload depends on, or the recovery path itself') }
        return @('No', 'shared platform component; operations are affected, business services keep running')
    }
    @('No', 'non-production environment')
}
function Get-VmCriticality([string]$Environment, [string]$RgCriticality, [string]$Backup, [string]$Replication, [string]$VmName, [string]$ResourceGroup) {
    if ($VmName -match $SessionHostNamePattern) { return @('No', 'pooled session host, rebuilt from the image', '') }
    if ($ResourceGroup -match $RestoreTestPattern) { return @('No', 'restore and failover test machine; the replication is part of the test', '') }
    $value = $RgCriticality; $why = 'inherited from the resource group'; $flag = ''
    if ($Environment -in 'Production', 'DR') {
        if ($Replication -eq 'Yes') { $value = 'Yes'; $why = 'already replicated by Site Recovery, so the platform treats it as critical' }
        elseif ($Backup -eq 'Yes') { $why = 'protected by Azure Backup; criticality follows the application' }
        else { $flag = 'Production or DR virtual machine with no backup declared'; $why = 'no backup declared on the machine; resource group answer applied' }
    }
    @($value, $why, $flag)
}
function Format-Sheet($Worksheet, [int]$Columns, [int]$Rows, [int[]]$InputColumns = @(), [int[]]$DerivedColumns = @()) {
    $Worksheet.Cells.Style.Font.Name = 'Arial'
    $Worksheet.Cells.Style.Font.Size = 10
    $last = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($Columns)
    Set-ExcelRange -Worksheet $Worksheet -Range "A1:${last}1" -BackgroundColor $Navy -FontColor $White -Bold -VerticalAlignment Center
    $Worksheet.Row(1).Height = 30
    $Worksheet.View.FreezePanes(2, 1)
    if ($Rows -gt 1) {
        foreach ($c in $DerivedColumns) { $l = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($c); Set-ExcelRange -Worksheet $Worksheet -Range "${l}2:${l}${Rows}" -BackgroundColor $DerivedFill }
        foreach ($c in $InputColumns) { $l = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($c); Set-ExcelRange -Worksheet $Worksheet -Range "${l}2:${l}${Rows}" -BackgroundColor $InputFill }
    }
}
function Add-Dropdown($Worksheet, [int]$Column, [int]$Rows, [string[]]$Values, [string]$Title) {
    if ($Rows -lt 2) { return }
    $l = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($Column)
    Add-ExcelDataValidationRule -Worksheet $Worksheet -Range "${l}2:${l}${Rows}" -ValidationType List -ValueSet $Values `
        -ShowErrorMessage -ErrorStyle stop -ErrorTitle 'Invalid value' -ErrorBody "$Title must be one of: $($Values -join ', ')"
}
function Write-TextSheet($Worksheet, [object[]]$Lines) {
    $Worksheet.Cells.Style.Font.Name = 'Arial'
    $r = 1
    foreach ($line in $Lines) {
        $Worksheet.Cells[$r, 1].Value = $line.Text
        switch ($line.Style) {
            'title' { $Worksheet.Cells[$r, 1].Style.Font.Size = 16; $Worksheet.Cells[$r, 1].Style.Font.Bold = $true; $Worksheet.Cells[$r, 1].Style.Font.Color.SetColor($Navy) }
            'heading' { $Worksheet.Cells[$r, 1].Style.Font.Size = 12; $Worksheet.Cells[$r, 1].Style.Font.Bold = $true; $Worksheet.Cells[$r, 1].Style.Font.Color.SetColor($Navy) }
            'bold' { $Worksheet.Cells[$r, 1].Style.Font.Bold = $true }
        }
        $r++
    }
    $Worksheet.Column(1).Width = 125
    $Worksheet.Cells.Style.VerticalAlignment = 'Top'
}

# -------------------------------------------------------------- collect data --
Write-Host 'Querying Azure Resource Graph (read-only)...' -ForegroundColor Cyan
$DataPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))) 'tagging-data'
New-Item -ItemType Directory -Force -Path $DataPath | Out-Null

$rgQuery = "resourcecontainers | where type == 'microsoft.resources/subscriptions/resourcegroups' | project subscriptionId, name, location"
$resQuery = 'resources | project subscriptionId, resourceGroup, type, name, location'
$vmQuery = ("resources | where type =~ 'microsoft.compute/virtualmachines' | project subscriptionId, resourceGroup, name, location, " +
    "vmSize = tostring(properties.hardwareProfile.vmSize), osType = tostring(properties.storageProfile.osDisk.osType), " +
    "backup = tostring(tags['{0}']), backupPolicy = tostring(tags['{1}']), repl = tostring(tags['{2}']), maint = tostring(tags['{3}'])") -f $BackupTag, $BackupPolicyTag, $ReplicationTag, $MaintenanceTag
$tagQuery = ("resources | extend e = tostring(tags['{0}']), c = tostring(tags['{1}']) " +
    "| summarize total = count(), withEnv = sum(iff(isnotempty(e), 1, 0)), withCrit = sum(iff(isnotempty(c), 1, 0)) by subscriptionId") -f $EnvironmentTag, $CriticalityTag

$rgRows = @(Search-Graph -Query $rgQuery -Subscription $SubIds)
$resRows = @(Search-Graph -Query $resQuery -Subscription $SubIds)
$vmRows = @(Search-Graph -Query $vmQuery -Subscription $SubIds | Sort-Object name)
$tagRows = @(Search-Graph -Query $tagQuery -Subscription $SubIds)
if (-not $rgRows.Count -or -not $resRows.Count) { throw "Resource Graph returned $($rgRows.Count) resource groups and $($resRows.Count) resources. Check the subscriptions and your Reader access." }

$rgRows | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $DataPath 'resourcegroups.json') -Encoding utf8
$resRows | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $DataPath 'resources.json') -Encoding utf8
$vmRows | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $DataPath 'virtualmachines.json') -Encoding utf8
Write-Host ('  resource groups {0}, resources {1}, virtual machines {2}' -f $rgRows.Count, $resRows.Count, $vmRows.Count)

# ------------------------------------------------------------------- derive --
$scopeRows = @($resRows | Where-Object { Test-InScope $_.type })
$scopeByRg = @{}
foreach ($r in $scopeRows) {
    $key = '{0}|{1}' -f $r.subscriptionId, $r.resourceGroup.ToLower()
    if (-not $scopeByRg.ContainsKey($key)) { $scopeByRg[$key] = [System.Collections.Generic.List[object]]::new() }
    $scopeByRg[$key].Add($r)
}

$rgIndex = @{}
$rgSheet = @(foreach ($rg in ($rgRows | Sort-Object @{ Expression = { $SubKey[$_.subscriptionId] } }, name)) {
    $subKeyV = $SubKey[$rg.subscriptionId]
    $envPair = Get-ProposedEnvironment $subKeyV $rg.name
    $app = Get-ApplicationGroup $rg.name
    $crPair = Get-DraftCriticality $envPair[0] $app
    $key = '{0}|{1}' -f $rg.subscriptionId, $rg.name.ToLower()
    $items = if ($scopeByRg.ContainsKey($key)) { @($scopeByRg[$key]) } else { @() }
    $layers = (($items | ForEach-Object { Get-Layer $_.type } | Sort-Object -Unique) -join ', ')
    $n = $rg.name.ToLower()
    $review = if ($rg.name -match $PlatformRgPattern) { 'PLATFORM-GENERATED' }
              elseif ($subKeyV -ne 'core' -and $n -match '-core-') { 'CORE NAME IN {0} SUBSCRIPTION' -f $subKeyV.ToUpper() }
              elseif ($subKeyV -eq 'nonprod' -and $n -match '-dr-|-asr$') { 'DR RESOURCE GROUP IN NONPROD SUBSCRIPTION' }
              elseif ($n -notmatch '-(prod|nonprod|core|dr|uat|dev|test)(-|$)') { 'NO ENVIRONMENT TOKEN IN NAME' }
              else { '' }
    $rgIndex[$key] = [pscustomobject]@{ Environment = $envPair[0]; Criticality = $crPair[0]; Application = $app }
    [pscustomobject][ordered]@{
        'Subscription' = $SubName[$rg.subscriptionId]; 'Resource group' = $rg.name; 'Location' = $rg.location
        'In-scope resources' = $items.Count; 'Layers' = $layers; 'Application group' = $app
        'Proposed Environment' = $envPair[0]; 'Draft Criticality' = $crPair[0]; 'Why (Environment)' = $envPair[1]; 'Why (Criticality)' = $crPair[1]
        'Review' = $review; 'Confirmed Environment' = ''; 'Agree with Criticality?' = ''; 'If not, Criticality' = ''; 'Application owner' = ''; 'Notes' = ''
    }
})

$vmFlags = [System.Collections.Generic.List[object]]::new()
$vmSheet = @(foreach ($vm in $vmRows) {
    $envPair = Get-ProposedEnvironment $SubKey[$vm.subscriptionId] $vm.resourceGroup
    $rgInfo = $rgIndex['{0}|{1}' -f $vm.subscriptionId, $vm.resourceGroup.ToLower()]
    $rgCrit = if ($rgInfo) { $rgInfo.Criticality } else { 'No' }
    $trio = Get-VmCriticality $envPair[0] $rgCrit $vm.backup $vm.repl $vm.name $vm.resourceGroup
    if ($trio[2]) {
        $vmFlags.Add([pscustomobject][ordered]@{ 'Virtual machine' = $vm.name; 'Subscription' = $SubName[$vm.subscriptionId]; 'Resource group' = $vm.resourceGroup; 'Environment' = $envPair[0]; 'Finding' = $trio[2] })
    }
    [pscustomobject][ordered]@{
        'Virtual machine' = $vm.name; 'Subscription' = $SubName[$vm.subscriptionId]; 'Resource group' = $vm.resourceGroup; 'Location' = $vm.location
        'Size' = $vm.vmSize; 'OS' = $vm.osType; $BackupTag = $vm.backup; $BackupPolicyTag = $vm.backupPolicy; $ReplicationTag = $vm.repl; $MaintenanceTag = $vm.maint
        'Proposed Environment' = $envPair[0]; 'Draft Criticality' = $trio[0]; 'Why (Criticality)' = $trio[1]; 'Flag' = $trio[2]
        'Confirmed Environment' = ''; 'Agree with Criticality?' = ''; 'If not, Criticality' = ''; 'Application owner' = ''; 'Notes' = ''
    }
})

$resSheet = @(foreach ($r in ($scopeRows | Sort-Object @{ Expression = { $SubKey[$_.subscriptionId] } }, resourceGroup, type, name)) {
    $rgInfo = $rgIndex['{0}|{1}' -f $r.subscriptionId, $r.resourceGroup.ToLower()]
    [pscustomobject][ordered]@{
        'Subscription' = $SubName[$r.subscriptionId]; 'Resource group' = $r.resourceGroup; 'Layer' = Get-Layer $r.type; 'Resource type' = $r.type
        'Resource name' = $r.name; 'Location' = $r.location
        'Proposed Environment' = $(if ($rgInfo) { $rgInfo.Environment } else { '' }); 'Draft Criticality' = $(if ($rgInfo) { $rgInfo.Criticality } else { '' })
        'Exception?' = ''; 'Confirmed Environment' = ''; 'Agree with Criticality?' = ''; 'If not, Criticality' = ''; 'Notes' = ''
    }
})

$reviewSheet = @(foreach ($row in ($rgSheet | Where-Object { $_.Review })) {
    $question = switch -Regex ($row.Review) {
        'PLATFORM' { 'Service-created resource group. Tag it as well, or leave it out of the classification scope?' }
        'CORE NAME' { 'The name says core but the resource group lives in another subscription. Which one is right?' }
        'DR RESOURCE' { 'Is this the disaster recovery copy of a production service, or a non-production DR test?' }
        default { 'The name carries no environment token. Which environment does this resource group belong to?' }
    }
    [pscustomobject][ordered]@{
        'Subscription' = $row.'Subscription'; 'Resource group' = $row.'Resource group'; 'In-scope resources' = $row.'In-scope resources'
        'Reason for review' = $row.Review; 'Our proposal' = '{0} / {1}' -f $row.'Proposed Environment', $row.'Draft Criticality'; 'Question' = $question
        'Confirmed Environment' = ''; 'Agree with Criticality?' = ''; 'If not, Criticality' = ''; 'Notes' = ''
    }
})

$appAgg = @{}
foreach ($row in $rgSheet) {
    $k = '{0}|{1}' -f $row.'Application group', $row.'Proposed Environment'
    if (-not $appAgg.ContainsKey($k)) { $appAgg[$k] = [pscustomobject]@{ App = $row.'Application group'; Env = $row.'Proposed Environment'; Rgs = 0; Resources = 0; Vms = 0; Backup = 0; Repl = 0 } }
    $appAgg[$k].Rgs++
    $appAgg[$k].Resources += $row.'In-scope resources'
}
foreach ($vm in $vmSheet) {
    $k = '{0}|{1}' -f (Get-ApplicationGroup $vm.'Resource group'), $vm.'Proposed Environment'
    if ($appAgg.ContainsKey($k)) {
        $appAgg[$k].Vms++
        if ($vm.$BackupTag -eq 'Yes') { $appAgg[$k].Backup++ }
        if ($vm.$ReplicationTag -eq 'Yes') { $appAgg[$k].Repl++ }
    }
}
$appSheet = @(foreach ($a in ($appAgg.Values | Sort-Object App, Env)) {
    $draft = Get-DraftCriticality $a.Env $a.App
    [pscustomobject][ordered]@{
        'Application group' = $a.App; 'Environment' = $a.Env; 'Resource groups' = $a.Rgs; 'In-scope resources' = $a.Resources
        'Virtual machines' = $a.Vms; 'VMs with backup' = $a.Backup; 'VMs with replication' = $a.Repl
        'Draft Criticality' = $draft[0]; 'Why (draft)' = $draft[1]
        'Agree with Criticality?' = ''; 'If not, Criticality' = ''; 'Business owner' = ''; 'Notes' = ''
    }
})

# -------------------------------------------------------------- summary data --
$currentState = @(foreach ($t in ($tagRows | Sort-Object @{ Expression = { $SubName[$_.subscriptionId] } })) {
    [pscustomobject][ordered]@{
        'Subscription' = $SubName[$t.subscriptionId]; 'Resources' = $t.total
        "With $EnvironmentTag tag" = $t.withEnv; "With $CriticalityTag tag" = $t.withCrit
        'In-scope resources' = @($scopeRows | Where-Object { $_.subscriptionId -eq $t.subscriptionId }).Count
        'Resource groups' = @($rgRows | Where-Object { $_.subscriptionId -eq $t.subscriptionId }).Count
    }
})
$layerSummary = @($scopeRows | Group-Object { Get-Layer $_.type } | Sort-Object Count -Descending | ForEach-Object {
    $types = @($_.Group | Select-Object -ExpandProperty type -Unique)
    [pscustomobject][ordered]@{ 'Layer' = $_.Name; 'Resources' = $_.Count; 'Resource types' = $types.Count; 'Examples' = (($types | Select-Object -First 4) -join ', ') }
})
$envSummary = @($rgSheet | Group-Object 'Proposed Environment' | Sort-Object Count -Descending | ForEach-Object {
    [pscustomobject][ordered]@{ 'Proposed Environment' = $_.Name; 'Resource groups' = $_.Count; 'In-scope resources' = ($_.Group | Measure-Object 'In-scope resources' -Sum).Sum }
})
$critSummary = @($rgSheet | Group-Object 'Draft Criticality' | Sort-Object Count -Descending | ForEach-Object {
    [pscustomobject][ordered]@{ 'Draft Criticality' = $_.Name; 'Resource groups' = $_.Count; 'In-scope resources' = ($_.Group | Measure-Object 'In-scope resources' -Sum).Sum }
})

$tagStandard = @(
    [pscustomobject][ordered]@{ Tag = $EnvironmentTag; Value = 'Production'; Meaning = 'Live service used by the business.'; Drives = 'Strictest change control, production backup policy, production maintenance window, highest monitoring priority.' }
    [pscustomobject][ordered]@{ Tag = $EnvironmentTag; Value = 'NonProduction'; Meaning = 'Integration and pre-release work that is not user acceptance.'; Drives = 'Relaxed change control, shorter backup retention, unattended patching.' }
    [pscustomobject][ordered]@{ Tag = $EnvironmentTag; Value = 'Development'; Meaning = 'Developer-owned environment.'; Drives = 'Lowest retention; separates development cost from delivery environments.' }
    [pscustomobject][ordered]@{ Tag = $EnvironmentTag; Value = 'Test'; Meaning = 'System and regression test environment.'; Drives = 'As development, plus scheduled refresh windows.' }
    [pscustomobject][ordered]@{ Tag = $EnvironmentTag; Value = 'UAT'; Meaning = 'Business acceptance environment.'; Drives = 'Change freeze during acceptance windows; backup kept for the test cycle.' }
    [pscustomobject][ordered]@{ Tag = $EnvironmentTag; Value = 'DR'; Meaning = 'Disaster recovery copy of another environment.'; Drives = 'Replication health monitoring, failover test scheduling, excluded from normal patch waves.' }
    [pscustomobject][ordered]@{ Tag = $EnvironmentTag; Value = 'Core'; Meaning = 'Shared platform service: identity, network, security, monitoring, backup, AVD.'; Drives = 'Platform change control; separates platform cost from workload cost.' }
    [pscustomobject][ordered]@{ Tag = $CriticalityTag; Value = 'Yes'; Meaning = 'Business critical. Losing this resource stops or materially degrades a business service, or breaks a platform service every other service depends on.'; Drives = 'Backup and replication required, priority incident response, strictest maintenance windows.' }
    [pscustomobject][ordered]@{ Tag = $CriticalityTag; Value = 'No'; Meaning = 'Not business critical. An outage is disruptive or delays delivery, but no business service stops and no irreplaceable data is lost.'; Drives = 'Standard backup and patching, best-effort response.' }
)
$critGuidance = @(
    [pscustomobject][ordered]@{ Rule = "Production or DR: business application groups ($(if ($CriticalApplicationGroup) { $CriticalApplicationGroup -join ', ' } else { 'none set: pass -CriticalApplicationGroup' }))"; Draft = 'Yes'; Reasoning = 'A business workload the users see when it is down.' }
    [pscustomobject][ordered]@{ Rule = "Production, DR or Core: platform groups ($($CriticalPlatformGroup -join ', '))"; Draft = 'Yes'; Reasoning = 'Every other service depends on it, or it is the recovery path itself.' }
    [pscustomobject][ordered]@{ Rule = 'Production or DR: everything else'; Draft = 'No'; Reasoning = 'An outage is disruptive, but no business service stops. This is the line to challenge first.' }
    [pscustomobject][ordered]@{ Rule = 'Core: everything else (management, monitoring, AVD, integration)'; Draft = 'No'; Reasoning = 'Operations and end-user tooling are affected, business services keep running.' }
    [pscustomobject][ordered]@{ Rule = 'Any virtual machine already replicated by Site Recovery'; Draft = 'Yes'; Reasoning = 'The platform already pays to keep it alive across regions, so we read that as critical.' }
    [pscustomobject][ordered]@{ Rule = 'Restore and failover test environment'; Draft = 'No'; Reasoning = 'It exists to be rebuilt; the backup and replication on it are the test itself.' }
    [pscustomobject][ordered]@{ Rule = 'Pooled session hosts'; Draft = 'No'; Reasoning = 'Rebuilt from the image; user data lives in profile containers.' }
    [pscustomobject][ordered]@{ Rule = 'NonProduction, UAT, Development, Test'; Draft = 'No'; Reasoning = 'Delivery impact only, no customer impact.' }
    [pscustomobject][ordered]@{ Rule = 'Service-created resource groups'; Draft = 'No'; Reasoning = 'No business service; candidates for exclusion from scope altogether.' }
)

# ---------------------------------------------------------------- build book --
# Export-Excel with an empty collection would hand back no package, so empty sheets are skipped (and noted).
foreach ($e in @(@('Virtual Machines', $vmSheet), @('In-Scope Resources', $resSheet), @('Review Items', $reviewSheet))) { if (-not $e[1].Count) { Write-Warning "Sheet '$($e[0])' has no rows and is left out." } }
if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }
Write-Host 'Writing workbook...' -ForegroundColor Cyan
$xl = $appSheet | Export-Excel -Path $OutputPath -WorksheetName 'Application Criticality' -AutoSize -AutoFilter -PassThru
$xl = $rgSheet | Export-Excel -ExcelPackage $xl -WorksheetName 'Resource Groups' -AutoSize -AutoFilter -PassThru
if ($vmSheet.Count) { $xl = $vmSheet | Export-Excel -ExcelPackage $xl -WorksheetName 'Virtual Machines' -AutoSize -AutoFilter -PassThru }
if ($resSheet.Count) { $xl = $resSheet | Export-Excel -ExcelPackage $xl -WorksheetName 'In-Scope Resources' -AutoSize -AutoFilter -PassThru }
if ($reviewSheet.Count) { $xl = $reviewSheet | Export-Excel -ExcelPackage $xl -WorksheetName 'Review Items' -AutoSize -AutoFilter -PassThru }
$xl = $tagStandard | Export-Excel -ExcelPackage $xl -WorksheetName 'Tag Standard' -AutoSize -PassThru

$xl = $currentState | Export-Excel -ExcelPackage $xl -WorksheetName 'Current State' -StartRow 3 -AutoSize -PassThru
$ws = $xl.Workbook.Worksheets['Current State']
$ws.Cells[1, 1].Value = "Current state of $EnvironmentTag and $CriticalityTag tagging"
$ws.Cells[2, 1].Value = "Azure Resource Graph snapshot taken $Stamp"
$startLayer = [int](3 + $currentState.Count + 3)
if ($layerSummary.Count) { $xl = $layerSummary | Export-Excel -ExcelPackage $xl -WorksheetName 'Current State' -StartRow $startLayer -AutoSize -PassThru }
$ws.Cells[($startLayer - 1), 1].Value = 'In-scope resources by layer'
$startEnv = [int]($startLayer + $layerSummary.Count + 3)
$xl = $envSummary | Export-Excel -ExcelPackage $xl -WorksheetName 'Current State' -StartRow $startEnv -AutoSize -PassThru
$ws.Cells[($startEnv - 1), 1].Value = 'Proposed Environment distribution, resource group level'
$startCrit = [int]($startEnv + $envSummary.Count + 3)
$xl = $critSummary | Export-Excel -ExcelPackage $xl -WorksheetName 'Current State' -StartRow $startCrit -AutoSize -PassThru
$ws.Cells[($startCrit - 1), 1].Value = 'Draft Criticality distribution, resource group level (for discussion, not a decision)'

$xl = $critGuidance | Export-Excel -ExcelPackage $xl -WorksheetName 'Criticality Guidance' -StartRow 2 -AutoSize -PassThru
$wsG = $xl.Workbook.Worksheets['Criticality Guidance']
$wsG.Cells[1, 1].Value = 'How the draft Criticality was derived'
$gapStart = [int](2 + $critGuidance.Count + 3)
if ($vmFlags.Count) {
    $xl = $vmFlags | Export-Excel -ExcelPackage $xl -WorksheetName 'Criticality Guidance' -StartRow $gapStart -AutoSize -PassThru
    $wsG.Cells[($gapStart - 1), 1].Value = 'Production and DR virtual machines with no backup declared: please confirm intent'
}

$wsOverview = Add-Worksheet -ExcelPackage $xl -WorksheetName 'Overview' -MoveToStart
$wsNext = Add-Worksheet -ExcelPackage $xl -WorksheetName 'Next Steps' -MoveToEnd
Write-TextSheet $wsOverview @(
    @{ Text = "Azure resource classification: $EnvironmentTag and $CriticalityTag"; Style = 'title' }
    @{ Text = "Prepared for $OrganizationName. Azure Resource Graph snapshot $Stamp." }
    @{ Text = '' }
    @{ Text = 'Why this workbook exists'; Style = 'heading' }
    @{ Text = "Two classification tags are wanted on every resource: $EnvironmentTag says which lifecycle stage it belongs to," }
    @{ Text = "$CriticalityTag says what the business loses if it fails. Without them every backup, patching, recovery and cost decision" }
    @{ Text = 'has to be looked up machine by machine instead of queried.' }
    @{ Text = '' }
    @{ Text = 'What has been prepared'; Style = 'heading' }
    @{ Text = "$EnvironmentTag is derived from the subscription and the resource group naming convention, so it needs confirmation rather than data entry." }
    @{ Text = "$CriticalityTag is a business judgement, answered Yes or No. Yes means losing the resource stops or materially degrades a business" }
    @{ Text = 'service, or breaks a platform service every other service depends on. No means the outage is disruptive but nothing business-facing stops.' }
    @{ Text = 'Every row carries a proposal built from Azure Backup coverage, Site Recovery replication, environment and application grouping.' }
    @{ Text = 'The rule behind each answer is on the Criticality Guidance sheet.' }
    @{ Text = '' }
    @{ Text = 'How to answer'; Style = 'heading' }
    @{ Text = 'Agree with Criticality? is Yes or No. If No, put the value you want in If not, Criticality. Where the proposal is right, one Yes is enough.' }
    @{ Text = '1. Application Criticality: one row per application and environment; the answer covers every resource underneath it.' }
    @{ Text = '2. Review Items: open questions where the naming convention gives no clear environment.' }
    @{ Text = '3. Resource Groups, 4. Virtual Machines, 5. In-Scope Resources: exceptions only.' }
    @{ Text = '' }
    @{ Text = 'Colour legend'; Style = 'heading' }
    @{ Text = 'Grey columns: the proposal, generated from live Azure data. Yellow columns: your decision, with drop-down lists.' }
    @{ Text = '' }
    @{ Text = 'Scope'; Style = 'heading' }
    @{ Text = 'Compute, storage, network, PaaS, database and monitoring resources. Objects the platform creates and manages for you (extensions,' }
    @{ Text = 'restore points, flow logs, alert rules) are out of scope: their tags add no value and drift as the services recreate them.' }
    @{ Text = '' }
    @{ Text = 'No Azure resource has been changed. This workbook is read-only analysis.'; Style = 'bold' }
)
Write-TextSheet $wsNext @(
    @{ Text = 'What happens once this workbook comes back'; Style = 'title' }
    @{ Text = '' }
    @{ Text = 'Step 1: resource group tags'; Style = 'heading' }
    @{ Text = 'The confirmed values are written onto the resource groups. Existing tags are merged, never overwritten.' }
    @{ Text = '' }
    @{ Text = 'Step 2: inheritance to the resources'; Style = 'heading' }
    @{ Text = 'Two Azure Policy assignments (Inherit a tag from the resource group if missing) fill the tags on the resources, followed by a' }
    @{ Text = 'remediation task for what already exists. The policy only fills a missing tag: it never blocks a deployment or changes a value.' }
    @{ Text = '' }
    @{ Text = 'Step 3: exceptions'; Style = 'heading' }
    @{ Text = 'Resources marked as exceptions are tagged individually.' }
    @{ Text = '' }
    @{ Text = 'Step 4: visibility'; Style = 'heading' }
    @{ Text = 'Audit policies report any resource whose tag is missing or outside the agreed values. Cost can then be grouped by both tags.' }
    @{ Text = '' }
    @{ Text = 'Not part of this phase'; Style = 'heading' }
    @{ Text = 'No Deny policy. If enforcement is wanted later it should cover only resource types people create directly: a Deny on disks or' }
    @{ Text = 'network interfaces breaks Azure Backup restore and Site Recovery failover, which create untagged resources on your behalf.' }
)

# ------------------------------------------------------------------ styling --
$fmt = @(
    @{ Name = 'Application Criticality'; Cols = 13; Rows = ($appSheet.Count + 1); Derived = @(8, 9); Inputs = @(10, 11, 12, 13); AgreeCol = 10; CritCol = 11; EnvCol = 0 }
    @{ Name = 'Resource Groups'; Cols = 16; Rows = ($rgSheet.Count + 1); Derived = @(7, 8, 9, 10, 11); Inputs = @(12, 13, 14, 15, 16); AgreeCol = 13; CritCol = 14; EnvCol = 12 }
    @{ Name = 'Virtual Machines'; Cols = 19; Rows = ($vmSheet.Count + 1); Derived = @(11, 12, 13, 14); Inputs = @(15, 16, 17, 18, 19); AgreeCol = 16; CritCol = 17; EnvCol = 15 }
    @{ Name = 'In-Scope Resources'; Cols = 13; Rows = ($resSheet.Count + 1); Derived = @(7, 8); Inputs = @(9, 10, 11, 12, 13); AgreeCol = 11; CritCol = 12; EnvCol = 10 }
    @{ Name = 'Review Items'; Cols = 10; Rows = ($reviewSheet.Count + 1); Derived = @(4, 5, 6); Inputs = @(7, 8, 9, 10); AgreeCol = 8; CritCol = 9; EnvCol = 7 }
    @{ Name = 'Tag Standard'; Cols = 4; Rows = ($tagStandard.Count + 1); Derived = @(); Inputs = @(); AgreeCol = 0; CritCol = 0; EnvCol = 0 }
)
foreach ($f in $fmt) {
    $w = $xl.Workbook.Worksheets[$f.Name]
    if (-not $w) { continue }   # Export-Excel creates no sheet for an empty collection (for example no review items)
    Format-Sheet $w $f.Cols $f.Rows $f.Inputs $f.Derived
    if ($f.EnvCol) { Add-Dropdown $w $f.EnvCol $f.Rows $EnvironmentValues 'Environment' }
    if ($f.AgreeCol) { Add-Dropdown $w $f.AgreeCol $f.Rows $YesNo 'Agree with Criticality?' }
    if ($f.CritCol) { Add-Dropdown $w $f.CritCol $f.Rows $CriticalityValues 'Criticality' }
    foreach ($c in 1..$f.Cols) { if ($w.Column($c).Width -gt 50) { $w.Column($c).Width = 50 } }
    $w.Cells["A1:$([OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($f.Cols))1"].Style.WrapText = $true
}
foreach ($name in 'Current State', 'Criticality Guidance') {
    $w = $xl.Workbook.Worksheets[$name]
    $w.Cells.Style.Font.Name = 'Arial'; $w.Cells.Style.Font.Size = 10
    $w.Cells[1, 1].Style.Font.Size = 14; $w.Cells[1, 1].Style.Font.Bold = $true; $w.Cells[1, 1].Style.Font.Color.SetColor($Navy)
}
$stacked = @(
    @{ Sheet = 'Current State'; Row = 3; Cols = 6 }
    @{ Sheet = 'Current State'; Row = $startLayer; Cols = 4 }
    @{ Sheet = 'Current State'; Row = $startEnv; Cols = 3 }
    @{ Sheet = 'Current State'; Row = $startCrit; Cols = 3 }
    @{ Sheet = 'Criticality Guidance'; Row = 2; Cols = 3 }
)
if ($vmFlags.Count) { $stacked += @{ Sheet = 'Criticality Guidance'; Row = $gapStart; Cols = 5 } }
foreach ($s in $stacked) {
    $w = $xl.Workbook.Worksheets[$s.Sheet]
    $l = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($s.Cols)
    Set-ExcelRange -Worksheet $w -Range "A$($s.Row):$l$($s.Row)" -BackgroundColor $Navy -FontColor $White -Bold
    if ($s.Row -gt 1) { $w.Cells[($s.Row - 1), 1].Style.Font.Bold = $true; $w.Cells[($s.Row - 1), 1].Style.Font.Color.SetColor($Navy) }
}
$wsT = $xl.Workbook.Worksheets['Tag Standard']
$wsT.Cells.Style.WrapText = $true
$wsT.Column(1).Width = 14; $wsT.Column(2).Width = 16; $wsT.Column(3).Width = 55; $wsT.Column(4).Width = 75

$xl.Workbook.Properties.Title = "Azure resource classification: $EnvironmentTag and $CriticalityTag"
$xl.Workbook.Properties.Company = $OrganizationName
Close-ExcelPackage $xl

Write-Host "`nWorkbook written: $OutputPath" -ForegroundColor Green
Write-Host ('  Resource Groups    : {0} rows, {1} flagged for review' -f $rgSheet.Count, $reviewSheet.Count)
Write-Host ('  Virtual Machines   : {0} rows, {1} protection-gap flags' -f $vmSheet.Count, $vmFlags.Count)
Write-Host ('  In-Scope Resources : {0} rows' -f $resSheet.Count)
Write-Host "  Raw data           : $DataPath"
