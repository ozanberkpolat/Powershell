<#
    .SYNOPSIS
        Multi-Subscription Service-level Azure Cost Comparison
    .DESCRIPTION
        Discovers all active subscriptions the user has access to, queries 
        each for monthly costs, aggregates the data across all subscriptions, 
        and pivots it into an Executive Summary format.
    .AUTHOR
        Cloud Consultant
#>

# 1. Authentication & Token
$accessToken = az account get-access-token --resource "https://management.azure.com" --query "accessToken" --output tsv
if (-not $accessToken) { Write-Error "Token yok. Lütfen 'az login' komutunu çalıştırın."; return }

$headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json" }

# 2. Dynamic Dates (Son 2 Ay)
$dateM1 = (Get-Date -Day 1).AddMonths(-2)
$dateM2 = (Get-Date -Day 1).AddMonths(-1)

$startDate = $dateM1.ToString("yyyy-MM-01T00:00:00Z")
$endDate   = $dateM2.AddMonths(1).AddDays(-1).ToString("yyyy-MM-ddT23:59:59Z")

$labelM1 = $dateM1.ToString("yyyy-MM")
$labelM2 = $dateM2.ToString("yyyy-MM")

# 3. API Request Body Definition
$body = @{
    type = "ActualCost"
    timeframe = "Custom"
    timePeriod = @{ from = $startDate; to = $endDate }
    dataset = @{
        granularity = "Monthly"
        aggregation = @{ totalCost = @{ name = "PreTaxCost"; function = "Sum" } }
        grouping = @( @{ type = "Dimension"; name = "ServiceName" } )
    }
} | ConvertTo-Json -Depth 10

# 4. GET ALL ACTIVE SUBSCRIPTIONS
Write-Host "Aktif abonelikler bulunuyor..." -ForegroundColor Cyan
$subIds = az account list --query "[?state=='Enabled'].id" --output tsv

if (-not $subIds) { Write-Error "Erişilebilir aktif abonelik bulunamadı."; return }

# Verileri toplayacağımız ana havuz
$masterReport = @()
$actualMonthColumn = $null

# 5. LOOP THROUGH SUBSCRIPTIONS
foreach ($subId in $subIds) {
    Write-Host "Veri çekiliyor: Subscription $subId..." -ForegroundColor Yellow
    $uri = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
    
    try {
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
        
        # Kolon isimlerini ilk başarılı istekte yakalayalım
        if ($null -eq $actualMonthColumn -and $response.properties.columns.name) {
            $columns = $response.properties.columns.name
            $actualMonthColumn = $columns | Where-Object { $_ -match "Month|Date" } | Select-Object -First 1
        }

        # Gelen satırları PowerShell objesine çevirip ana havuza ekleyelim
        if ($response.properties.rows) {
            foreach ($row in $response.properties.rows) {
                $obj = [PSCustomObject]@{}
                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $obj | Add-Member -MemberType NoteProperty -Name $columns[$i] -Value $row[$i]
                }
                $masterReport += $obj
            }
        }
    } catch {
        Write-Warning "Subscription $subId için veri çekilemedi. Hata: $_"
    }
}

if ($masterReport.Count -eq 0) {
    Write-Warning "Hiçbir abonelikten veri dönmedi."
    return
}

Write-Host "Veriler işleniyor ve analiz ediliyor..." -ForegroundColor Cyan

# 6. PIVOT VE AGGREGATION (Tüm Aboneliklerin Toplamı)
# Group-Object sayesinde "Storage" harcaması 5 farklı abonelikten de gelse hepsi tek satırda birleşecek.
$finalReport = foreach ($group in $masterReport | Group-Object ServiceName) {
    $svcName = $group.Name
    
    # İlgili ayları buluyoruz
    $rowsM1 = $group.Group | Where-Object { ([datetime]($_.$actualMonthColumn)).ToString("yyyy-MM") -eq $labelM1 }
    $rowsM2 = $group.Group | Where-Object { ([datetime]($_.$actualMonthColumn)).ToString("yyyy-MM") -eq $labelM2 }
    
    # Measure-Object -Sum kullanarak tüm aboneliklerdeki o ayki Storage/VM maliyetlerini GÜVENLE topluyoruz
    $costM1 = if ($rowsM1) { ($rowsM1 | Measure-Object -Property PreTaxCost -Sum).Sum } else { 0.0 }
    $costM2 = if ($rowsM2) { ($rowsM2 | Measure-Object -Property PreTaxCost -Sum).Sum } else { 0.0 }
    
    # Fark Hesaplamaları
    $diffUSD = $costM2 - $costM1
    $diffPct = 0.0
    
    if ($costM1 -gt 0) {
        $diffPct = ($diffUSD / $costM1) * 100
    } elseif ($costM2 -gt 0) {
        $diffPct = 100.0
    }

    [PSCustomObject]@{
        "Resource Name"     = $svcName
        "Cost on $labelM1"  = [Math]::Round($costM1, 2)
        "Cost on $labelM2"  = [Math]::Round($costM2, 2)
        "Difference in %"   = "$([Math]::Round($diffPct, 2))%"
        "Difference in USD" = [Math]::Round($diffUSD, 2)
    }
}

# 7. SONUÇ
$finalReport | Sort-Object "Difference in USD" -Descending | Format-Table -AutoSize