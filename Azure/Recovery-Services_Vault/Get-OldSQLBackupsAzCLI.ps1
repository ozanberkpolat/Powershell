# -------- CONFIG --------
$vaultName = "rsv-isbankag-prod-backup-gw"
$rgName = "rg-isbankag-management-prod-gw"
$days = 30

$cutoff = (Get-Date).AddDays(-$days)

# Azure CLI login kontrol
az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    az login
}

Write-Host "SQL backup item'ları çekiliyor..." -ForegroundColor Cyan

# SQL workload backup item'ları listele
$itemsJson = az backup item list `
  --resource-group $rgName `
  --vault-name $vaultName `
  --backup-management-type AzureWorkload `
  --workload-type MSSQL `
  --query "[].{name:name, containerName:properties.containerName, lastBackupTime:properties.lastBackupTime, protectionState:properties.protectionState}" `
  -o json

$items = $itemsJson | ConvertFrom-Json

$oldBackups = @()

foreach ($item in $items) {

    if ($item.lastBackupTime) {

        $backupTime = [datetime]$item.lastBackupTime

        if ($backupTime -lt $cutoff) {
            $oldBackups += [PSCustomObject]@{
                DatabaseName    = $item.name
                LastBackupTime  = $backupTime
                ProtectionState = $item.protectionState
                ContainerName   = $item.containerName
            }
        }
    }
}

Write-Host "`n===== 30 GÜNDEN ESKİ SQL BACKUP'LAR =====" -ForegroundColor Yellow
$oldBackups | Sort-Object LastBackupTime | Format-Table -AutoSize

# CSV export istersen:
# $oldBackups | Export-Csv .\30gun-eski-sql-cli.csv -NoTypeInformation