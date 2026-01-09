# YÜkleme ve çalıştırma

# Microsoft365DSC modülünü yükler.
Install-Module Microsoft365DSC -Force 

# Microsoft365DSC bağımlılıklarını günceller.
Update-M365DSCDependencies 

# Yüklü Microsoft365DSC modülünün yolunu ve sürümünü gösterir.
Get-Module Microsoft365DSC -ListAvailable | Select-Object ModuleBase, Version 

# Microsoft 365 DSC yapılandırma web arayüzünü başlatır. Web arayüzü üzerinden dışa aktarma seçeneklerinizi seçebilir ve bu seçeneklere göre yedekleme yapabilirsini - https://export.microsoft365dsc.com/#Home .
Export-M365DSCConfiguration -LaunchWebUI

$Credential = Get-Credential # Kimlik bilgilerini al
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss") # Zaman damgası oluşturur.
$filename = "M365DSC_$timestamp.ps1" # Dosya adı oluşturur ve zaman damgasını ekler.

Export-M365DSCConfiguration -Components @("AADApplication") -Credential $Credential -Path "C:\M365DSC" -FileName $filename
# Sadece AADApplication ayarlarını  dışa aktarır ve belirtilen yola kaydeder.
# Yukarıdaki satırı ihtiyacınıza göre düzenleyin, farklı bileşenler ekleyebilir veya çıkarabilirsiniz.

# Restore

# Dışa aktarılan yapılandırma tekrar çalıştırılarak compile edilir.
.\M365TenantConfig.ps1 -Credential $Credential 

# Yapılandırmayı uygulamak için DSC kullanılır.
Start-DSCConfiguration -Path C:\DemoM365DSC\M365TenantConfig -Wait -Verbose -Force

# Konfigürasyon drift kontrolünü kapatmak için kullanılır.
Stop-DSCConfiguration -Force
Remove-DSCConfigurationDocument -Stage Current