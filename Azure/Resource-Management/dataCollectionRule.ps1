
#---------------------------------------------------
# Parametreler
#---------------------------------------------------
$subscriptionId = "daecf2a9-4ad0-41a5-8d24-be2f3e4ab637"
$resourceGroup = "rg-isbankag-security-core-gw"
$location = "germanywestcentral"
$workspaceResourceId = "/subscriptions/daecf2a9-4ad0-41a5-8d24-be2f3e4ab637/resourcegroups/rg-isbankag-security-core-gw/providers/microsoft.operationalinsights/workspaces/log-isbankag-sentinel-gw"
$vmResourceId = "/subscriptions/d3a1c6d4-b44d-4763-811e-cb2ba1ef7f5b/resourcegroups/rg-isbank-corebank-vm-nonprod-gw/providers/microsoft.compute/virtualmachines/vm-isbankag-corebank-dev-isbazdbd1"
$dcrName = "auditdlogs"
$dcrAssocName = "auditdlogs-association"

# VM Resource ID

#---------------------------------------------------
# Azure Subscription Ayarı
#---------------------------------------------------
az login
az account set --subscription $subscriptionId


az monitor log-analytics workspace table create --resource-group rg-isbankag-security-core-gw --workspace-name log-isbankag-sentinel-gw -n AuditdLogs_CL --retention-time 45 --columns MyColumn1=string TimeGenerated=datetime

#---------------------------------------------------
# 1. DCR Oluştur
#---------------------------------------------------

az monitor data-collection rule create `
  --name $dcrName `
  --resource-group $resourceGroup `
  --location $location `
  --description "Collect auditd logs from audit.log for $vmName" `
  --destinations logAnalytics=law `
  --log-analytics-workspaces law=resource-id=$workspaceResourceId `
  --data-flows streams=$streamName destinations=law


#---------------------------------------------------
# 2. Custom Log Kaynağı Ekle
#---------------------------------------------------
az monitor data-collection rule data-source custom-log add `
  --rule-name $dcrName `
  --resource-group $resourceGroup `
  --name "AuditdLogFile" `
  --file-patterns "/var/log/audit/audit.log" `
  --streams $streamName `
  --record-delimiter "\n"

#---------------------------------------------------
# 3. DCR'yi VM'e Bağla
#---------------------------------------------------
az monitor data-collection rule association create `
  --name $dcrAssocName `
  --resource-group $resourceGroup `
  --rule-name $dcrName `
  --target $vmResourceId
