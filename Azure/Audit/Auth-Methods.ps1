<#
.SYNOPSIS
Generates a tenant-wide Authentication Methods Policy report from Microsoft Entra (via Graph API).
The report includes:
- Authentication method name
- Enabled/disabled status
- IncludeTargets resolved to display names
- Policy version and last modified date
- Registration enforcement details
- Security level (based on Microsoft best practices)

The report is exported to a CSV file with today’s date in the filename.
#>

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Policy.Read.AuthenticationMethod","User.Read.All","Group.Read.All"

# Get tenant-wide authentication methods policy
$policy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy"

$methodsReport = @()

# Security level mapping
$securityMap = @{
    "fido2"                                 = "High"
    "passwordlessmicrosoftauthenticator"    = "High"
    "windowshelloforbusiness"               = "High"
    "x509certificate"                       = "High"
    "temporaryaccesspass"                   = "High"
    "microsoftauthenticator"                = "High"
    "softwareoath"                          = "Medium"
    "hardwareoath"                          = "Medium"
    "sms"                                   = "Low"
    "voice"                                 = "Low"
    "email"                                 = "Low"
    "password"                              = "Low"
}

function To-Bool($v) {
    if ($null -eq $v) { return $false }
    if ($v -is [bool]) { return $v }
    $s = ([string]$v).ToLowerInvariant()
    return ($s -in @("true","1","enabled","yes"))
}

foreach ($method in $policy.authenticationMethodConfigurations) {
    # Normalize method name
    $rawType = $method."@odata.type"
    $methodName = if ($rawType) { ($rawType -replace "#microsoft.graph.","" -replace "AuthenticationMethodConfiguration","") } else { "<unknown>" }

    # Determine enabled status
    $isEnabled = $null
    if ($null -ne $method.isEnabled) { $isEnabled = $method.isEnabled }
    elseif ($null -ne $method.state) { $isEnabled = $method.state }
    elseif ($null -ne $method.enabled) { $isEnabled = $method.enabled }
    $isEnabledBool = To-Bool $isEnabled

    # Resolve targets
    $targets = $null
    if ($method.includeTargets) {
        $targetNames = @()
        foreach ($t in $method.includeTargets) {
            $id = $null
            if ($t -is [string]) { $id = $t }
            elseif ($t.id) { $id = $t.id }
            elseif ($t.target) { $id = $t.target }

            if ($id) {
                try {
                    $group = Get-MgGroup -GroupId $id -ErrorAction SilentlyContinue
                    if ($group) { $targetNames += $group.DisplayName; continue }
                    $user = Get-MgUser -UserId $id -ErrorAction SilentlyContinue
                    if ($user) { $targetNames += $user.DisplayName; continue }
                    $targetNames += $id
                } catch {
                    $targetNames += $id
                }
            }
        }
        $targets = $targetNames -join "; "
    }

    # Security Level
    $securityLevel = $securityMap[$methodName]
    if (-not $securityLevel) { $securityLevel = "Unknown" }

    $methodsReport += [PSCustomObject]@{
        MethodName           = $methodName
        IsEnabled            = $isEnabledBool
        IncludeTargets       = $targets
        SecurityLevel        = $securityLevel
    }
}

# Add date to filename
$date = Get-Date -Format "yyyyMMdd"
$outFile = "D:\OBP\Audit Results\TenantAuthMethodsFullPolicy_$date.csv"

# Export CSV
$methodsReport | Export-Csv $outFile -NoTypeInformation -Force

Write-Host "Report generated: $outFile"
