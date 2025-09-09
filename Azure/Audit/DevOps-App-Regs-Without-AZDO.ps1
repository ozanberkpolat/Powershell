<#
.SYNOPSIS
    Find all App Registrations with specific text in Internal Notes
    but exclude those starting with "azdo" (case-insensitive)

.DESCRIPTION
    This script connects to Microsoft Graph, retrieves all App Registrations,
    and filters those where:
      - Notes (Internal Notes) contain "Managed by Azure DevOps"
      - DisplayName does NOT start with "azdo" (ignores case)
#>

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Application.Read.All"

# Retrieve all App Registrations
Write-Host "Retrieving App Registrations..."
$appRegistrations = Get-MgApplication -All

# Filter by Notes and exclude DisplayNames starting with "azdo" (case-insensitive)
$filteredApps = $appRegistrations | Where-Object {
    ($_.Notes -like "*Managed by Azure DevOps*") -and
    ($_.DisplayName -notmatch "^(?i)azdo")   # case-insensitive regex
}

# Show results in console
Write-Host "`n=== Matching App Registrations (excluding 'azdo*') ==="
$filteredApps | Select-Object Id, DisplayName, Notes | Format-Table -AutoSize

# Show results
$filteredApps | Select-Object Id, DisplayName, Notes | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
