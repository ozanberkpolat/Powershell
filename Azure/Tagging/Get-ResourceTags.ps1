Connect-AzAccount
# 1. VM'i bulalım (Resource Group adını bilmediğimiz için tüm abonelikte isminden arıyoruz)
$testVmName = "vm-isbankag-core-prod-ISBNAC01"
$vm = Get-AzResource -Name $testVmName -ResourceType "Microsoft.Compute/virtualMachines"

if ($vm) {
    Write-Host "VM Bulundu! ID: $($vm.ResourceId)" -ForegroundColor Cyan
    
    # 2. Şu anki etiketlerine bakalım
    Write-Host "Mevcut Etiketler:" -ForegroundColor Yellow
    $vm.Tags | Format-Table -AutoSize

    # 3. Test etiketlerimizi basalım (Hata yakalamayı kapattık ki kırmızı hatayı görelim)
    $testTags = @{
        "BackupEnabled"      = "Yes"
        "BackupPolicy"       = "Test-Policy"
        "ReplicationEnabled" = "No"
    }

    Write-Host "Etiketler Merge ediliyor..." -ForegroundColor Cyan
    Update-AzTag -ResourceId $vm.ResourceId -Tag $testTags -Operation Merge
    
    Write-Host "İşlem bitti. Güncel etiketler tekrar kontrol ediliyor:" -ForegroundColor Yellow
    (Get-AzResource -ResourceId $vm.ResourceId).Tags | Format-Table -AutoSize

} else {
    Write-Host "VM bulunamadı! Lütfen doğru Subscription'da (Abonelikte) olduğunuzdan emin olun." -ForegroundColor Red
}