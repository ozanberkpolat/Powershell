az login
$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
$subIds = (az account list --query "[].id" -o tsv)

$url = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"

$query = @"
recoveryservicesresources
| where type =~ 'microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems'
| extend rpoInSeconds = tolong(properties.providerSpecificDetails.rpoInSeconds)
| where isnotnull(rpoInSeconds) and rpoInSeconds > 600
| project
    subscriptionId,
    resourceGroup,
    vaultName = split(id, '/')[8],
    vmName = tostring(properties.friendlyName),
    rpoInSeconds
| order by rpoInSeconds desc

"@

$queryJson = @{ 
    subscriptions = $subIds
    query = $query 
} | ConvertTo-Json -Depth 10

$params = @{
    Method  = "Post"
    Uri     = $url
    Headers = @{ 
        "Authorization" = "Bearer $token" 
        "Content-Type"  = "application/json" 
    }
    Body    = $queryJson
}

$response = Invoke-RestMethod @params

if ($response.data) {
    $response.data | Format-Table -AutoSize
    
    $response | ConvertTo-Json -Depth 10
} else {
    Write-Host "`nSonuç dönmedi. Lütfen abonelik ID'lerini ve yetkileri kontrol edin." -ForegroundColor Yellow
}