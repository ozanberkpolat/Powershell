# Variables
$AppID = "f0468c66-1847-4f52-958b-d3609ba5e9e5"  # Replace with your actual Application ID
$GroupName = "AGRP-ALL-AppAccPolicy-CLMTestUS"
$GroupAlias = "CLMTestUS-SecGrp"
$Description = "grants access to clm-hou-test@gunvorgroup.com"
$Mailboxes = @("clm-hou-test@gunvorgroup.com")  # Add more as needed
 
# Connect to Exchange Online (if not already connected)
Connect-ExchangeOnline
 
# Step 1: Create a Mail-Enabled Security Group
$group = New-DistributionGroup -Name $GroupName -DisplayName $GroupName -Alias $GroupAlias -Type Security -PrimarySmtpAddress "$GroupAlias@gunvorgroup.com" -Members $null
 
# Step 2: Add Mailboxes to the group
foreach ($mailbox in $Mailboxes) {Add-DistributionGroupMember -Identity $group.Identity -Member $mailbox}
 
# Step 3: Get the Group ID for the Application Access Policy
$PolicyScopeGroupId = (Get-DistributionGroup $group.Identity).ExternalDirectoryObjectId
 
# Step 4: Create the Application Access Policy
New-ApplicationAccessPolicy -AppId $AppID -PolicyScopeGroupId $PolicyScopeGroupId -AccessRight RestrictAccess -Description $Description
 
 
# Step 5: TEST
$Identity = "clm-hou-test@gunvorgroup.com"  # Replace with the identity you want to test
$Identity2 = "ozan.polat@gunvorgroup.com"  # Replace with another identity to test
Test-ApplicationAccessPolicy -Identity $Identity -AppId $AppID
Test-ApplicationAccessPolicy -Identity $Identity2 -AppId $AppID 
Get-ApplicationAccessPolicy