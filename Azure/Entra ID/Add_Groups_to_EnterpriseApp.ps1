# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Directory.ReadWrite.All", "Application.ReadWrite.All"

# Define the Service Principal (Enterprise App) objectId
$enterpriseAppId = "OBJECT-ID-OF-ENTERPRISE-APP" # Replace with your actual Enterprise App Object ID

# Default role ID when no app roles exist (used by Azure implicitly)
$defaultAppRoleId = "18d14569-c3bd-439b-9a66-3a2aee01d14f"

# List of group display names
$groupNames = @("GROUP-NAME-1", "GROUP-NAME-2", "GROUP-NAME-3") # Replace with your actual group names

foreach ($groupName in $groupNames) {
    # Find group by display name
    $group = Get-MgGroup -Filter "displayName eq '$groupName'"

    if ($group) {
        try {
            New-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $enterpriseAppId `
                -PrincipalId $group.Id `
                -ResourceId $enterpriseAppId `
                -AppRoleId $defaultAppRoleId

            Write-Host "✔ Assigned '$groupName' to enterprise app with default access."
        }
        catch {
            Write-Warning "✖ Failed to assign '$groupName': $_"
        }
    }
    else {
        Write-Warning "⚠ Group '$groupName' not found."
    }
}
