# Variables
$AppID = "APP-CLIENT-ID"  # Replace with your actual Application ID
$GroupName = "GROUP-NAME"
$GroupAlias = "GROUP-NAME-SecGrp"
$Description = "Grants access to mailbox@company.com"
$Mailboxes = @("mailbox@company.com")  # Add more as needed
 
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
$Identity = "test@company.com"
Test-ApplicationAccessPolicy -Identity $Identity -AppId $AppID 
Get-ApplicationAccessPolicy