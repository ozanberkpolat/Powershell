$warningDays = 60

$userName = $env:USERNAME
$userDomain = $env:USERDOMAIN

# Get the user object from Active Directory
$user = Get-ADUser -Identity $userName -Properties PasswordLastSet, PasswordNeverExpires, PasswordExpired, "msDS-UserPasswordExpiryTimeComputed"

if (!$user) {
    Write-Host "Failed to find user account."
    exit 1
}

if ($user.PasswordNeverExpires -or $user.PasswordExpired) {
    # The password doesn't expire, or it has already expired.
    exit 0
}

$maxPwdAge = (Get-ADDefaultDomainPasswordPolicy).MaxPasswordAge

$pwdLastSet = $user.PasswordLastSet
$expiryTime = $user."msDS-UserPasswordExpiryTimeComputed"

if ($pwdLastSet -eq $null) {
    Write-Host "Failed to retrieve password last set time for user."
    exit 1
}

if ($expiryTime -eq $null) {
    Write-Host "Failed to retrieve password expiry time for user."
    exit 1
}

$expiryDateTime = [DateTime]::FromFileTimeUtc($expiryTime)
$daysLeft = ($expiryDateTime - (Get-Date)).Days

Write-Host $expiryDateTime
Write-Host $daysLeft

if ($daysLeft -lt $warningDays -and $daysLeft -ge 0) {
    $message = "Password expires in $daysLeft day(s) at $($expiryDateTime.ToString()).`r`n`r`nOnce logged in, press CTRL-ALT-DEL and select the 'Change a password' option."
    [System.Windows.Forms.MessageBox]::Show($message, "PASSWORD EXPIRATION WARNING!", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
}