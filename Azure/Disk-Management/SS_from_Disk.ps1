
# Parametreler
$subscriptionId = "90992e51-523b-431a-92ce-76828ffb7957"
$sourceRG = "RG-ISBANK-COREBANK-VM-PROD-GW"
$destinationRG = "rg-isbankag-drtest-gw"
$location = "germanywestcentral"
$snapshotPrefix = "ss-drtest-disk"

# Azure'a bağlan
Connect-AzAccount
Select-AzSubscription -SubscriptionId $subscriptionId

# Kaynak disk isimleri
$diskNames = @(
    "vm-isbankag-corebank-prod-ISBAZDB01_DataDisk_0",
    "vm-isbankag-corebank-prod-ISBAZDB01_DataDisk_1",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_2",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_3",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_4",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_5",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_6",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_7",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_8",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_9",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_10",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_11",
    "vm-isbankag-corebank-prod-ISBAZDB01_Datadisk_12"
)

# Paralel snapshot oluşturma
$diskNames | ForEach-Object -Parallel {
    $disk = Get-AzDisk -ResourceGroupName $using:sourceRG -DiskName $_

    if ($disk -ne $null) {
        $diskNumber = ($_ -split "_")[-1]
        $snapshotName = "$using:snapshotPrefix$diskNumber"

        # API çağrısı zamanı
        $apiCallTime = Get-Date -Format "HH:mm:ss"
        Write-Host "[$apiCallTime] Azure API çağrısı gönderildi: $snapshotName"

        # Snapshot oluştur
        New-AzSnapshot `
            -Snapshot (New-AzSnapshotConfig -SkuName Premium_LRS -SourceUri $disk.Id -Location $using:location -PublicNetworkAccess Disabled -NetworkAccessPolicy DenyAll -CreateOption Copy) `
            -SnapshotName $snapshotName `
            -ResourceGroupName $using:destinationRG

        # ProvisioningState kontrolü
        do {
            Start-Sleep -Seconds 5
            $snapshot = Get-AzSnapshot -ResourceGroupName $using:destinationRG -SnapshotName $snapshotName
        } while ($snapshot.ProvisioningState -ne "Succeeded")

        # Tamamlanma zamanı
        $endTime = Get-Date -Format "HH:mm:ss"
        Write-Host "[$endTime] Snapshot tamamlandı: $snapshotName"
    }
    else {
        Write-Host "Disk bulunamadı: $_"
    }
} -ThrottleLimit 15
