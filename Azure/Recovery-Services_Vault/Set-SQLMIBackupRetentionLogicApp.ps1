az login
# 1. Access Token ve Mevcut Tüm Aboneliklerin ID'lerini Çek
Write-Host "Azure bağlantısı kuruluyor ve abonelik listesi alınıyor..." -ForegroundColor Cyan
$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$subIds = (az account list --query "[].id" -o tsv)

if ($subIds.Count -eq 0) {
    return
}

# 2. Azure Resource Graph API URL
$url = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"

# 3. KQL Sorgusu
# Önemli: resourceGroup ve subscriptionId küçük harf olmalı (Case-sensitive)
$query = @"
resources
| where type =~ 'microsoft.sql/managedinstances/databases'
| extend 
    InstanceName = tostring(split(id, '/')[8]),
    DatabaseName = name,
    EarliestPoint = todatetime(properties.earliestRestorePoint)
| extend 
    ActualDays = datetime_diff('day', now(), EarliestPoint)
| where isnull(EarliestPoint) or ActualDays < 30
| project 
    InstanceName, 
    DatabaseName, 
    EarliestPoint = iif(isnull(EarliestPoint), 'No Backup Found', tostring(EarliestPoint)), 
    ActualDays = iif(isnull(ActualDays), 0, ActualDays),
    Status = iif(isnull(EarliestPoint), '🔴 CRITICAL', '🟡 WARNING'),
    resourceGroup,
    subscriptionId
| order by ActualDays asc
"@

# 4. Request Body (Bütün abonelik ID'lerini buraya basıyoruz)
$queryJson = @{ 
    subscriptions = $subIds
    query = $query 
} | ConvertTo-Json -Depth 10

# 5. API İsteği Parametreleri
$params = @{
    Method  = "Post"
    Uri     = $url
    Headers = @{ 
        "Authorization" = "Bearer $token" 
        "Content-Type"  = "application/json" 
    }
    Body    = $queryJson
}

# 6. Sorguyu Çalıştır ve Sonuçları Göster
try {
    $response = Invoke-RestMethod @params
    
    if ($response.data.Count -gt 0) {
        # Sonuçları ekrana tablo olarak bas
        $response.data | Format-Table -AutoSize
        
        # İstersen sonuçları bir değişkene atıp Logic App'e POST edebilirsin
        # $response.data | ConvertTo-Json -Depth 10
    } else {
        Write-Host "`n[OK] Tüm aboneliklerdeki Managed Instance veritabanları 30 günlük yedekleme hedefine uygun." -ForegroundColor Green
    }
}
catch {
    $errorDetails = $_.Exception.Message
    Write-Host "`nAPI Hatası: $errorDetails" -ForegroundColor Red
}