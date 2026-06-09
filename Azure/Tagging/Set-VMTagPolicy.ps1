# ============================================================================
# Faz 3: Azure VM Backup & Replication Tag Synchronization (Interactive)
# ============================================================================

# 1. KQL Sorgusu ile Gerçek Verileri Çekme
$query = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project vmId = tolower(id), vmName = tolower(name), originalVmName = name, resourceGroup
| join kind=leftouter (
    RecoveryServicesResources
    | where type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems' 
         or type =~ 'microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems'
    | extend isBackup = type contains 'backupfabrics'
    | extend isReplication = type contains 'replicationfabrics'
    | extend mappedVmName = tolower(case(
        isBackup, tostring(split(properties.sourceResourceId, '/')[-1]),
        isReplication, tostring(properties.friendlyName),
        ''
    ))
    | where isnotempty(mappedVmName)
    | extend policy = tostring(properties.policyName)
    | summarize 
        BackupStatus = anyif('Yes', isBackup and isnotempty(policy)),
        BackupPolicy = anyif(policy, isBackup and isnotempty(policy)),
        ReplicationStatus = anyif('Yes', isReplication)
        by vmName = mappedVmName
) on vmName
| project 
    VM_Name = originalVmName, 
    ResourceGroup = resourceGroup, 
    BackupStatus = coalesce(BackupStatus, 'No'), 
    BackupPolicy = coalesce(BackupPolicy, 'None'), 
    ReplicationStatus = coalesce(ReplicationStatus, 'No'), 
    vmId
"@
Connect-AzAccount

Write-Host "Adım 1: Azure Resource Graph üzerinden canlı veriler çekiliyor..." -ForegroundColor Cyan
$vmData = Search-AzGraph -Query $query

$totalCount = $vmData.Count
Write-Host "Toplam $totalCount adet VM bulundu. Etiketleme aşamasına geçiliyor.`n" -ForegroundColor Yellow

# 2. İnteraktif Etiket Güncelleme Döngüsü
$successCount = 0
$skipCount = 0
$errorCount = 0
$currentIndex = 1
$autoConfirmAll = $false

foreach ($vm in $vmData) {
    $vmId = $vm.vmId
    $vmName = $vm.VM_Name
    
    # Yazılacak etiketler
    $tagsToUpdate = @{
        "BackupEnabled"      = $vm.BackupStatus
        "BackupPolicy"       = $vm.BackupPolicy
        "ReplicationEnabled" = $vm.ReplicationStatus
    }
    
    Write-Host "---------------------------------------------------"
    Write-Host "VM: $vmName" -ForegroundColor Cyan
    Write-Host "Planlanan Tag'ler -> Backup: $($vm.BackupStatus) | Policy: $($vm.BackupPolicy) | Rep: $($vm.ReplicationStatus)"
    
    # Onay Mekanizması
    if (-not $autoConfirmAll) {
        $prompt = Read-Host "[$currentIndex/$totalCount] Bu VM güncellensin mi? [E]vet / [H]ayır / [T]ümüne Evet / [I]ptal"
        
        switch -Regex ($prompt) {
            "^[eE]" { $action = "yes" }
            "^[hH]" { $action = "no" }
            "^[tT]" { $action = "all"; $autoConfirmAll = $true }
            "^[iI]" { Write-Host "İşlem kullanıcı tarafından durduruldu."; break }
            default { $action = "no"; Write-Host "Geçersiz giriş, bu VM atlanıyor..." -ForegroundColor Yellow }
        }
    } else {
        $action = "all"
    }

    # Aksiyon Uygulama
    if ($action -eq "yes" -or $action -eq "all") {
        try {
            Write-Host "Etiketler yazılıyor..." -NoNewline
            # -Operation Merge sadece hedef etiketleri değiştirir, VM üzerindeki diğer etiketleri korur.
            Update-AzTag -ResourceId $vmId -Tag $tagsToUpdate -Operation Merge -ErrorAction Stop | Out-Null
            Write-Host " [BAŞARILI]" -ForegroundColor Green
            $successCount++
        }
        catch {
            Write-Host " [HATA: $($_.Exception.Message)]" -ForegroundColor Red
            $errorCount++
        }
    } else {
        Write-Host "VM atlandı." -ForegroundColor DarkGray
        $skipCount++
    }
    
    $currentIndex++
}

# 3. Sonuç Özeti
Write-Host "===================================================" -ForegroundColor Green
Write-Host "FAZ 3: İŞLEM ÖZETİ" -ForegroundColor Cyan
Write-Host "Başarılı Güncelleme : $successCount"
Write-Host "Atlanan VM Sayısı   : $skipCount"
if ($errorCount -gt 0) {
    Write-Host "Hatalı İşlem        : $errorCount" -ForegroundColor Red
} else {
    Write-Host "Hatalı İşlem        : 0" -ForegroundColor Green
}
Write-Host "===================================================" -ForegroundColor Green