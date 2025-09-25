<#
.SYNOPSIS
    Tenant-wide audit of registered authentication methods for guest users.

.DESCRIPTION
    Retrieves all guest users in the tenant, resolves their object ID from UPN,
    queries registered authentication methods using Invoke-MgGraphRequest,
    and exports a CSV with DisplayName, UPN, Method, Device, and CreatedDate.

.NOTES
    Requires Microsoft Graph PowerShell module and permission:
    - UserAuthenticationMethod.Read.All
    - User.Read.All
#>

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All"

# Get all guest users
$guests = Get-MgUser -Filter "userType eq 'Guest'" -All

$guestReport = @()

foreach ($guest in $guests) {

    try {
        # Resolve Object ID from UPN
        $objectId = $guest.Id

        # Get authentication methods
        $methods = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$objectId/authentication/methods"

        foreach ($method in $methods.value) {
            $methodType = ($method.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","")
            $deviceInfo = if ($method.displayName) { $method.displayName } else { "N/A" }
            $createdDate = if ($method.createdDateTime) { $method.createdDateTime } else { "N/A" }

            $guestReport += [PSCustomObject]@{
                DisplayName       = $guest.DisplayName
                UserPrincipalName = $guest.UserPrincipalName
                Method            = $methodType
                Device            = $deviceInfo
                CreatedDate       = $createdDate
            }
        }

        # If no methods found, still add row
        if (-not $methods.value) {
            $guestReport += [PSCustomObject]@{
                DisplayName       = $guest.DisplayName
                UserPrincipalName = $guest.UserPrincipalName
                Method            = "None"
                Device            = "N/A"
                CreatedDate       = "N/A"
            }
        }

    } catch {
        Write-Warning "Failed to fetch auth methods for $($guest.UserPrincipalName): $_"
    }
}

# Export CSV with date
$date = Get-Date -Format "yyyyMMdd"
$outFile = "D:\OBP\Audit Results\GuestRegisteredAuthMethods_$date.csv"
$guestReport | Export-Csv -Path $outFile -NoTypeInformation -Force

Write-Host "✅ Guest registered auth methods report exported to $outFile"
