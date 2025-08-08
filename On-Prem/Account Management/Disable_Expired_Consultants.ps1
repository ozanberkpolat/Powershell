#This script will:
#find the Consultants
#check their account expiration date
#and if it's today; it will disable the user object, it will add 'Disabled on - DATE' to the description, move the user object to the Disabled OU in the same site.

# Define the list of site codes
$sites = @("AMS","BOG","BUE","CAL","DUB","GVA","HOU","IBR","IST","LON","MAD","MOS","NIC","RTM","SHA","SIN","STF","TAL","ULN")  # Add more site names as needed

# Define the current date
$today = Get-Date

# Initialize an array to store information about deleted users
$deletedUsersInfo = @()

# Loop through each site
foreach ($siteCode in $sites) {

    $searchBase = "OU=Externals,OU=Users,OU=$siteCode,OU=Sites,DC=company,DC=local"
    $targetDisabledOU = "OU=Disabled,OU=Users,OU=$siteCode,OU=Sites,DC=company,DC=local"
    $users = Get-ADUser -Filter {(Enabled -eq $true) -and (AccountExpirationDate -like '*')} -Properties AccountExpirationDate, Description, DistinguishedName -SearchBase $searchBase
    foreach ($user in $users) {
        $expirationDate = $user.AccountExpirationDate
        if ($expirationDate -lt $today) {
Start-Transcript -Path "C:\4_Disabled_Consultants_History\$(Get-Date -UFormat %d_%m_%Y)_transscript.txt" -NoClobber # Transcripts the output into txt file
             $newDescription = $user.Description + "- Disabled on " + $expirationDate.ToString("yyyy-MM-dd")
            $user | Set-ADUser -Description $newDescription
            $user | Disable-ADAccount
            $user | Move-ADObject -TargetPath $targetDisabledOU
            $deletedUserInfo = @{
                SamAccountName = $user.SamAccountName
                Description = $user.Description
            }
            $deletedUsersInfo += New-Object PSObject -Property $deletedUserInfo

            Write-Host "Updated description, disabled, and moved $($user.Name) to $targetDisabledOU in site $siteCode."
            Stop-Transcript
        }
    }
}

# Check if there are any deleted users
if ($deletedUsersInfo.Count -gt 0) {
    $emailBody = "List of disabled external users:`r`n`r`n"
    foreach ($userInfo in $deletedUsersInfo) {
        $emailBody += "User sAMAccountName: $($userInfo.SamAccountName)`r`nUser's Description: $($userInfo.Description)`r`n`r`n"
    }

    $smtpServer = "smtp.company.local"
    $senderEmail = "DisabledUserNotification@company.com"
    $subject = "Notification for Disabled Consultant Users"

    Send-MailMessage -From $senderEmail -To 'Thierry.MASSON@company.com','linus.joyeux@company.com','ozan.polat@company.com','mesut.cevik@company.com','musa.yakasiz@company.com','kerim.korkmaz@company.com' -Subject $subject -Body $emailBody -SmtpServer $smtpServer
 
}
