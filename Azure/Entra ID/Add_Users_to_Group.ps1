Connect-MgGraph -Scopes "GroupMember.ReadWrite.All"

# Define the group ID
$groupId = "GROUP-OBJECT-ID"

# List of user emails
$userEmails = @(
    "Goksel.ATAKAN@gunvorgroup.com",
    "musa.yilmaz@gunvorgroup.com",
    "sidharth.mohan@freshworks.com",
    "ataberk.koleogullari@gunvorgroup.com",
    "Murat.DUMAN@gunvorgroup.com",
    "berkay.ozkan@gunvorgroup.com",
    "malek.iskandarani@gunvorgroup.com",
    "Ibrahim.TEPE@gunvorgroup.com",
    "Thierry.MASSON@gunvorgroup.com",
    "Serdar.CALIKOGLU@gunvorgroup.com",
    "Danish.Khan@gunvorgroup.com",
    "Mihhail.EBERLEIN@gunvorgroup.com",
    "Mark.DUPERRET@gunvorgroup.com",
    "zulal.mavi@gunvorgroup.com",
    "rasmus.saarepera@gunvorgroup.com",
    "julien.matray@gunvorgroup.com",
    "fouad.aabid@gunvorgroup.com",
    "gabriel.grigore@gunvorgroup.com",
    "vincenzo.mascaro@gunvorgroup.com",
    "ilker.avimelek@gunvorgroup.com"
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
