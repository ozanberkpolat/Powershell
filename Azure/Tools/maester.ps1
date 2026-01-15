Install-Module Pester -SkipPublisherCheck -Force -Scope CurrentUser # Pester modülünü yükle
Install-Module Maester -Scope CurrentUser # Maester modülünü yükle

md maester-tests # Testler için dizin oluştur
cd maester-tests # Dizine geç
Install-MaesterTests # Maester testlerini yükle

Install-Module ExchangeOnlineManagement -Scope CurrentUser # Exchange Online modülünü yükle

Import-Module ExchangeOnlineManagement # Exchange Online modülünü içe aktar

Install-Module MicrosoftTeams # Microsoft Teams modülünü yükle

Import-Module MicrosoftTeams # Microsoft Teams modülünü içe aktar

Connect-Maester -Service All # Bağlantı için tüm servisleri kullan - Exchange ve Teams dahil

Connect-Maester -GraphClientId 'f45ec3ad-32f0-4c06-8b69-47682afe0216' # App registration ile bağlanma, gerekli izinler verilmiş olmalı

# App registration oluşturma ve gerekli izinlerin verilmesi için: https://maester.dev/docs/connect-maester/connect-maester-advanced/

Invoke-Maester # Tüm testleri çalıştır

# Tüm testlerin düzgün çalışması için müşteri tenant'ında gerekli yapılandırmaların yapılmış olması gerekir.