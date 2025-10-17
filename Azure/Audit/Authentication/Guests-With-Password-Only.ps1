<#
.SYNOPSIS
    Checks guest users for weak authentication: password-only accounts.
.DESCRIPTION
    Loops through all guest users, fetches registered authentication methods via Graph,
    and flags users who only have password and no MFA / passwordless methods.
#>

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "UserAuthenticationMethod.Read.All","User.Read.All"

# Get all guest users
$guests = Get-MgUser -Filter "userType eq 'Guest'" -All

$report = @()

foreach ($guest in $guests) {
    try {
        $objectId = $guest.Id
        $methods = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$objectId/authentication/methods"

        # Extract method types
        $methodTypes = @()
        foreach ($method in $methods.value) {
            $type = ($method.'@odata.type' -replace "#microsoft.graph.","" -replace "AuthenticationMethod","")
            $methodTypes += $type
        }

        # Determine if password-only
        $isPasswordOnly = $false
        if ($methodTypes -contains "Password" -and ($methodTypes.Count -eq 1)) {
            $isPasswordOnly = $true
        }

        $report += [PSCustomObject]@{
            DisplayName       = $guest.DisplayName
            UserPrincipalName = $guest.UserPrincipalName
            RegisteredMethods = if ($methodTypes) { $methodTypes -join ", " } else { "None" }
            PasswordOnly      = $isPasswordOnly
        }

    } catch {
        Write-Warning "Failed to fetch auth methods for $($guest.UserPrincipalName): $_"
    }
}

# Export CSV
$date = Get-Date -Format "yyyyMMdd"
$outFile = "D:\OBP\Audit Results\GuestPasswordOnlyReport_$date.csv"
$report | Export-Csv -Path $outFile -NoTypeInformation -Force

Write-Host "✅ Password-only guest report exported to $outFile"
