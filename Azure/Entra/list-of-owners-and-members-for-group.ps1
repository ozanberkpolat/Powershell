# Connect to Azure AD using Microsoft Graph
Connect-MgGraph -Scopes "Group.Read.All", "User.Read.All", "Directory.Read.All"

$allGroups = Get-MgGroup -All
$groups = $allGroups | Where-Object { $_.DisplayName -like "AGRP-ALL-PBI*" }

# Loop through each group and retrieve the owners and members
$groupData = foreach ($group in $groups) {
    # Get the owners for each group using Get-MgGroupOwner
    $owners = Get-MgGroupOwner -GroupId $group.Id -All
    
    # Get the DisplayName for each owner by using their User ID
    $ownerNames = foreach ($owner in $owners) {
        try {
            $user = Get-MgUser -UserId $owner.Id
            $user.DisplayName
        } catch {
            Write-Warning "Owner with ID $($owner.Id) not found or is not a user."
            $null
        }
    }

    # Get the members of the group (including owners and other members), with proper paging handling
    $members = Get-MgGroupMember -GroupId $group.Id -All

    # Fetch the DisplayName for each member using Get-MgDirectoryObject (general query)
    $memberNames = foreach ($member in $members) {
        try {
            # Use Get-MgDirectoryObject to fetch any directory object by its ID (user or group)
            $directoryObject = (Get-MgDirectoryObject -DirectoryObjectId $member.Id).AdditionalProperties

            # Check if the object has a DisplayName property (users and groups have this)
            if ($directoryObject.displayName) {
                $directoryObject.displayName
            } else {
                Write-Warning "No DisplayName found for member with ID $($member.Id)."
                $null
            }
        } catch {
            Write-Warning "Object with ID $($member.Id) not found or could not be fetched."
            $null
        }
    }

    # Join the owner and member names into single strings
    $ownerString = if ($ownerNames) { $ownerNames -join ", " } else { "No owners found" }
    $memberString = if ($memberNames) { $memberNames -join ", " } else { "No members found" }

    # Prepare the result object with group name, group id, owners, and members
    [PSCustomObject]@{
        GroupDisplayName = $group.DisplayName
        GroupId          = $group.Id
        Owners           = $ownerString
        Members          = $memberString
    }
}

# Output the result in a GridView format
$groupData | Out-GridView
