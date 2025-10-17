<#
.SYNOPSIS
    Find all "azdo*" App Registrations with active (non-expired) client secrets.

.DESCRIPTION
    This script connects to Microsoft Graph, retrieves all App Registrations
    whose DisplayName starts with "azdo" (case-insensitive),
    and checks if they have any active (non-expired) password credentials (client secrets).
    Expired secrets are ignored.
    The results are exported for further action (migration to federated credentials).
#>

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All"

# Current date/time for comparison
$now = Get-Date

# Retrieve all App Registrations
Write-Host "Retrieving App Registrations..."
$appRegistrations = Get-MgApplication -All

# Filter apps starting with "azdo" (case-insensitive) that have active secrets
$azdoAppsWithActiveSecrets = $appRegistrations | Where-Object {
    $_.DisplayName -match "^(?i)azdo" -and
    ($_.PasswordCredentials | Where-Object { $_.EndDateTime -gt $now }).Count -gt 0
}

# Show results in console
Write-Host "`n=== 'azdo*' App Registrations WITH Active Secrets ==="
$azdoAppsWithActiveSecrets | ForEach-Object {
    $activeSecrets = $_.PasswordCredentials | Where-Object { $_.EndDateTime -gt $now }
    foreach ($secret in $activeSecrets) {
        [PSCustomObject]@{
            Id           = $_.Id
            DisplayName  = $_.DisplayName
            SecretExpiry = $secret.EndDateTime
        }
    }
} | Format-Table -AutoSize

# Export results to CSV
$csvPath = "D:\OBP\Audit Results\AzdoApps-With-Active-Secrets.csv"
$azdoAppsWithActiveSecrets | ForEach-Object {
    $activeSecrets = $_.PasswordCredentials | Where-Object { $_.EndDateTime -gt $now }
    foreach ($secret in $activeSecrets) {
        [PSCustomObject]@{
            Id           = $_.Id
            DisplayName  = $_.DisplayName
            SecretExpiry = $secret.EndDateTime
        }
    }
} | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host "`nResults exported to $csvPath"
