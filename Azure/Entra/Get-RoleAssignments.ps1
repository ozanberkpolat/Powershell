Connect-AzAccount

# Define the user to check
$userEmail = "user@company.com"

# Output file path
$outputFile = "D:\OBP\export\UserRolesReportfor_$userEmail.csv"

# Initialize an array to hold the role assignments
$roleAssignments = @()

# Get all subscriptions
$subscriptions = Get-AzSubscription

foreach ($subscription in $subscriptions) {
    Write-Output "Processing Subscription: $($subscription.Name)"
    Set-AzContext -SubscriptionId $subscription.Id

    # Get all role assignments in the subscription
    $allRoleAssignments = Get-AzRoleAssignment

    # Filter role assignments for the specific user
    $userRoleAssignments = $allRoleAssignments | Where-Object { $_.SignInName -eq $userEmail }

    foreach ($roleAssignment in $userRoleAssignments) {
        # Retrieve the role definition based on the RoleDefinitionId
        $roleDefinition = Get-AzRoleDefinition | Where-Object { $_.Id -eq $roleAssignment.RoleDefinitionId }

        if ($roleDefinition) {
            # Get the scope (Subscription, Resource Group, or Resource level)
            $scope = $roleAssignment.Scope

            # Create a custom object to store the data
            $roleData = [PSCustomObject]@{
                SubscriptionName = $subscription.Name
                SubscriptionId   = $subscription.Id
                RoleName         = $roleDefinition.RoleName
                RoleDefinitionId = $roleDefinition.Id
                Scope            = $scope
                UserEmail        = $userEmail
            }

            # Add to the array
            $roleAssignments += $roleData
        } else {
            Write-Warning "Could not find role definition for RoleDefinitionId: $($roleAssignment.RoleDefinitionId)"
        }
    }
}

# Export the data to a CSV file
$roleAssignments | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

Write-Output "Role assignments have been exported to $outputFile"
