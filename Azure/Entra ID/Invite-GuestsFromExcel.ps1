#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication, Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Invites B2B guests from an Excel or CSV list and optionally gives each guest a role on resource groups. Dry run by default.

.DESCRIPTION
    For every row of the list: finds an existing user by mail or otherMails, otherwise sends a B2B invitation
    (Graph POST /invitations), then optionally assigns a built-in role (Reader by default) on the resource groups mapped to
    the row's group value. Assignments are made per person because creating security groups is often not allowed for the
    operator (allowedToCreateSecurityGroups = false).

    Modes
      (default)  Dry run. Validates the list, looks every person up and prints what WOULD happen, as counts.
      -Apply     Sends invitations and creates role assignments (each guarded by ShouldProcess, so -WhatIf and -Confirm work).
      -Status    Read-only: per row the user type, external state and how many of the mapped RG assignments exist.

    Privacy and safety rules kept from production use
      * Names and e-mail addresses are never printed or written to the record file. Output refers to the row number; the
        record file (-RecordPath) holds only row number, group, objectId, assignment IDs and date.
      * The whole list is validated BEFORE any write: bad e-mail format, e-mail domain outside -AllowedEmailDomain, unknown
        group value, duplicate address. Nothing is invited if any row fails.
      * More than one directory match for an address stops the run (resolve by hand).
      * A role assignment for a just-invited guest can fail with PrincipalNotFound for a few seconds (directory
        replication). It is retried up to 6 times, 10 seconds apart. RoleAssignmentExists counts as success.
      * The record file is rewritten after every person, so an interrupted run can be resumed (existing users are reused).

.PARAMETER Path
    .xlsx (needs the ImportExcel module) or .csv list.

.PARAMETER WorksheetName
    Worksheet for .xlsx. Default: the first sheet.

.PARAMETER EmailColumn
    Column header of the e-mail address. Default Email.

.PARAMETER NameColumn
    Column header of the display name. Default DisplayName.

.PARAMETER GroupColumn
    Optional column header whose value selects the resource groups through -GroupMap.

.PARAMETER GroupMap
    Hashtable: group value -> array of resource group names, for example @{ 'Group 1' = @('rg-lab-01','rg-lab-02') }.
    Required with -GroupColumn. Omit both to only invite.

.PARAMETER SubscriptionId
    Subscription that holds the resource groups (required when GroupMap is used).

.PARAMETER RoleDefinitionId
    Role to assign. Default acdd72a7-3385-48ef-bd42-f606fba81ae7 (built-in Reader).

.PARAMETER AllowedEmailDomain
    Optional regex that every address must match, for example '@contoso\.com$'.

.PARAMETER InviteRedirectUrl
    Where the guest lands after redeeming. Default https://portal.azure.com.

.PARAMETER MessageBody
    Customised invitation text. Default: a short neutral sentence.

.PARAMETER MessageLanguage
    Invitation language tag. Default en-US.

.PARAMETER RecordPath
    JSON record of what was done. Default .\guest-invite-record.json.

.PARAMETER Apply
    Really invite and assign. Without it nothing is written.

.PARAMETER Status
    Report state only.

.EXAMPLE
    .\Invite-GuestsFromExcel.ps1 -Path .\participants.csv -AllowedEmailDomain '@contoso\.com$'

.EXAMPLE
    .\Invite-GuestsFromExcel.ps1 -Path .\participants.xlsx -GroupColumn Group -GroupMap @{ 'Group 1' = @('rg-lab-01') } `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 -Apply

.NOTES
    Modules: Microsoft.Graph.Authentication, Az.Accounts, Az.Resources (ImportExcel for .xlsx).
    Sign in first: Connect-AzAccount -Tenant <tenant>. This script then connects Graph itself.
    Graph delegated scopes: User.Invite.All, User.Read.All. Entra role: Guest Inviter (or higher).
    RBAC for assignments: Owner or User Access Administrator (or a role with Microsoft.Authorization/roleAssignments/write)
    on the resource groups; activate through PIM first. Reader on the RGs is enough for -Status and the dry run.
    Time-bound Contributor for a lab day is not implemented here: create a PIM eligible/active schedule for the
    objectIds in the record file instead of a permanent assignment.
    The User.Read.All lookup uses ConsistencyLevel eventual with $count, which Graph requires for the otherMails filter.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$WorksheetName,
    [string]$EmailColumn = 'Email',
    [string]$NameColumn = 'DisplayName',
    [string]$GroupColumn,
    [hashtable]$GroupMap,
    [string]$SubscriptionId,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7',   # built-in Reader
    [string]$AllowedEmailDomain,
    [string]$InviteRedirectUrl = 'https://portal.azure.com',
    [string]$MessageBody = 'You have been invited to collaborate in our Azure environment. After you accept, you may see an empty landing page; this is expected.',
    [string]$MessageLanguage = 'en-US',
    [string]$RecordPath = (Join-Path (Get-Location) 'guest-invite-record.json'),
    [switch]$Apply,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($GroupColumn -and -not $GroupMap) { throw '-GroupColumn needs -GroupMap.' }
if ($GroupMap -and -not $SubscriptionId) { throw '-GroupMap needs -SubscriptionId.' }
if ($GroupMap -and -not $GroupColumn) { throw '-GroupMap needs -GroupColumn.' }

# --- Read the list -------------------------------------------------------------------------------
if (-not (Test-Path $Path -PathType Leaf)) { throw "List not found: $Path" }
if ($Path -like '*.xlsx') {
    if (-not (Get-Module -ListAvailable ImportExcel)) { throw 'Reading .xlsx needs the ImportExcel module (Install-Module ImportExcel -Scope CurrentUser), or save the list as .csv.' }
    Import-Module ImportExcel
    $rowsRaw = if ($WorksheetName) { @(Import-Excel -Path $Path -WorksheetName $WorksheetName) } else { @(Import-Excel -Path $Path) }
} else {
    $rowsRaw = @(Import-Csv -Path $Path)
}
if ($rowsRaw.Count -eq 0) { throw "No rows in $Path." }
foreach ($col in @($EmailColumn, $NameColumn) + @($(if ($GroupColumn) { $GroupColumn }))) {
    if ($rowsRaw[0].PSObject.Properties.Name -notcontains $col) { throw "Column '$col' not found. Columns: $($rowsRaw[0].PSObject.Properties.Name -join ', ')" }
}
$people = @()
$n = 0
foreach ($r in $rowsRaw) {
    $n++
    $mail = ([string]$r.$EmailColumn).Trim()
    if (-not $mail) { continue }          # blank rows are normal in spreadsheets
    $people += [pscustomobject]@{
        Row   = $n
        Mail  = $mail
        Name  = ([string]$r.$NameColumn).Trim()
        Group = $(if ($GroupColumn) { ([string]$r.$GroupColumn).Trim() } else { $null })
    }
}
if ($people.Count -eq 0) { throw "No rows with an e-mail address in $Path." }

# --- Validate everything before any write --------------------------------------------------------
$bad = @()
$seen = @{}
foreach ($p in $people) {
    if ($p.Mail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $bad += "row $($p.Row): not an e-mail address"; continue }
    if ($AllowedEmailDomain -and $p.Mail -notmatch $AllowedEmailDomain) { $bad += "row $($p.Row): address outside the allowed domain"; continue }
    if ($seen.ContainsKey($p.Mail.ToLower())) { $bad += "row $($p.Row): duplicate of row $($seen[$p.Mail.ToLower()])"; continue }
    $seen[$p.Mail.ToLower()] = $p.Row
    if ($GroupMap -and -not $GroupMap.ContainsKey($p.Group)) { $bad += "row $($p.Row): group value '$($p.Group)' is not in -GroupMap" }
    if (-not $p.Name) { $bad += "row $($p.Row): empty display name" }
}
if ($bad.Count -gt 0) { throw ("The list has problems, nothing was changed:`n  " + ($bad -join "`n  ")) }

# --- Sessions ------------------------------------------------------------------------------------
$azCtx = Get-AzContext
if (-not $azCtx) { throw 'Not signed in to Azure. Run Connect-AzAccount -Tenant <tenant> first.' }
$tenantId = $azCtx.Tenant.Id
$scopes = if ($Status -or -not $Apply) { @('User.Read.All') } else { @('User.Invite.All', 'User.Read.All') }
Connect-MgGraph -TenantId $tenantId -Scopes $scopes -NoWelcome -ContextScope Process

function Find-GuestUser([string]$Mail) {
    $esc = $Mail.Replace("'", "''")
    $q = [uri]::EscapeDataString("mail eq '$esc' or otherMails/any(x:x eq '$esc')")
    $res = Invoke-MgGraphRequest -Method GET -OutputType PSObject -Headers @{ ConsistencyLevel = 'eventual' } `
        -Uri "https://graph.microsoft.com/v1.0/users?`$filter=$q&`$count=true&`$select=id,userType,externalUserState"
    @($res.value)
}

function Add-RoleWithRetry([string]$ObjectId, [string]$Scope) {
    for ($try = 1; $try -le 6; $try++) {
        try {
            $a = New-AzRoleAssignment -ObjectId $ObjectId -ObjectType User -RoleDefinitionId $RoleDefinitionId -Scope $Scope `
                -Description 'Guest access (temporary), created by Invite-GuestsFromExcel'
            return $a.RoleAssignmentId
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'already exists|RoleAssignmentExists') { return 'already-exists' }
            if ($m -match 'PrincipalNotFound|does not exist in the directory' -and $try -lt 6) { Start-Sleep -Seconds 10; continue }
            throw "Role assignment on $Scope failed: $m"
        }
    }
}

function Get-Rgs($p) { if ($GroupMap) { @($GroupMap[$p.Group]) } else { @() } }

# --- Status mode ---------------------------------------------------------------------------------
if ($Status) {
    foreach ($p in $people) {
        $found = @(Find-GuestUser $p.Mail)
        $state = if ($found.Count) { ($found | ForEach-Object { "$($_.userType)/$($_.externalUserState)" }) -join ',' } else { 'not found' }
        $have = 0; $want = @(Get-Rgs $p).Count
        foreach ($u in $found) {
            foreach ($rg in @(Get-Rgs $p)) {
                $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
                $have += @(Get-AzRoleAssignment -ObjectId $u.id -Scope $scope -RoleDefinitionId $RoleDefinitionId | Where-Object { $_.Scope -eq $scope }).Count
            }
        }
        Write-Host ("row {0}: {1}; role assignments {2}/{3}" -f $p.Row, $state, $have, $want)
    }
    return
}

# --- Plan / apply --------------------------------------------------------------------------------
$plan = foreach ($p in $people) {
    $found = @(Find-GuestUser $p.Mail)
    if ($found.Count -gt 1) { throw "row $($p.Row): $($found.Count) directory matches for the address. Resolve by hand." }
    [pscustomobject]@{ Person = $p; Existing = $(if ($found.Count) { $found[0] } else { $null }); Rgs = @(Get-Rgs $p) }
}
foreach ($x in $plan) {
    Write-Host ("row {0}: {1}, role on {2} RG(s)" -f $x.Person.Row, $(if ($x.Existing) { 'user exists' } else { 'will be invited' }), $x.Rgs.Count)
}
Write-Host ("{0} to invite, {1} existing, {2} role assignment(s)" -f @($plan | Where-Object { -not $_.Existing }).Count, @($plan | Where-Object { $_.Existing }).Count, (($plan | ForEach-Object { $_.Rgs.Count }) | Measure-Object -Sum).Sum)
if (-not $Apply) { Write-Host 'Dry run. Re-run with -Apply to invite and assign.'; return }

$out = [ordered]@{}
if (Test-Path $RecordPath) { foreach ($pr in (Get-Content $RecordPath -Raw | ConvertFrom-Json).PSObject.Properties) { $out[$pr.Name] = $pr.Value } }
foreach ($x in $plan) {
    $p = $x.Person
    $oid = $null; $sent = $false
    if ($x.Existing) { $oid = $x.Existing.id }
    elseif ($PSCmdlet.ShouldProcess("row $($p.Row)", 'invite B2B guest')) {
        $body = @{
            invitedUserEmailAddress = $p.Mail; invitedUserDisplayName = $p.Name
            inviteRedirectUrl = $InviteRedirectUrl; sendInvitationMessage = $true
            invitedUserMessageInfo = @{ messageLanguage = $MessageLanguage; customizedMessageBody = $MessageBody } } | ConvertTo-Json -Depth 5
        $inv = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/invitations' -Body $body -ContentType 'application/json' -OutputType PSObject
        if (-not $inv.invitedUser.id) { throw "row $($p.Row): invitation returned no user id." }
        $oid = $inv.invitedUser.id; $sent = $true
    } else { continue }
    $assignments = @()
    foreach ($rg in $x.Rgs) {
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"
        if ($PSCmdlet.ShouldProcess($scope, "assign role $RoleDefinitionId to row $($p.Row)")) { $assignments += Add-RoleWithRetry $oid $scope }
    }
    $out[[string]$p.Row] = [ordered]@{ group = $p.Group; objectId = $oid; roleAssignments = $assignments; date = (Get-Date -Format 'yyyy-MM-dd') }
    $out | ConvertTo-Json -Depth 5 | Out-File -FilePath $RecordPath -Encoding utf8
    Write-Host ("row {0}: invitation {1}, {2} role assignment(s)" -f $p.Row, $(if ($sent) { 'sent' } else { 'not needed' }), $assignments.Count)
}
Write-Host "Record: $RecordPath"
