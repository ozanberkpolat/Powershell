# Object ID of the Managed Identity's Service Principal
$ObjectId = "OBJECT-ID-HERE" # Replace with actual Object ID of the service principal

# Connect to Microsoft Graph
Connect-MgGraph -Scope "Application.Read.All AppRoleAssignment.ReadWrite.All"

# Get Microsoft Graph Service Principal
$graphSP = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Define the Graph API permissions to assign
$graphPermissions = @("User.Read.All", "Device.Read.All", "Group.Read.All")

# Assign each permission
foreach ($perm in $graphPermissions) {
    $role = $graphSP.AppRoles | Where-Object { $_.Value -eq $perm }
    if ($role) {
        $appRoleAssignment = @{
            principalId = $ObjectId
            resourceId  = $graphSP.Id
            appRoleId   = $role.Id
        }

        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ObjectId -BodyParameter $appRoleAssignment | Format-List
        Write-Host "✅ Assigned Graph permission: $perm"
    } else {
        Write-Warning "⚠️ Permission '$perm' not found in Graph AppRoles."
    }
}
