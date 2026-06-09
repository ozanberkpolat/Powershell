# ============================================================================
# Faz 4: Azure VM Maintenance Configuration Tag Synchronization (Final Version)
# ============================================================================

Connect-AzAccount -ErrorAction SilentlyContinue

# 1. Doğrulanmış KQL Sorgusu: VM ve Maintenance Config eşleşmesini çeker
$query = @"
maintenanceresources
| where type =~ 'microsoft.maintenance/configurationassignments'
| extend configName = tostring(split(properties.maintenanceConfigurationId, '/')[-1])
| extend targetResourceId = tolower(tostring(properties.resourceId))
| project configName, targetResourceId
| join kind=rightouter (
    Resources
    | where type =~ 'microsoft.compute/virtualmachines'
    | project VM_Name = name, vmId = tolower(id), ResourceGroup = resourceGroup
) on `$left.targetResourceId == `$right.vmId
| project 
    VM_Name, 
    MaintenanceConfiguration = coalesce(configName, 'Unassigned'), 
    vmId
"@

Write-Host "Adım 1: Azure Resource Graph üzerinden gerçek veriler çekiliyor..." -ForegroundColor Cyan
$vmData = Search-AzGraph -Query $query

$totalCount = $vmData.Count
Write-Host "Toplam $totalCount adet VM analiz edildi. Güncelleme başlıyor...`n" -ForegroundColor Yellow

# 2. İnteraktif Etiket Güncelleme Döngüsü
$successCount = 0
$skipCount = 0
$errorCount = 0
$currentIndex = 1
$autoConfirmAll = $false

foreach ($vm in $vmData) {
    # KQL'den gelen verileri güvenli hale getiriyoruz
    $vmId = [string]$vm.vmId
    $vmName = [string]$vm.VM_Name
    $mConfig = if ([string]::IsNullOrWhiteSpace($vm.MaintenanceConfiguration)) { "Unassigned" } else { [string]$vm.MaintenanceConfiguration }

    $tagsToUpdate = @{
        "MaintenanceConfiguration" = $mConfig
    }
    
    Write-Host "---------------------------------------------------"
    Write-Host "VM: $vmName" -ForegroundColor Cyan
    Write-Host "Tespit Edilen Config: $mConfig"
    
    # Onay Mekanizması
    if (-not $autoConfirmAll) {
        $prompt = Read-Host "[$currentIndex/$totalCount] Etiket yazılsın mı? [E]vet / [H]ayır / [T]ümüne Evet / [I]ptal"
        
        switch -Regex ($prompt) {
            "^[eE]" { $action = "yes" }
            "^[hH]" { $action = "no" }
            "^[tT]" { $action = "all"; $autoConfirmAll = $true }
            "^[iI]" { Write-Host "İşlem durduruldu."; break }
            default { $action = "no"; Write-Host "Atlanıyor..." -ForegroundColor Yellow }
        }
    } else {
        $action = "all"
    }

    # Aksiyon Uygulama
    if ($action -eq "yes" -or $action -eq "all") {
        try {
            Write-Host "Yazılıyor... " -NoNewline
            # Merge operasyonu mevcut Backup/Replication etiketlerini asla bozmaz.
            Update-AzTag -ResourceId $vmId -Tag $tagsToUpdate -Operation Merge -ErrorAction Stop
            Write-Host "[TAMAMLANDI]" -ForegroundColor Green
            $successCount++
        }
        catch {
            Write-Host "[HATA: $($_.Exception.Message)]" -ForegroundColor Red
            $errorCount++
        }
    } else {
        Write-Host "VM Atlandı." -ForegroundColor DarkGray
        $skipCount++
    }
    
    $currentIndex++
}

# 3. Final Özeti
Write-Host "`n===================================================" -ForegroundColor Green
Write-Host "İŞLEM ÖZETİ" -ForegroundColor Cyan
Write-Host "Başarıyla Etiketlenen: $successCount"
Write-Host "Atlanan/Pas Geçilen   : $skipCount"
if ($errorCount -gt 0) {
    Write-Host "Hata Alınan VM Sayısı: $errorCount" -ForegroundColor Red
}
Write-Host "===================================================" -ForegroundColor Green