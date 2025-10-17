<#
.SYNOPSIS
    Audit Azure AD App Registrations for long-lived secrets/certificates.

.DESCRIPTION
    This script connects to Microsoft Graph and retrieves all App Registrations
    in the tenant. It checks each application's client secrets (PasswordCredentials) 
    and certificates (KeyCredentials) to identify any credentials with a lifetime 
    longer than 24 months (730 days).

    - Expired credentials are ignored (only active credentials are reported).
    - Results are exported to a CSV file in: D:\OBP\Audit Results\LongLivedCredentials.csv

.REQUIREMENTS
    - PowerShell 5.1+ or PowerShell Core 7+
    - Microsoft.Graph PowerShell SDK
      Install with: Install-Module Microsoft.Graph -Scope CurrentUser
    - Permissions: Application.Read.All and Directory.Read.All

.OUTPUTS
    CSV file containing:
        - App Name
        - App ID
        - Credential Type (Client Secret / Certificate)
        - Key ID
        - Start Date
        - End Date
        - Lifetime in Days

.NOTES
    Author: OBP + ChatGPT
    Date:   2025-08-29
#>

# Connect to Microsoft Graph with required permissions
Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All"

# Ensure output folder exists
$OutputFolder = "D:\OBP\Audit Results"
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$OutputFile = Join-Path $OutputFolder "LongLivedCredentials.csv"
$now = Get-Date

# Get all applications
$apps = Get-MgApplication -All

$results = @()

foreach ($app in $apps) {
    # Client Secrets
    foreach ($secret in $app.PasswordCredentials) {
        if ($null -ne $secret.StartDateTime -and $null -ne $secret.EndDateTime) {
            $lifetimeDays = ($secret.EndDateTime - $secret.StartDateTime).Days
            if ($lifetimeDays -gt 730 -and $secret.EndDateTime -gt $now) {
                $results += [PSCustomObject]@{
                    AppName        = $app.DisplayName
                    AppId          = $app.AppId
                    CredentialType = "Client Secret"
                    KeyId          = $secret.KeyId
                    StartDate      = $secret.StartDateTime
                    EndDate        = $secret.EndDateTime
                    LifetimeDays   = $lifetimeDays
                }
            }
        }
    }

    # Certificates
    foreach ($cert in $app.KeyCredentials) {
        if ($null -ne $cert.StartDateTime -and $null -ne $cert.EndDateTime) {
            $lifetimeDays = ($cert.EndDateTime - $cert.StartDateTime).Days
            if ($lifetimeDays -gt 730 -and $cert.EndDateTime -gt $now) {
                $results += [PSCustomObject]@{
                    AppName        = $app.DisplayName
                    AppId          = $app.AppId
                    CredentialType = "Certificate"
                    KeyId          = $cert.KeyId
                    StartDate      = $cert.StartDateTime
                    EndDate        = $cert.EndDateTime
                    LifetimeDays   = $lifetimeDays
                }
            }
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host "✅ No active credentials with lifetime greater than 2 years found."
} else {
    Write-Host "⚠️ Active credentials with lifetime greater than 2 years found. Exporting to $OutputFile" -ForegroundColor Yellow
    $results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "📂 Export complete. File saved at: $OutputFile" -ForegroundColor Green
}
