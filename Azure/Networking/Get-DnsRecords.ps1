$hubVnetName = "vnet-isbankag-hub-gw"
$subscriptions = Get-AzSubscription
$results = @()

foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    $zones = Get-AzPrivateDnsZone
    foreach ($zone in $zones) {
        $links = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name
        $linkedToHub = $links | Where-Object { $_.VirtualNetworkId -like "*/$hubVnetName" }
        if (-not $linkedToHub) {
            $recordSets = Get-AzPrivateDnsRecordSet -ResourceGroupName $zone.ResourceGroupName -ZoneName $zone.Name
            foreach ($rs in $recordSets) {
                $results += [PSCustomObject]@{
                    Subscription  = $sub.Name
                    ResourceGroup = $zone.ResourceGroupName
                    Zone          = $zone.Name
                    RecordSetName = $rs.Name
                    RecordType    = $rs.RecordType
                    TTL           = $rs.Ttl
                    Records       = ($rs.Records | ConvertTo-Json -Compress)
                }
            }
        }
    }
}

$results | Export-Csv -Path ".\unlinked-dns-records.csv" -NoTypeInformation -Encoding UTF8
Write-Host "$($results.Count) kayıt bulundu ve unlinked-dns-records.csv'ye kaydedildi."