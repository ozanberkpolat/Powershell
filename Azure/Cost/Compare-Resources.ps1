# Azure'a giriş yap
Connect-AzAccount

# Karşılaştırılacak aylar (YIL-AY formatında girilmeli)
$firstMonth = "2025-11"
$secondMonth = "2025-12"

# Kayıt klasörü
$basePath = "C:\AzureResourceDiff"

# Klasör oluştur
New-Item -ItemType Directory -Path $basePath -Force | Out-Null

# Tüm subscription’ları al
$subscriptions = Get-AzSubscription

foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id

    $subFolder = Join-Path $basePath $sub.Name
    New-Item -ItemType Directory -Path $subFolder -Force | Out-Null

    # Kaynak listelerini ay ay çekmek için geçici dizinler
    $firstMonthResources = @()
    $secondMonthResources = @()

    # Tüm resource group’ları al
    $resourceGroups = Get-AzResourceGroup

    foreach ($rg in $resourceGroups) {
        Write-Host "  Checking resource group: $($rg.ResourceGroupName)"

        # X ayı kaynak listesi
        $firstResources = Get-AzResource -ResourceGroupName $rg.ResourceGroupName | Where-Object {
            $_.ResourceId -ne $null
        }
        foreach ($res in $firstResources) {
            $firstMonthResources += [PSCustomObject]@{
                Name = $res.Name
                Type = $res.ResourceType
                ResourceGroup = $res.ResourceGroupName
                SubscriptionId = $sub.Id
                Id = $res.ResourceId
            }
        }

        Start-Sleep -Milliseconds 300  # API yükünü azaltmak için kısa bekleme

        # Y ayı kaynak listesi
        # Bu örnekte anlık alıyoruz, geçmiş veri çekilemiyor. Sadece X ayı snapshot’ı varsa karşılaştırabilirsin.
        # Alternatif olarak bu scripti her ay çalıştırarak snapshot’ları arşivleyebilirsin.
    }

    # CSV olarak kaydet
    $firstCsv = Join-Path $subFolder "$($firstMonth)_resources.csv"
    $secondCsv = Join-Path $subFolder "$($secondMonth)_resources.csv"

    $firstMonthResources | Export-Csv -Path $firstCsv -NoTypeInformation
    $secondMonthResources = Get-AzResource | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            Type = $_.ResourceType
            ResourceGroup = $_.ResourceGroupName
            SubscriptionId = $sub.Id
            Id = $_.ResourceId
        }
    }
    $secondMonthResources | Export-Csv -Path $secondCsv -NoTypeInformation

    # Karşılaştırma
    $firstIds = $firstMonthResources.Id
    $secondIds = $secondMonthResources.Id

    $added = $secondMonthResources | Where-Object { $firstIds -notcontains $_.Id }
    $removed = $firstMonthResources | Where-Object { $secondIds -notcontains $_.Id }

    # Farkları yazdır
    Write-Host "    Added resources in $secondMonth : $($added.Count)" -ForegroundColor Green
    Write-Host "    Removed resources since $firstMonth : $($removed.Count)" -ForegroundColor Red

    # CSV olarak kaydet
    $added | Export-Csv -Path (Join-Path $subFolder "added_in_$secondMonth.csv") -NoTypeInformation
    $removed | Export-Csv -Path (Join-Path $subFolder "removed_since_$firstMonth.csv") -NoTypeInformation
}

Write-Host "✅ Tüm işlemler tamamlandı. Raporlar: $basePath"
