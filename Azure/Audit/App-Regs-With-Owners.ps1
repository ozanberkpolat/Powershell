<#
.SYNOPSIS
    Audit Azure AD App Registrations and list their owners.

.DESCRIPTION
    This script connects to Microsoft Graph and retrieves all App Registrations
    in the tenant. For each application, it enumerates the assigned owners and 
    exports the details to a CSV.

    The script identifies whether an owner is:
        - A User
        - A Service Principal
        - An unknown type (rare case)

    If an application has no owners, it will be flagged accordingly.

.REQUIREMENTS
    - PowerShell 5.1+ or PowerShell Core 7+
    - Microsoft.Graph PowerShell SDK
      Install with: Install-Module Microsoft.Graph -Scope CurrentUser
    - Permissions: Application.Read.All, Directory.Read.All, User.Read.All

.OUTPUTS
    CSV file saved in:
        D:\OBP\Audit Results\AppRegistrationsWithOwners_<timestamp>.csv

    Columns include:
        - AppDisplayName
        - AppId
        - CreatedDateTime
        - OwnerDisplayName
        - OwnerUserPrincipalName (UPN for users, AppId for SPs)
        - OwnerType

.NOTES
    Author: OBP + ChatGPT
    Date:   2025-08-29
#>

# Connect to Microsoft Graph with required scopes
Import-Module Microsoft.Graph.Applications -Force
Connect-MgGraph -Scopes "Application.Read.All", "Directory.Read.All", "User.Read.All"

# Get all App Registrations with createdDateTime included
$appRegs = Get-MgApplication -All -Property "id,displayName,appId,createdDateTime"
$result = @()

foreach ($app in $appRegs) {
    $owners = Get-MgApplicationOwner -ApplicationId $app.Id

    if ($owners.Count -gt 0) {
        foreach ($owner in $owners) {
            $ownerType = $owner.AdditionalProperties.'@odata.type'

            if ($ownerType -eq "#microsoft.graph.user") {
                $user = Get-MgUser -UserId $owner.Id
                $result += [PSCustomObject]@{
                    AppDisplayName         = $app.DisplayName
                    AppId                  = $app.AppId
                    CreatedDateTime        = $app.CreatedDateTime
                    OwnerDisplayName       = $user.DisplayName
                    OwnerUserPrincipalName = $user.UserPrincipalName
                    OwnerType              = "User"
                }
            }
            elseif ($ownerType -eq "#microsoft.graph.servicePrincipal") {
                $sp = Get-MgServicePrincipal -ServicePrincipalId $owner.Id
                $result += [PSCustomObject]@{
                    AppDisplayName         = $app.DisplayName
                    AppId                  = $app.AppId
                    CreatedDateTime        = $app.CreatedDateTime
                    OwnerDisplayName       = $sp.DisplayName
                    OwnerUserPrincipalName = $sp.AppId
                    OwnerType              = "ServicePrincipal"
                }
            }
            else {
                $result += [PSCustomObject]@{
                    AppDisplayName         = $app.DisplayName
                    AppId                  = $app.AppId
                    CreatedDateTime        = $app.CreatedDateTime
                    OwnerDisplayName       = "<Unknown Type>"
                    OwnerUserPrincipalName = $owner.Id
                    OwnerType              = $ownerType
                }
            }
        }
    }
    else {
        $result += [PSCustomObject]@{
            AppDisplayName         = $app.DisplayName
            AppId                  = $app.AppId
            CreatedDateTime        = $app.CreatedDateTime
            OwnerDisplayName       = "<No Owner>"
            OwnerUserPrincipalName = "<No Owner>"
            OwnerType              = "-"
        }
    }
}

# Export results with timestamped filename
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputPath = "D:\OBP\Audit Results\AppRegistrationsWithOwners_$timestamp.csv"
$result | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
Write-Host "Exported to $outputPath"
