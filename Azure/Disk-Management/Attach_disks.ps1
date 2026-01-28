Connect-AzAccount | Out-Null
Set-AzContext -SubscriptionId "90992e51-523b-431a-92ce-76828ffb7957" | Out-Null

$RgName     = "RG-ISBANKAG-DRTEST-GW"
$VmName     = "TARGET-VM-NAME"
$DiskPrefix = "disk-drtest-"

$ReadOnlyLuns = @(1,2,4,10,11,12)

$vm = Get-AzVM -ResourceGroupName $RgName -Name $VmName

$disks = Get-AzDisk -ResourceGroupName $RgName |
         Where-Object { $_.Name -like "$DiskPrefix*" }

if (-not $disks) {
    Write-Host "Attach edilecek disk bulunamadı."
    return
}

foreach ($disk in $disks) {

    # disk adının sonundaki rakam LUN olacak (disk0 -> 0)
    if ($disk.Name -match 'disk(\d+)$') {
        $lun = [int]$matches[1]
    }
    else {
        Write-Host "SKIP: LUN parse edilemedi -> $($disk.Name)"
        continue
    }

    # Disk zaten bağlı mı?
    if ($vm.StorageProfile.DataDisks.ManagedDisk.Id -contains $disk.Id) {
        Write-Host "SKIP: Zaten bağlı -> $($disk.Name)"
        continue
    }

    # LUN dolu mu?
    if ($vm.StorageProfile.DataDisks.Lun -contains $lun) {
        Write-Host "ERROR: LUN $lun zaten dolu -> $($disk.Name)"
        continue
    }

    # HostCaching seçimi
    if ($ReadOnlyLuns -contains $lun) {
        $caching = "ReadOnly"
    }
    else {
        $caching = "None"
    }

    Write-Host "Attach: $($disk.Name) -> LUN $lun (Caching: $caching)"

    Add-AzVMDataDisk `
        -VM $vm `
        -Name $disk.Name `
        -ManagedDiskId $disk.Id `
        -Lun $lun `
        -CreateOption Attach `
        -Caching $caching | Out-Null
}

Update-AzVM -ResourceGroupName $RgName -VM $vm | Out-Null

Write-Host "Diskler LUN numarasına göre attach edildi. Host caching kuralları uygulandı."
