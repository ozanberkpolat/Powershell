# -------- CONFIG --------
$vaultName = "rsv-customer-prod-backup-gw"
$rgName = "rg-customer-management-prod-gw"
$days = 30
$askConfirmation = $true   # false yaparsan direkt siler

$cutoff = (Get-Date).AddDays(-$days)

# Azure CLI login kontrol
az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    az login
}

Write-Host "SQL backup item'ları çekiliyor..." -ForegroundColor Cyan

# SQL workload backup item'ları çek
$itemsJson = az backup item list `
  --resource-group $rgName `
  --vault-name $vaultName `
  --backup-management-type AzureWorkload `
  --workload-type MSSQL `
  --query "[].{name:name, containerName:properties.containerName, lastBackupTime:properties.lastBackupTime}" `
  -o json

$items = $itemsJson | ConvertFrom-Json

$candidates = @()

foreach ($item in $items) {
    if ($item.lastBackupTime) {
        $backupTime = [datetime]$item.lastBackupTime

        if ($backupTime -lt $cutoff) {
            $candidates += $item
        }
    }
}

# -------- SONUÇ --------
Write-Host "`n===== DISABLE EDİLECEK SQL BACKUP'LAR =====" -ForegroundColor Yellow
$candidates | Select name,lastBackupTime,containerName | Format-Table -AutoSize

Write-Host "`nToplam: $($candidates.Count) adet" -ForegroundColor Cyan

if ($candidates.Count -eq 0) {
    Write-Host "Disable edilecek backup yok." -ForegroundColor Green
    return
}

# -------- CONFIRMATION --------
if ($askConfirmation) {
    $answer = Read-Host "Disable işlemi başlasın mı? (y/n)"
    if ($answer -ne "y") {
        Write-Host "İptal edildi." -ForegroundColor Red
        return
    }
}

# -------- DISABLE --------
foreach ($item in $candidates) {

    Write-Host "Disabling -> $($item.containerName) / $($item.name)" -ForegroundColor Yellow

    az backup protection disable `
      --resource-group $rgName `
      --vault-name $vaultName `
      --container-name $item.containerName `
      --item-name $item.name `
      --backup-management-type AzureWorkload `
      --workload-type MSSQL `
      --yes
}

Write-Host "`nBitti." -ForegroundColor Green