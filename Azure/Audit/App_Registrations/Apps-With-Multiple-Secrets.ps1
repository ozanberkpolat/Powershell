<#
.SYNOPSIS
    Audit Azure AD App Registrations for multiple secrets.

.DESCRIPTION
    This script connects to Microsoft Graph and retrieves all App Registrations
    in the tenant. It identifies apps that have more than one secret, and only
    includes those in the output. Expired secrets are ignored for details, but
    total secrets count considers all secrets.

.REQUIREMENTS
    - PowerShell 5.1+ or PowerShell Core 7+
    - Microsoft.Graph PowerShell SDK
    - Permissions: Application.Read.All, Directory.Read.All

.OUTPUTS
    CSV file containing:
        - App Name
        - App ID
        - Total Secrets
        - Active Secret Count
        - Secret Key IDs
        - Secret Start Dates
        - Secret End Dates
#>

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All","Directory.Read.All"

# Ensure output folder exists
$OutputFolder = "C:\OBP\Audit Results"
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

# Timestamp for output file
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OutputFile = Join-Path $OutputFolder "Apps_WithMultipleSecrets_$timestamp.csv"
$now = Get-Date

# Get all applications including PasswordCredentials
$apps = Get-MgApplication -All -Property "id,displayName,appId,passwordCredentials"

$results = @()

foreach ($app in $apps) {
    $totalSecrets = $app.PasswordCredentials.Count
    $activeSecrets = $app.PasswordCredentials | Where-Object { $_.EndDateTime -gt $now }

    # Only include apps with more than 1 total secret
    if ($totalSecrets -gt 1) {
        $results += [PSCustomObject]@{
            AppName            = $app.DisplayName
            AppId              = $app.AppId
            TotalSecrets       = $totalSecrets
            ActiveSecretCount  = $activeSecrets.Count
            SecretKeyIds       = ($activeSecrets | ForEach-Object { $_.KeyId } | ForEach-Object { $_.ToString() }) -join "; "
            SecretStartDates   = ($activeSecrets | ForEach-Object { $_.StartDateTime } | ForEach-Object { $_.ToString("yyyy-MM-dd") }) -join "; "
            SecretEndDates     = ($activeSecrets | ForEach-Object { $_.EndDateTime } | ForEach-Object { $_.ToString("yyyy-MM-dd") }) -join "; "
        }
    }
}

if ($results.Count -eq 0) {
    Write-Host "✅ No App Registrations with more than one secret found."
} else {
    Write-Host "⚠️ App Registrations with more than one secret found. Exporting to $OutputFile" -ForegroundColor Yellow
    $results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "📂 Export complete. File saved at: $OutputFile" -ForegroundColor Green
}
