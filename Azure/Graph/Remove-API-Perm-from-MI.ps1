# Input variables 

$managedIdentityName = "ManagedIdentityName" # Replace with your actual Managed Identity name

$permissionsToRemove = @( 

    "Policy.Read.ConditionalAccess", 

    "RoleEligibilitySchedule.Read.Directory", 

    "DeviceManagementManagedDevices.Read.All", 

    "UserAuthenticationMethod.Read.All", 

    "SharePointTenantSettings.Read.All", 

    "PrivilegedAccess.Read.AzureAD", 

    "SecurityIdentitiesHealth.Read.All", 

    "DirectoryRecommendations.Read.All", 

    "RoleManagement.Read.All", 

    "SecurityIdentitiesSensors.Read.All", 

    "DeviceManagementConfiguration.Read.All", 

    "IdentityRiskEvent.Read.All", 

    "Policy.Read.All", 

    "Reports.Read.All"# Add more permissions to remove 

) 

Import-Module Microsoft.Graph.Applications 

# Connect to Graph 

Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All", "Directory.ReadWrite.All" 

  

# Get the Managed Identity (Enterprise Application) 

$miApp = Get-MgServicePrincipal -Filter "displayName eq '$managedIdentityName'" 

if (-not $miApp) { throw "Managed Identity not found" } 

  

# Get current App Role Assignments 

$appRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miApp.Id 

  

foreach ($assignment in $appRoleAssignments) { 

    # Get the API (resource) providing the role (e.g., Microsoft Graph) 

    $resourceSp = Get-MgServicePrincipal -ServicePrincipalId $assignment.ResourceId 

  

    foreach ($roleName in $permissionsToRemove) { 

        $matchedRole = $resourceSp.AppRoles | Where-Object { $_.Id -eq $assignment.AppRoleId -and $_.Value -eq $roleName } 

        if ($matchedRole) { 

            Write-Host "Revoking '$roleName' from $($resourceSp.DisplayName)..." 

            Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miApp.Id -AppRoleAssignmentId $assignment.Id 

        } 

    } 

} 

Disconnect-MgGraph 

 