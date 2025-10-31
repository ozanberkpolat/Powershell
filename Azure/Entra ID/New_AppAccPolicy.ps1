# Variables
$AppID = ""  # Replace with your actual Application ID
$GroupName = "AGRP-ALL-AppAccPolicy-" # AGRP-ALL-AppAccPolicy-APP_REGISTRATION_NAME
$GroupAlias = "-SecGrp" # APP_REGISTRATION_NAME-SecGrp
$Description = "grants Mail.Send access to Barge-vetting-test@company.com" # Description for the Application Access Policy
$Mailboxes = @("Barge-vetting-test@company.com")  # List of mailboxes to include in the policy group

# Connect to Exchange Online (if not already connected)
Connect-ExchangeOnline
 
# Step 1: Create a Mail-Enabled Security Group
New-DistributionGroup -Name $GroupName -DisplayName $GroupName -Alias $GroupAlias -Type Security -PrimarySmtpAddress "$GroupAlias@company.com" -Members $null
 
# Step 2: Add Mailboxes to the group
foreach ($mailbox in $Mailboxes) {Add-DistributionGroupMember -Identity $GroupName -Member $mailbox}
 
# Step 3: Get the Group ID for the Application Access Policy
$PolicyScopeGroupId = (Get-DistributionGroup $GroupName).ExternalDirectoryObjectId
 
# Step 4: Create the Application Access Policy
New-ApplicationAccessPolicy -AppId $AppID -PolicyScopeGroupId $PolicyScopeGroupId -AccessRight RestrictAccess -Description $Description
 
 
# Step 5: TEST
$Identity = "Barge-vetting-test@company.com"  # Replace with the identity you want to test
$Identity2 = "ozan.polat@company.com"  # Replace with another identity to test
Test-ApplicationAccessPolicy -Identity $Identity -AppId $AppID
Test-ApplicationAccessPolicy -Identity $Identity2 -AppId $AppID 