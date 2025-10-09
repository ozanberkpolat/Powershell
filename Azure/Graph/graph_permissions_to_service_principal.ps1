# Connect to Microsoft Graph with sufficient privileges
# (You need to be a Global Admin or Privileged Role Admin)
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

# Variables
$UamiObjectId = "0d46e530-cf50-4a22-8c45-04d141a2ba8f"  # Service Principal ObjectId of your UAMI
$GraphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Desired Microsoft Graph application roles
$RequiredPermissions = @(
    "User.Read.All",
    "Application.Read.All",
    "Group.Read.All"
)

# Get the app role IDs for the required permissions
$AppRoles = $GraphSp.AppRoles | Where-Object {
    $_.Value -in $RequiredPermissions -and $_.AllowedMemberTypes -contains "Application"
}

foreach ($AppRole in $AppRoles) {
    Write-Output "Assigning $($AppRole.Value) to UAMI $UamiObjectId"
    
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $UamiObjectId `
        -PrincipalId $UamiObjectId `
        -ResourceId $GraphSp.Id `
        -AppRoleId $AppRole.Id
}

Write-Output "✅ Finished assigning Graph API application permissions."
