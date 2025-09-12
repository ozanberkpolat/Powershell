# Connect to Azure AD
Connect-AzureAD

# -----------------------------
# User-defined parameters
# -----------------------------
$SourceGroupName      = "RBAC-Snowflake-Dev-USC-DataEngineer"        # source group name
$DestinationGroupName = "RBAC-Snowflake-Test-USC-DataEngineer"   # destination group name
# -----------------------------

# Get source group ID by name
$sourceGroup = Get-AzureADGroup -Filter "DisplayName eq '$SourceGroupName'"
if (-not $sourceGroup) {
    Write-Error "❌ Source group '$SourceGroupName' not found."
    exit 1
}
$sourceGroupId = $sourceGroup.ObjectId
    
# Get destination group ID by name
$targetGroup = Get-AzureADGroup -Filter "DisplayName eq '$DestinationGroupName'"
if (-not $targetGroup) {
    Write-Error "❌ Destination group '$DestinationGroupName' not found."
    exit 1
}
$targetGroupId = $targetGroup.ObjectId

Write-Host "🔍 Copying members from '$SourceGroupName' to '$DestinationGroupName'..."

# Get members of source group
$members = Get-AzureADGroupMember -ObjectId $sourceGroupId | Where-Object { $_.ObjectType -eq 'User' }

$successCount = 0
$failCount = 0

# Add members to target group
foreach ($member in $members) {
    try {
        Add-AzureADGroupMember -ObjectId $targetGroupId -RefObjectId $member.ObjectId
        Write-Host "   ➡️ Added $($member.DisplayName)"
        $successCount++
    }
    catch {
        Write-Warning "⚠️ Failed to add $($member.DisplayName) : $_"
        $failCount++
    }
}

Write-Host "🎉 Done! Users copied: $successCount"
if ($failCount -gt 0) { Write-Host "⚠️ Users failed: $failCount" }
