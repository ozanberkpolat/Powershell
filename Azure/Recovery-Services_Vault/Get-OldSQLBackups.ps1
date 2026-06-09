# -------- CONFIG --------
$vaultName = "rsv-isbankag-prod-backup-gw"
$rgName = "rg-isbankag-management-prod-gw"
$days = 30

$cutoffDate = (Get-Date).AddDays(-$days)

# -------- VAULT --------
$vault = Get-AzRecoveryServicesVault -Name $vaultName -ResourceGroupName $rgName
Set-AzRecoveryServicesVaultContext -Vault $vault

$results = @()

# -------- SQL CONTAINERS --------
$containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer

foreach ($container in $containers) {

    $items = Get-AzRecoveryServicesBackupItem `
        -Container $container `
        -WorkloadType MSSQL

    foreach ($item in $items) {

        if ($item.LastBackupTime -and $item.LastBackupTime -lt $cutoffDate) {

            # -------- LISTE --------
            $results += [PSCustomObject]@{
                VMName           = $container.FriendlyName
                DatabaseName     = $item.Name
                LastBackupTime   = $item.LastBackupTime
                LastBackupStatus = $item.LastBackupStatus
                ProtectionState  = $item.ProtectionState
            }

            Write-Host "CANDIDATE -> $($container.FriendlyName) / $($item.Name)" -ForegroundColor Yellow


            # ==========================================================
            # -------- STOP PROTECTION (ÇALIŞAN YOL) --------
            # Stop etmek istediğinde aşağıdaki commentleri kaldır
            # ==========================================================

            Disable-AzRecoveryServicesBackupProtection `
  -Item $item `
  -RetainRecoveryPointsAsPerPolicy `
  -VaultId $vault.ID `
  -Force

        }
    }
}

# -------- SONUÇ TABLO --------
Write-Host "`n===== 30 GÜNDEN ESKİ BACKUP'LAR =====" -ForegroundColor Cyan
$results | Sort-Object LastBackupTime | Format-Table -AutoSize