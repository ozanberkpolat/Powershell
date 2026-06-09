# 1. Tek Join ve İsim Eşleşmeli Optimize KQL Sorgusu
$query = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project vmId = tolower(id), vmName = tolower(name), originalVmName = name, resourceGroup
| join kind=leftouter (
    RecoveryServicesResources
    | where type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems' 
         or type =~ 'microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems'
    | extend isBackup = type contains 'backupfabrics'
    | extend isReplication = type contains 'replicationfabrics'
    // Backup için ID'nin sonundaki VM adını alıyoruz, Replikasyon için doğrudan friendlyName kullanıyoruz
    | extend mappedVmName = tolower(case(
        isBackup, tostring(split(properties.sourceResourceId, '/')[-1]),
        isReplication, tostring(properties.friendlyName),
        ''
    ))
    | where isnotempty(mappedVmName)
    | extend policy = tostring(properties.policyName)
    // Eğer backup ise ve policy boş değilse 'Yes' kabul ediyoruz
    | summarize 
        BackupStatus = anyif('Yes', isBackup and isnotempty(policy)),
        BackupPolicy = anyif(policy, isBackup and isnotempty(policy)),
        ReplicationStatus = anyif('Yes', isReplication)
        by vmName = mappedVmName
) on vmName
| project 
    VM_Name = originalVmName, 
    ResourceGroup = resourceGroup, 
    BackupStatus = coalesce(BackupStatus, 'No'), 
    BackupPolicy = coalesce(BackupPolicy, 'None'), 
    ReplicationStatus = coalesce(ReplicationStatus, 'No'), 
    vmId
"@

Connect-AzAccount

Write-Host "Veriler çekiliyor (Tek JOIN ve İsim Eşleşmesi ile ARG limitleri aşılıyor)..." -ForegroundColor Cyan

# 2. Sorguyu çalıştır
$vmData = Search-AzGraph -Query $query

# 3. Sonuçları Tablo Olarak Göster
$vmData | Sort-Object BackupStatus, ReplicationStatus -Descending | Format-Table VM_Name, BackupStatus, BackupPolicy, ReplicationStatus -AutoSize

# İstatistikler
$total = $vmData.Count
$bUp = ($vmData | Where-Object { $_.BackupStatus -eq 'Yes' }).Count
$repl = ($vmData | Where-Object { $_.ReplicationStatus -eq 'Yes' }).Count

Write-Host "--- TARAMA ÖZETİ ---" -ForegroundColor Green
Write-Host "Toplam VM Sayısı          : $total"
Write-Host "Yedeklemesi Aktif VM'ler  : $bUp"
Write-Host "Replikasyonu Aktif VM'ler : $repl"
Write-Host "--------------------" -ForegroundColor Green