#Written by Neytullah ARSLAN
#Get Disabled Users

import-module ActiveDirectory

$txt = $null
$body = $null
$user = $null
$content = $null
$disabled_user = $null
$disabled_list = $null

function mail-sending{ 

Send-MailMessage -From 'DeletedUserNotification@company.com' -To 'ozan.polat@company.com' -Subject 'Notification for Deleted User' -Body $body -SmtpServer 'smtp.company.local' -Port '25' }

function get-deletefunc{

$User=$disabled_user.SamAccountName

Start-Transcript "C:\2_Delete_Disabled_Accounts_History\$(Get-Date -UFormat %d_%m_%Y)_$($User)_transscript.txt" -NoClobber

Write-Host "Getting $User homedirectory" -ForegroundColor Yellow

$UserFolder=Get-ADUser $User -Properties HomeDirectory | Select-Object HomeDirectory

Write-Host "Deleting user $User homedirectory" -ForegroundColor Yellow

If($UserFolder.HomeDirectory -ne $null){

Remove-Item $UserFolder.HomeDirectory -Recurse -Force -Confirm:$false

}
else{
Write-Host "Account $User does not have Homedrive defined" -ForegroundColor Cyan
}
Write-Host "Removing $User from AD" -ForegroundColor Yellow

Remove-ADobject (Get-ADUser $User).distinguishedname -Recursive -Confirm:$false

Write-Host "Removing $User complete" -ForegroundColor Green }


$disabled_list = Get-ADUser -Filter {Enabled -eq $false} -SearchBase "OU=Sites,DC=company,DC=local" -Properties Description


#Connect-ExchangeOnline -ErrorAction SilentlyContinue

#Get disabled date

foreach ($disabled_user in $disabled_list)
{

$content = $null

$content = $disabled_user.Description

$disabled_user.SamAccountName +"-"+ $Content.Substring(12,10)

$Cdate = get-date

$Ddate=$Cdate

$Ddate=[DateTime]$Content.Substring(12,10)


#Select Users Who Have Been Disabled for more than 90 days

$substraction = 0


$substraction = New-TimeSpan -Start $Ddate -End $Cdate

$substraction

if($substraction.Days -gt 90){

#Get OoO Message of User

#$Arm = Get-MailboxAutoReplyConfiguration -identity $disabled_user.SamAccountName -ErrorAction SilentlyContinue

#If($Arm -notlike "*maternity*" -and $Content -notlike "*maternity*" ) {

#deleteaccount

#get-deletefunc


#mail-sending
 
#}
if($Content -notlike "*maternity*" -and $content -notlike "*-s*" -and $disabled_user.SamAccountName -notlike "*-s*"){

#deleteaccount

get-deletefunc

$deleted_user = $disabled_user.SamAccountName

$body = -join($body," ",$txt)

$txt1 = '***************************************************************

The user : ' + $deleted_user  + ' has been deleted
' 

$txt2 = 'Description : ' + $content + '

Important note : If you think something has been wrongly, please ask your manager to restore it.

'
$txt = $txt1 + $txt2

#Write-Host $Body -ForegroundColor green -NoNewline
}

}

}

mail-sending

