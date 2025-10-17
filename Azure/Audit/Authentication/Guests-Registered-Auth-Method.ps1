<#
.SYNOPSIS
    Tenant-wide audit of guest users with their authentication methods and sign-in activity.

.DESCRIPTION
    Retrieves all guest users in the tenant.
    For each guest:
        - DisplayName
        - UPN
        - Account status
        - Last interactive sign-in
        - Registered authentication methods
        - A flag showing if Microsoft Authenticator is registered

.NOTES
    Requires Microsoft Graph PowerShell module and permissions:
        - UserAuthenticationMethod.Read.All
        - User.Read.All
        - AuditLog.Read.All
#>

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All","AuditLog.Read.All"
Select-MgProfile -Name "beta"

# Get all guest users
$guests = Get-MgUser -Filter "userType eq 'Guest'" -All -Property DisplayName,UserPrincipalName,AccountEnabled,SignInActivity

$guestReport = @()

foreach ($guest in $guests) {
    try {
        # Get authentication methods
        $methods = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$($guest.Id)/authentication/methods"

        # Determine if Microsoft Authenticator is present
        $hasAuthenticator = $false
        foreach ($method in $methods.value) {
            if ($method.'@odata.type' -eq "#microsoft.graph.microsoftAuthenticatorAuthenticationMethod" -and $method.displayName) {
                $hasAuthenticator = $true
                break
            }
        }

        if ($methods.value) {
            foreach ($method in $methods.value) {
                $methodType = ($method.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","")
                $deviceInfo = if ($method.displayName) { $method.displayName } else { "N/A" }
                $createdDate = if ($method.createdDateTime) { $method.createdDateTime } else { "N/A" }

                $guestReport += [PSCustomObject]@{
                    DisplayName             = $guest.DisplayName
                    UserPrincipalName       = $guest.UserPrincipalName
                    AccountEnabled          = if ($guest.AccountEnabled) { "Enabled" } else { "Disabled" }
                    LastSignIn              = $guest.SignInActivity.LastSignInDateTime
                    Method                  = $methodType
                    Device                  = $deviceInfo
                    CreatedDate             = $createdDate
                    HasMicrosoftAuthenticator = if ($hasAuthenticator) { "Yes" } else { "No" }
                }
            }
        }
        else {
            # If no methods found, still add row
            $guestReport += [PSCustomObject]@{
                DisplayName             = $guest.DisplayName
                UserPrincipalName       = $guest.UserPrincipalName
                AccountEnabled          = if ($guest.AccountEnabled) { "Enabled" } else { "Disabled" }
                LastSignIn              = $guest.SignInActivity.LastSignInDateTime
                Method                  = "None"
                Device                  = "N/A"
                CreatedDate             = "N/A"
                HasMicrosoftAuthenticator = "No"
            }
        }
    }
    catch {
        Write-Warning "Failed to fetch auth methods for $($guest.UserPrincipalName): $_"
    }
}

# Export CSV with date
$date = Get-Date -Format "yyyyMMdd"
$outFile = "D:\OBP\Audit Results\GuestAudit_WithAuthFlag_$date.csv"
$guestReport | Export-Csv -Path $outFile -NoTypeInformation -Force -Encoding UTF8

Write-Host "✅ Guest audit with Microsoft Authenticator flag exported to $outFile"
