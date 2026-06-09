$token = $env:XURRENT_API_TOKEN   # set via: $env:XURRENT_API_TOKEN = "your-token"
# Token'ın başına otomatik olarak "Bearer " ekliyoruz:
$headers = @{
    "Authorization" = "Bearer $token"
    "X-Xurrent-Account" = $env:XURRENT_ACCOUNT   # set via: $env:XURRENT_ACCOUNT = "your-account-id"
    "Accept" = "application/json"
}

$uri = "https://api.4me.com/v1/requests"

try {
    Write-Host "Xurrent API'sine bağlanılıyor..." -ForegroundColor Cyan
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
    Write-Host "BAŞARILI! Biletler çekildi." -ForegroundColor Green
    # Sadece ilk biletin başlığını görelim:
    $response[0] | Select-Object id, subject
} catch {
    Write-Host "HATA ALINDI!" -ForegroundColor Red
    Write-Host $_.Exception.Message
    
    # Detaylı hata mesajını okumak için:
    if ($_.ErrorDetails) {
        Write-Host "API'nin cevabı: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
    }
}