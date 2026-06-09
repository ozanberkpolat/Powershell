$endpoints = az network private-endpoint list --query "[?contains(privateLinkServiceConnections[0].privateLinkServiceId, 'bdrp') || contains(privateLinkServiceConnections[0].privateLinkServiceId, 'bdrp')].{name:name, nic:networkInterfaces[0].id}" --output json | ConvertFrom-Json

foreach ($ep in $endpoints) {
    $ip = az network nic show --ids $ep.nic --query "ipConfigurations[0].privateIPAddress" --output tsv
    Write-Host "$($ep.name) -> $ip"
}
