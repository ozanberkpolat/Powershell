<#
.SYNOPSIS
    Audit SPA (Single Page Application) App Registrations for client secrets.

.DESCRIPTION
    This script connects to Microsoft Graph and retrieves all App Registrations
    in the tenant. It identifies apps configured as SPA (Single Page Application)
    and checks if they contain any **active** client secrets (PasswordCredentials).
    
    SPAs are public clients and should not have secrets assigned. 
    If any are found, they are flagged and exported.

    Expired secrets are ignored.

.REQUIREMENTS
    - PowerShell 5.1+ or PowerShell Core 7+
    - Microsoft.Graph PowerShell SDK
      Install with: Install-Module Microsoft.Graph -Scope CurrentUser
    - Permissions: Application.Read.All and Directory.Read.All

.OUTPUTS
    CSV file containing:
        - App Name
        - App ID
        - Created Date
        - Redirect URIs
        - Secret Key ID
        - Secret Start Date
        - Secret End Date

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

$OutputFile = Join-Path $OutputFolder "SPA_Apps_WithSecrets.csv"
$now = Get-Date

# Get all applications (include createdDateTime)
$apps = Get-MgApplication -All -Property "id,displayName,appId,createdDateTime,spa,passwordCredentials"

$results = @()

foreach ($app in $apps) {
    # Check if app is a SPA (has RedirectUris under spa property)
    if ($app.Spa -and $app.Spa.RedirectUris.Count -gt 0) {
        # Check if active secrets exist
        foreach ($secret in $app.PasswordCredentials) {
            if ($null -ne $secret.StartDateTime -and $null -ne $secret.EndDateTime) {
                if ($secret.EndDateTime -gt $now) {
                    $results += [PSCustomObject]@{
                        AppName      = $app.DisplayName
                        AppId        = $app.AppId
                        CreatedDate  = $app.CreatedDateTime
                        RedirectURIs = ($app.Spa.RedirectUris -join "; ")
                        SecretKeyId  = $secret.KeyId
                        StartDate    = $secret.StartDateTime
                        EndDate      = $secret.EndDateTime
                    }
                }
            }
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host "✅ No SPA applications with active secrets found."
} else {
    Write-Host "⚠️ SPA applications with active secrets found. Exporting to $OutputFile" -ForegroundColor Yellow
    $results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "📂 Export complete. File saved at: $OutputFile" -ForegroundColor Green
}
