Connect-AzAccount
$vms = Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines"
$total = $vms.Count
$i = 1

Write-Host "Toplam $total VM'e MaintenanceConfiguration etiketi ekleniyor..." -ForegroundColor Cyan

foreach ($vm in $vms) {
    Write-Host "[$i/$total] $($vm.Name) güncelleniyor... " -NoNewline
    
    $newTag = @{ "MaintenanceConfiguration" = "Unassigned" } # Varsayılan değerini buradan değiştirebilirsin
    
    try {
        Update-AzTag -ResourceId $vm.ResourceId -Tag $newTag -Operation Merge -ErrorAction Stop
        Write-Host "[BAŞARILI]" -ForegroundColor Green
    } catch {
        Write-Host "[HATA: $($_.Exception.Message)]" -ForegroundColor Red
    }
    $i++
}
Write-Host "İşlem Tamamlandı!" -ForegroundColor Green