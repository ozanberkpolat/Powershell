Connect-AzAccount

# Zaman aralıkları
$novStart = Get-Date "2025-11-01"
$novEnd   = Get-Date "2025-11-30 23:59:59"
$decStart = Get-Date "2025-12-01"
$decEnd   = Get-Date "2025-12-31 23:59:59"

# Kayıt yeri
$outputFolder = "C:\AzureResourceDiff"
New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null

# Subscriptions
$subscriptions = Get-AzSubscription

foreach ($sub in $subscriptions) {
    Write-Host "`n🔍 Subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id

    # Kasım loglarını al
    $novLogs = Get-AzActivityLog -StartTime $novStart -EndTime $novEnd -Status "Succeeded" |
        Where-Object {
            $_.OperationName.Value -like "*write*" -or $_.OperationName.Value -like "*delete*"
        }

    # Aralık loglarını al
    $decLogs = Get-AzActivityLog -StartTime $decStart -EndTime $decEnd -Status "Succeeded" |
        Where-Object {
            $_.OperationName.Value -like "*write*" -or $_.OperationName.Value -like "*delete*"
        }

    # Kasım
    $novCreated = $novLogs | Where-Object { $_.OperationName.Value -like "*write*" -and $_.ResourceId }
    $novDeleted = $novLogs | Where-Object { $_.OperationName.Value -like "*delete*" -and $_.ResourceId }

    # Aralık
    $decCreated = $decLogs | Where-Object { $_.OperationName.Value -like "*write*" -and $_.ResourceId }
    $decDeleted = $decLogs | Where-Object { $_.OperationName.Value -like "*delete*" -and $_.ResourceId }

    # Özet
    Write-Host "  Kasım'da oluşturulan: $($novCreated.Count)" -ForegroundColor Green
    Write-Host "  Kasım'da silinen:     $($novDeleted.Count)" -ForegroundColor Red
    Write-Host "  Aralık'ta oluşturulan: $($decCreated.Count)" -ForegroundColor Green
    Write-Host "  Aralık'ta silinen:     $($decDeleted.Count)" -ForegroundColor Red

    # Export CSV
    $safeSub = $sub.Name -replace '[\\/:*?"<>|]', '_'
    $prefix = Join-Path $outputFolder $safeSub

    $novCreated | Select-Object EventTimestamp, ResourceId, ResourceGroupName, OperationName, Caller |
        Export-Csv -NoTypeInformation -Path "$prefix-Kasim2025-Olusturulan.csv"
    $novDeleted | Select-Object EventTimestamp, ResourceId, ResourceGroupName, OperationName, Caller |
        Export-Csv -NoTypeInformation -Path "$prefix-Kasim2025-Silinen.csv"
    $decCreated | Select-Object EventTimestamp, ResourceId, ResourceGroupName, OperationName, Caller |
        Export-Csv -NoTypeInformation -Path "$prefix-Aralik2025-Olusturulan.csv"
    $decDeleted | Select-Object EventTimestamp, ResourceId, ResourceGroupName, OperationName, Caller |
        Export-Csv -NoTypeInformation -Path "$prefix-Aralik2025-Silinen.csv"
}

Write-Host "`n✅ Bitti. CSV çıktıları: $outputFolder" -ForegroundColor Yellow
