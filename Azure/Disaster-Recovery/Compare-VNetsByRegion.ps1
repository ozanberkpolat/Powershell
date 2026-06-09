$subscriptionIds = @(
    "daecf2a9-4ad0-41a5-8d24-be2f3e4ab637",
    "d3a1c6d4-b44d-4763-811e-cb2ba1ef7f5b",
    "90992e51-523b-431a-92ce-76828ffb7957"
)

$gwVnets = @()
$gnVnets = @()

foreach ($subId in $subscriptionIds) {
    Set-AzContext -SubscriptionId $subId | Out-Null
    $subName = (Get-AzContext).Subscription.Name
    Write-Host "`n[$subName] analiz ediliyor..." -ForegroundColor Cyan

    # GWC VNet'leri — migratetest ve izole hariç
    $gw = Get-AzVirtualNetwork | Where-Object {
        $_.Location -eq "germanywestcentral" -and
        $_.Name -notlike "*migratetest*" -and
        $_.Name -notlike "rg-izole*"
    }

    foreach ($vnet in $gw) {
        $gwVnets += [PSCustomObject]@{
            SubscriptionId   = $subId
            SubscriptionName = $subName
            VNetName         = $vnet.Name
            ResourceGroup    = $vnet.ResourceGroupName
            AddressSpace     = ($vnet.AddressSpace.AddressPrefixes -join ", ")
            DnsServers       = ($vnet.DhcpOptions.DnsServers -join ", ")
            Subnets          = ($vnet.Subnets | ForEach-Object {
                                    $nsg = if ($_.NetworkSecurityGroup) { $_.NetworkSecurityGroup.Id.Split('/')[-1] } else { "" }
                                    $rt  = if ($_.RouteTable) { $_.RouteTable.Id.Split('/')[-1] } else { "" }
                                    $pfx = if ($_.AddressPrefix) { $_.AddressPrefix } else { ($_.AddressPrefixes -join ";") }
                                    "$($_.Name)|$pfx|$nsg|$rt"
                               }) -join "||"
            Tags             = if ($vnet.Tag -and $vnet.Tag.Count -gt 0) {
                                   ($vnet.Tag.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
                               } else { "" }
        }
    }

    # GN VNet'leri — tümü
    $gn = Get-AzVirtualNetwork | Where-Object { $_.Location -eq "germanynorth" }

    foreach ($vnet in $gn) {
        $gnVnets += [PSCustomObject]@{
            SubscriptionId   = $subId
            SubscriptionName = $subName
            VNetName         = $vnet.Name
            ResourceGroup    = $vnet.ResourceGroupName
            AddressSpace     = ($vnet.AddressSpace.AddressPrefixes -join ", ")
            DnsServers       = ($vnet.DhcpOptions.DnsServers -join ", ")
            Subnets          = ($vnet.Subnets | ForEach-Object {
                                    $nsg = if ($_.NetworkSecurityGroup) { $_.NetworkSecurityGroup.Id.Split('/')[-1] } else { "" }
                                    $rt  = if ($_.RouteTable) { $_.RouteTable.Id.Split('/')[-1] } else { "" }
                                    $pfx = if ($_.AddressPrefix) { $_.AddressPrefix } else { ($_.AddressPrefixes -join ";") }
                                    "$($_.Name)|$pfx|$nsg|$rt"
                               }) -join "||"
            Tags             = if ($vnet.Tag -and $vnet.Tag.Count -gt 0) {
                                   ($vnet.Tag.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
                               } else { "" }
        }
    }
}

# Export — iki ayrı CSV
$gwVnets | Export-Csv -Path "vnets_gwc.csv" -NoTypeInformation -Encoding UTF8
$gnVnets | Export-Csv -Path "vnets_gn.csv"  -NoTypeInformation -Encoding UTF8

Write-Host "`n=== GWC VNet Sayısı: $($gwVnets.Count) ===" -ForegroundColor Green
Write-Host "=== GN  VNet Sayısı: $($gnVnets.Count) ===" -ForegroundColor Yellow

# Fark — workload adı bazlı karşılaştır
function Get-VNetWorkload($name) {
    $name -replace '^vnet-isbankag-','' `
          -replace '-(prod|nonprod|dev|dr)$','' `
          -replace '-(gw|gn)$','' `
          -replace '-(prod|nonprod|dev|dr)$',''
}

$gnWorkloads = $gnVnets.VNetName | ForEach-Object { Get-VNetWorkload $_ }

$missing = $gwVnets | Where-Object {
    (Get-VNetWorkload $_.VNetName) -notin $gnWorkloads
}

Write-Host "`n=== GN'de Eksik VNet'ler ($($missing.Count) adet) ===" -ForegroundColor Red
$missing | Format-Table SubscriptionName, VNetName, AddressSpace -AutoSize
$missing | Export-Csv -Path "missing_vnets_gn.csv" -NoTypeInformation -Encoding UTF8