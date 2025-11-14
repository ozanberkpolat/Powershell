# Install Microsoft Graph module if not already installed
Install-Module Microsoft.Graph -Scope CurrentUser

# Connect to Graph
Connect-MgGraph -Scopes "Directory.Read.All","Group.Read.All","User.Read.All"

# Get all groups that have licenses assigned
$licensedGroups = Get-MgGroup -All -Filter "assignedLicenses/any()"

$results = @()

foreach ($group in $licensedGroups) {
    $groupLicenses = $group.AssignedLicenses

    foreach ($license in $groupLicenses) {
        # Get SKU details
        $sku = (Get-MgSubscribedSku | Where-Object { $_.SkuId -eq $license.SkuId })
        $skuName = if ($sku) { $sku.SkuPartNumber } else { $license.SkuId }

        # Get members of this group
        $members = Get-MgGroupMember -GroupId $group.Id -All -Property "Id,DisplayName,UserPrincipalName"

        foreach ($member in $members) {
            if ($member.'@odata.type' -eq '#microsoft.graph.user') {
                $results += [PSCustomObject]@{
                    GroupName          = $group.DisplayName
                    GroupId            = $group.Id
                    LicenseSkuId       = $license.SkuId
                    LicenseSkuName     = $skuName
                    UserDisplayName    = $member.DisplayName
                    UserPrincipalName  = $member.UserPrincipalName
                }
            }
        }
    }
}

# Export results
$results | Export-Csv "Group_Based_Licenses.csv" -NoTypeInformation
Write-Host "Export completed: Group_Based_Licenses.csv"
