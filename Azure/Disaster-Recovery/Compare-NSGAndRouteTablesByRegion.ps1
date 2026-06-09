$subscriptionIds = @(
    "d3a1c6d4-b44d-4763-811e-cb2ba1ef7f5b",
    "90992e51-523b-431a-92ce-76828ffb7957"
)

foreach ($subId in $subscriptionIds) {
    Set-AzContext -SubscriptionId $subId | Out-Null
    $subName = (Get-AzContext).Subscription.Name
    Write-Host "`n[$subName]" -ForegroundColor Cyan

    # NSG rule sayıları
    Get-AzNetworkSecurityGroup | Where-Object { $_.Location -eq "germanywestcentral" } | ForEach-Object {
        $customRules = ($_.SecurityRules | Where-Object { $_.Direction }).Count
        Write-Host "  NSG: $($_.Name) — $customRules custom rule" -ForegroundColor $(if ($customRules -gt 0) { "Yellow" } else { "Gray" })
    }

    # RT route sayıları
    Get-AzRouteTable | Where-Object { $_.Location -eq "germanywestcentral" } | ForEach-Object {
        $routes = $_.Routes.Count
        Write-Host "  RT:  $($_.Name) — $routes route" -ForegroundColor $(if ($routes -gt 0) { "Yellow" } else { "Gray" })
    }
}