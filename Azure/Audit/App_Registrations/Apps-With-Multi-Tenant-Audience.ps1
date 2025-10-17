<#
.SYNOPSIS
    Audit Azure AD App Registrations for multi-tenant configuration.

.DESCRIPTION
    This script connects to Microsoft Graph and retrieves all App Registrations
    in the tenant. It identifies applications configured as multi-tenant (or supporting
    accounts in other organizations), which is generally not allowed in tightly controlled environments.

.REQUIREMENTS
    - PowerShell 5.1+ or PowerShell Core 7+
    - Microsoft.Graph PowerShell SDK
    - Permissions: Application.Read.All, Directory.Read.All

.OUTPUTS
    CSV file containing:
        - App Name
        - App ID
        - Sign-In Audience (Supported Account Types)
#>

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All"

# Ensure output folder exists
$OutputFolder = "D:\OBP\Audit Results"
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

# Timestamp for output file
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OutputFile = Join-Path $OutputFolder "Apps_MultiTenant_$timestamp.csv"

# Get all applications including SignInAudience
# Possible values:
#   AzureADMyOrg          = Single tenant
#   AzureADMultipleOrgs   = Multi-tenant
#   AzureADandPersonalMicrosoftAccount = Multi-tenant + MSA
#   PersonalMicrosoftAccount = MSA only
$apps = Get-MgApplication -All -Property "id,displayName,appId,signInAudience"

$results = @()

foreach ($app in $apps) {
    if ($app.SignInAudience -ne "AzureADMyOrg") {
        $results += [PSCustomObject]@{
            AppName         = $app.DisplayName
            AppId           = $app.AppId
            SignInAudience  = $app.SignInAudience
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host "✅ No multi-tenant App Registrations found."
} else {
    Write-Host "⚠️ Multi-tenant App Registrations detected. Exporting to $OutputFile" -ForegroundColor Yellow
    $results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "📂 Export complete. File saved at: $OutputFile" -ForegroundColor Green
}
