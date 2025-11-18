# Install & import Graph modules if needed
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
Import-Module Microsoft.Graph.Applications

# Connect to Graph
Connect-MgGraph -Scopes "Application.ReadWrite.All"

# App Registration (Application) ID
$appId = "APP-ID-HERE"

# Get the application object
$app = Get-MgApplication -Filter "appId eq '$appId'"

# Define the new roles
$newRoles = @(
    @{
        id = [Guid]::NewGuid()
        allowedMemberTypes = @("User", "Application")
        description = "Allows read-only access to XYZ."
        displayName = "Test1"
        isEnabled = $true
        value = "Test1"
    },
    @{
        id = [Guid]::NewGuid()
        allowedMemberTypes = @("User", "Application")
        description = "Allows full access to XYZ."
        displayName = "Test2"
        isEnabled = $true
        value = "Test2"
    }
)

# Merge with existing roles
$updatedRoles = $app.AppRoles + $newRoles

# Update the application
Update-MgApplication -ApplicationId $app.Id -AppRoles $updatedRoles

Write-Host "Roles added successfully."
