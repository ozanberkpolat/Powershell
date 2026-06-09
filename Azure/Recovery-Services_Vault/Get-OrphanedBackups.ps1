# Login
Connect-AzAccount

# 1️⃣ Gerçek canlı VM envanteri
$liveVMs = Get-AzVM -Status -ErrorAction SilentlyContinue |
    Where-Object { $_.Name } |
    Select-Object @{n="VmName";e={$_.Name.ToLower()}}

# 2️⃣ Tüm RSV Vault'lar
$vaults = Get-AzRecoveryServicesVault

$protectedVMs = foreach ($vault in $vaults) {

    Set-AzRecoveryServicesVaultContext -Vault $vault

    $subId = (Get-AzContext).Subscription.Id

    Get-AzRecoveryServicesBackupItem `
        -BackupManagementType AzureVM `
        -WorkloadType AzureVM `
        -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName } |
    ForEach-Object {
        [PSCustomObject]@{
            SubscriptionId = $subId
            VaultName      = $vault.Name
            VmName         = $_.FriendlyName.ToLower()
            ProtectionState= $_.ProtectionState
            BackupStatus   = $_.LastBackupStatus
        }
    }
}

# 3️⃣ RSV’de var ama canlı VM listesinde yok
$orphanBackups = $protectedVMs | Where-Object {
    $_.VmName -notin $liveVMs.VmName
}

# 4️⃣ Sonuç
$orphanBackups | Sort-Object SubscriptionId, VaultName, VmName
