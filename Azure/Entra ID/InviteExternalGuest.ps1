# Connect to Azure AD
Connect-AzureAD 

# Variables for guest user information
$emailAddress = "external@company.com" # EXTERNAL ADDRESS
$firstName = "Name" # First Name
$lastName = "Surname" # Last Name
$displayName = "$firstName $lastName" # Constructed Display Name
$managerEmail = "manager@company.com" # Manager's email address

# Customized invitation message
$customizedMessageBody = "This is an invitation for your account creation on Gunvor Group Azure tenant. Once you accept this invitation, you will be redirected to a landing page where you don't have permission to view, and this is normal. Please setup MFA from 'aka.ms/mfasetup' before accessing any resource. Thank you."

# Replace with your specific AD group ID
$groupId = "63c21c0f-2c90-4e0a-9e03-d2d011bce42f" # MFA SETUP OUTSIDE GUNVOR NETWORK GROUP

# Create the invitation
$invitation = New-AzureADMSInvitation -SendInvitationMessage $True `
    -InvitedUserEmailAddress $emailAddress `
    -InviteRedirectUrl "https://google.com/" `
    -InvitedUserDisplayName $displayName `
    -InvitedUserMessageInfo @{
        "MessageLanguage" = "en-US"; 
        "CustomizedMessageBody" = $customizedMessageBody 
    } `
    -InvitedUserType Guest 

# Display the invitation details 
$invitation 

# Get the invited user's ID
$invitedUserId = $invitation.InvitedUser.Id 

# Set additional user properties (First Name and Last Name)
Set-AzureADUser -ObjectId $invitedUserId -GivenName $firstName -Surname $lastName

# Get the manager's Object ID
$managerId = (Get-AzureADUser -ObjectId $managerEmail).ObjectId

# Set the manager for the guest user
Set-AzureADUserManager -ObjectId $invitedUserId -RefObjectId $managerId

# Add the guest user to a specific AD group 
Add-AzureADGroupMember -ObjectId $groupId -RefObjectId $invitedUserId
