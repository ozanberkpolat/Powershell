# ----------------------------------------------------
Connect-MgGraph -Scopes "AuditLog.Read.All","User.Read.All"
# ----------------------------------------------------

$groupId = ""  # Replace with your group object ID

# 1. Get group members
$members = @()
$uri = "https://graph.microsoft.com/v1.0/groups/$groupId/members?$select=id,userPrincipalName"

while ($uri) {
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    $members += $response.value
    $uri = $response.'@odata.nextLink'
}

# 2. Filter only users with -z in UPN
$zUsers = $members | Where-Object { $_.userPrincipalName -and $_.userPrincipalName -like "*-z*" }
Write-Host "Found $($zUsers.Count) users with '-z' in UPN"

# 3. Get last interactive sign-in per user
$lastSignIns = @()

foreach ($user in $zUsers) {
    $signInUri = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=userPrincipalName eq '$($user.userPrincipalName)'&`$orderby=createdDateTime desc&`$top=1"

    $result = Invoke-MgGraphRequest -Method GET -Uri $signInUri

    if ($result.value) {
        # Optional: filter for interactive only
        $interactive = $result.value | Where-Object {
            $_.authenticationRequirement -eq "singleFactorAuthentication" -or
            $_.authenticationRequirement -eq "multiFactorAuthentication"
        }

        if ($interactive) {
            $lastSignIns += $interactive
        }
    }
}

# 4. Output
$lastSignIns | Select-Object userPrincipalName, userDisplayName, createdDateTime, ipAddress, status

# Optional: Export
# $lastSignIns | Export-Csv "LastInteractiveSignIns-ZUsers.csv" -NoTypeInformation
