# Connect to Azure
Connect-AzAccount

# List of subscription names
$subscriptions = @(
    "Subscription1",
    "Subscription2",
    "Subscription3"
)

foreach ($sub in $subscriptions) {
    # Construct group name using subscription name directly
    $groupName = "AGRP-ALL-LZ_${sub}_USR_Contributor"

    # Set the subscription context
    Set-AzContext -Subscription $sub

    # Get the group object ID
    $group = Get-AzADGroup -DisplayName $groupName
    if (-not $group) {
        Write-Warning "Group '$groupName' not found in subscription '$sub'"
        continue
    }

    # Assign Key Vault Administrator role at subscription scope
    New-AzRoleAssignment -ObjectId $group.Id `
                         -RoleDefinitionName "Key Vault Administrator" `
                         -Scope "/subscriptions/$((Get-AzContext).Subscription.Id)"
}