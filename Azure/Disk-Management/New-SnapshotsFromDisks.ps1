# -------- CONFIG (fill before running) --------
$subscriptionId = $env:AZURE_SUBSCRIPTION_ID
$sourceRG       = "RG-SOURCE"          # resource group containing source disks
$destinationRG  = "RG-DESTINATION"     # resource group for snapshots
$location       = "germanywestcentral"
$snapshotPrefix = "ss-snapshot-disk"

Connect-AzAccount
Select-AzSubscription -SubscriptionId $subscriptionId

# -------- DISK NAMES (fill before running) --------
$diskNames = @(
    # "vm-name_DataDisk_0",
    # "vm-name_DataDisk_1",
)

$diskNames | ForEach-Object -Parallel {
    $disk = Get-AzDisk -ResourceGroupName $using:sourceRG -DiskName $_

    if ($disk -ne $null) {
        $diskNumber = ($_ -split "_")[-1]
        $snapshotName = "$using:snapshotPrefix$diskNumber"

        New-AzSnapshot `
            -Snapshot (New-AzSnapshotConfig -SkuName Premium_LRS -SourceUri $disk.Id -Location $using:location -PublicNetworkAccess Disabled -NetworkAccessPolicy DenyAll -CreateOption Copy) `
            -SnapshotName $snapshotName `
            -ResourceGroupName $using:destinationRG

        do {
            Start-Sleep -Seconds 5
            $snapshot = Get-AzSnapshot -ResourceGroupName $using:destinationRG -SnapshotName $snapshotName
        } while ($snapshot.ProvisioningState -ne "Succeeded")

        $endTime = Get-Date -Format "HH:mm:ss"
        Write-Host "[$endTime] Snapshot tamamlandı: $snapshotName"
    }
    else {
        Write-Host "Disk bulunamadı: $_"
    }
} -ThrottleLimit 15
