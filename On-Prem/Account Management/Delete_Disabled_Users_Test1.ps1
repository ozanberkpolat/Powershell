#Set Site Names
$sites = @("AMS","ALL","BOG","BUE","CAL","DUB","GVA","HOU","IBR","IST","LON","MAD","MOS","NIC","RTM","SHA","SIN","STF","TAL","ULN")  # Add more site names as needed

# Set threshold date (3 months old)
$thresholdDate = (Get-Date).AddMonths(-3)

# Create an array to store information about deleted users
$deletedUsersInfo = @()

foreach ($site in $sites) {
    # Define the OU path using each site
    $searchBase = "OU=$site,OU=Sites,DC=company,DC=local" # Replace with your actual OU path
    
    # Get disabled user objects with the specified description format within the specified OU
    $disabledUsers = Get-ADUser -Filter { Enabled -eq $false -and Description -like "*Disabled on*" } -SearchBase $searchBase -Properties Description
    foreach ($user in $disabledUsers) {

        
        $description = $user.Description
        $disableDateMatch = [Regex]::Match($description, "(?i).*Disabled on (\d{4}-\d{2}-\d{2}).*")
        
        if ($disableDateMatch.Success) {
            $disableDate = [DateTime]::ParseExact($disableDateMatch.Groups[1].Value, "yyyy-MM-dd", $null)
            
            if ($disableDate -lt $thresholdDate -and $description -notmatch "(?i)maternity*" -and $user.SamAccountName -notlike "*-s*") {
                 Start-Transcript -Path "C:\2_Delete_Disabled_Accounts_History\$(Get-Date -UFormat %d_%m_%Y)_$($User.SamAccountName)_transscript.txt" -NoClobber # Transcripts the output into txt file
                $UserFolder = Get-ADUser $user -Properties HomeDirectory | Select-Object HomeDirectory

                if ($UserFolder.HomeDirectory -ne $null) {
                    Remove-Item $UserFolder.HomeDirectory -Recurse -Force -Confirm:$false # Removing users home directory folder, which deletes the folder on File Server
                    Write-Host "Home Directory deleted for $($user.SamAccountName)" -ForegroundColor Green 
                } else {

                    Write-Host "Account $($user.SamAccountName) does not have Homedrive defined" -ForegroundColor Red
                }
                
                Write-Host "Deleting user $($user.SamAccountName) with description '$description'..." -ForegroundColor Green
                
                
                Remove-ADUser -Identity $user -Confirm:$false # Deleting AD object
                Stop-Transcript
                # Add information about the deleted user to the array
                $deletedUserInfo = @{
                    SamAccountName = $user.SamAccountName
                    Description = $description
                }
                $deletedUsersInfo += $deletedUserInfo

            } else {
                Write-Host "Skipping user $($user.SamAccountName) with description '$description'..." -ForegroundColor Yellow
            }
        } else {
            Write-Host "Invalid description format for user $($user.SamAccountName): '$description'" -ForegroundColor Red
        }
    
    }
}

# Send email with deleted users information
if ($deletedUsersInfo.Count -gt 0) {
    $emailBody = "List of deleted users:`r`n`r`n"
    foreach ($userInfo in $deletedUsersInfo) {
        $emailBody += "User sAMAccountName: $($userInfo.SamAccountName)`r`n`r`nUser's Description: $($userInfo.Description)`r`n`r`n"
    }

    $smtpServer = "smtp.company.local"
    $senderEmail = "DeletedUserNotification@company.com"
    $subject = "Notification for Deleted User"

    Send-MailMessage -From $senderEmail -To 'email1@company.com','email2@company.com' -Subject $subject -Body $emailBody -SmtpServer $smtpServer
    #TO SEND TEST -   Send-MailMessage -From $senderEmail -To 'ozan.polat@company.com' -Subject $subject -Body $emailBody -SmtpServer $smtpServer
    Write-Host "Deletion report email sent."
} else {
    Write-Host "No users were deleted."
}
