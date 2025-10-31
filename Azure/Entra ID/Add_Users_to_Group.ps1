Connect-MgGraph -Scopes "GroupMember.ReadWrite.All"

# Define the group ID
$groupId = "GROUP-OBJECT-ID"

# List of user emails
$userEmails = @(
    "user1@company.com",
    "user2@company.com",
    "user3@company.com"
)


# Loop through each email and add to group
foreach ($email in $userEmails) {
    $user = Get-MgUser -Filter "mail eq '$email'"
    if ($user) {
        try {
            New-MgGroupMember -GroupId $groupId -DirectoryObjectId $user.Id
            Write-Host "✅ Added $email to group."
        } catch {
            Write-Host "❌ Failed to add $email : $_"
        }
    } else {
        Write-Host "⚠️ User not found: $email"
    }
}
