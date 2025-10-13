Connect-MgGraph

# Define your tenant ID
$tenantID = "TENANT_ID_HERE"

# List of roles to query
$roles = @(
"Application Administrator",
"Attribute Assignment Administrator",
"Attribute Definition Administrator",
"Authentication Administrator",
"Authentication Policy Administrator",
"Azure DevOps Administrator",
"Azure Information Protection Administrator",
"Billing Administrator",
"Cloud Application Administrator",
"Cloud Device Administrator",
"Compliance Administrator",
"Conditional Access Administrator",
"Customer LockBox Access Approver",
"Desktop Analytics Administrator",
"Directory Readers",
"Directory Synchronization Accounts",
"Exchange Administrator",
"Exchange Recipient Administrator",
"External Identity Provider Administrator",
"Fabric Administrator",
"Global Administrator",
"Global Reader",
"Groups Administrator",
"Guest Inviter",
"Helpdesk Administrator",
"Hybrid Identity Administrator",
"Identity Governance Administrator",
"Intune Administrator",
"License Administrator",
"Lifecycle Workflows Administrator",
"Message Center Reader",
"Network Administrator",
"Office Apps Administrator",
"Password Administrator",
"Power Platform Administrator",
"Privileged Authentication Administrator",
"Privileged Role Administrator",
"Reports Reader",
"Security Administrator",
"Security Operator",
"Security Reader",
"Service Support Administrator",
"SharePoint Administrator",
"SignIn Report Readers",
"Teams Administrator",
"Teams Devices Administrator",
"Teams Telephony Administrator",
"User Administrator",
"Windows 365 Administrator"
)

# Collect activation duration data
$roleDurations = @()

foreach ($role in $roles) {
    try {
        $policy = Get-PIMEntraRolePolicy -TenantID $tenantID -RoleName $role -ErrorAction Stop
        $roleDurations += [PSCustomObject]@{
            RoleName              = $role
            ActivationDuration    = $policy.ActivationDuration
        }
    } catch {
        Write-Warning "No policy found or failed to retrieve: $role"
    }
}

# Display sorted output
$roleDurations | Sort-Object RoleName | Format-Table -AutoSize

# Optional export
$roleDurations | Export-Csv -Path "D:\OBP\Audit Results\PIM_RoleActivationDurations.csv" -NoTypeInformation
