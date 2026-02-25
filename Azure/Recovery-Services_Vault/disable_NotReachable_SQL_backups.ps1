Set-AzContext -Subscription "subs-customer-prod"
$subId = (Get-AzContext).Subscription.Id
az account set --subscription $subId

# -------- CONFIG --------
$vaultName = "rsv-customer-prod-backup-gw"
$rgName = "rg-customer-management-prod-gw"
$askConfirmation = $true   # false yaparsan direkt disable eder

# -------- VAULT --------
$vault = Get-AzRecoveryServicesVault -Name $vaultName -ResourceGroupName $rgName
Set-AzRecoveryServicesVaultContext -Vault $vault

Write-Host "SQL backup item'ları çekiliyor..." -ForegroundColor Cyan

$candidates = @()

# -------- SQL CONTAINERS --------
$containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer

foreach ($container in $containers) {

    $items = Get-AzRecoveryServicesBackupItem `
        -Container $container `
        -WorkloadType MSSQL

    foreach ($item in $items) {

        # sadece NotReachable + hala Protected olanlar
        if (
            $item.ProtectedItemHealthStatus -eq "NotReachable" -and
            $item.ProtectionState -eq "Protected"
        ) {
            $candidates += [PSCustomObject]@{
                VMName                    = $container.FriendlyName
                SQLInstance               = $item.ServerName
                DatabaseName              = $item.Name
                ContainerName             = $container.Name
                ProtectedItemHealthStatus = $item.ProtectedItemHealthStatus
                ProtectionState           = $item.ProtectionState
                LastBackupStatus          = $item.LastBackupStatus
                LastBackupTime            = $item.LastBackupTime
            }
        }
    }
}

# -------- SONUÇ --------
Write-Host "`n===== DISABLE EDİLECEK NOTREACHABLE SQL BACKUP'LAR =====" -ForegroundColor Yellow
$candidates | Format-Table VMName,SQLInstance,DatabaseName,ProtectedItemHealthStatus,ProtectionState,LastBackupTime -AutoSize

Write-Host "`nToplam: $($candidates.Count) adet" -ForegroundColor Cyan

if ($candidates.Count -eq 0) {
    Write-Host "Disable edilecek backup yok." -ForegroundColor Green
    return
}

# -------- AZ CLI LOGIN --------
az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    az login
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

    Write-Host "Disabling -> $($item.ContainerName) / $($item.DatabaseName)" -ForegroundColor Yellow

    az backup protection disable `
      --resource-group $rgName `
      --vault-name $vaultName `
      --container-name $item.ContainerName `
      --item-name $item.DatabaseName `
      --backup-management-type AzureWorkload `
      --workload-type MSSQL `
      --yes
}

Write-Host "`nBitti." -ForegroundColor Green