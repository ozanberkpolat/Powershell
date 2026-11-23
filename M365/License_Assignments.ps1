#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Microsoft 365 licence report: SKU consumption, group-based licence assignments, and the users on one SKU.

.DESCRIPTION
    Read-only. Three parts:

    1. SKU consumption (always): every subscribed SKU with its capability status, consumed units and the
       Enabled / Warning / Suspended / LockedOut prepaid units, plus the free count. Printed and written to
       <OutDir>/License_SKU_Usage.csv. Use it before a renewal or a true-up: Warning and Suspended units are
       licences that are about to go or already went.

    2. Group-based licences (default, skip with -SkipGroupReport): every group that assigns a licence and its
       user members, to <OutDir>/Group_Based_Licenses.csv (same file and columns as earlier versions of this
       script).

    3. Users on one SKU (with -SkuPartNumber, for example ENTERPRISEPREMIUM or SPE_E5): every user holding it,
       with how it was assigned (Direct or the group it comes from), to <OutDir>/Users_<SKU>.csv.

.PARAMETER SkuPartNumber
    List the users assigned this SKU. Must match a subscribed SKU's SkuPartNumber (the script lists them if not).
.PARAMETER SkipGroupReport
    Do not build the group-based licence report (it reads every licensed group's members and can be slow).
.PARAMETER OutDir
    Folder for the CSV files. Default: current folder.

.EXAMPLE
    ./License_Assignments.ps1

.EXAMPLE
    ./License_Assignments.ps1 -SkuPartNumber SPE_E5 -SkipGroupReport

.NOTES
    Permissions (delegated): Organization.Read.All, User.Read.All, Group.Read.All, Directory.Read.All.
    Directory role: Global Reader is enough. Modules: Microsoft.Graph (Authentication, Users, Groups,
    Identity.DirectoryManagement). Install them once with Install-Module Microsoft.Graph -Scope CurrentUser;
    the script itself never installs anything. If no Graph context exists, it calls Connect-MgGraph.
    Traps kept:
      - Group-based licensing applies to DIRECT members only (nested groups get nothing), so the report reads
        direct user members (Get-MgGroupMemberAsUser). Get-MgGroupMember returns directory objects whose
        UserPrincipalName is empty unless read from AdditionalProperties.
      - Get-MgSubscribedSku is called once; calling it per group and licence is slow and throttles.
      - A user can hold the same SKU both directly and through one or more groups: one row per path.
      - The users-on-SKU filter runs on the server (assignedLicenses/any(x:x/skuId eq <id>)), not by
        downloading every user.
#>
[CmdletBinding()]
param(
    [string]$SkuPartNumber,
    [switch]$SkipGroupReport,
    [string]$OutDir = '.'
)

$ErrorActionPreference = 'Stop'
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes 'Organization.Read.All', 'User.Read.All', 'Group.Read.All', 'Directory.Read.All' -NoWelcome
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---- 1. SKU consumption ----
$skus = @(Get-MgSubscribedSku -All)
if (-not $skus.Count) { throw 'Get-MgSubscribedSku returned no SKU. Check the Organization.Read.All consent and the signed-in tenant.' }
$skuName = @{}
foreach ($s in $skus) { $skuName[[string]$s.SkuId] = $s.SkuPartNumber }

$usage = foreach ($s in $skus | Sort-Object SkuPartNumber) {
    [pscustomobject]@{
        SkuPartNumber    = $s.SkuPartNumber
        SkuId            = $s.SkuId
        CapabilityStatus = $s.CapabilityStatus
        Enabled          = $s.PrepaidUnits.Enabled
        Warning          = $s.PrepaidUnits.Warning
        Suspended        = $s.PrepaidUnits.Suspended
        LockedOut        = $s.PrepaidUnits.LockedOut
        Consumed         = $s.ConsumedUnits
        Available        = $s.PrepaidUnits.Enabled - $s.ConsumedUnits
    }
}
$usage | Format-Table SkuPartNumber, CapabilityStatus, Enabled, Warning, Suspended, Consumed, Available -AutoSize | Out-String | Write-Host
$usage | Export-Csv (Join-Path $OutDir 'License_SKU_Usage.csv') -NoTypeInformation
$attention = @($usage | Where-Object { $_.Warning -gt 0 -or $_.Suspended -gt 0 -or $_.Available -lt 0 })
foreach ($a in $attention) { Write-Warning "$($a.SkuPartNumber): Warning=$($a.Warning) Suspended=$($a.Suspended) Available=$($a.Available)" }

# ---- 2. Group-based licences (behaviour of the original script) ----
if (-not $SkipGroupReport) {
    $licensedGroups = @(Get-MgGroup -All -Filter 'assignedLicenses/any()' -Property Id, DisplayName, AssignedLicenses)
    $results = foreach ($group in $licensedGroups) {
        $members = @(Get-MgGroupMemberAsUser -GroupId $group.Id -All -Property Id, DisplayName, UserPrincipalName)
        foreach ($license in $group.AssignedLicenses) {
            $name = if ($skuName.ContainsKey([string]$license.SkuId)) { $skuName[[string]$license.SkuId] } else { $license.SkuId }
            foreach ($member in $members) {
                [pscustomobject]@{
                    GroupName         = $group.DisplayName
                    GroupId           = $group.Id
                    LicenseSkuId      = $license.SkuId
                    LicenseSkuName    = $name
                    UserDisplayName   = $member.DisplayName
                    UserPrincipalName = $member.UserPrincipalName
                }
            }
        }
    }
    $results = @($results)
    $groupCsv = Join-Path $OutDir 'Group_Based_Licenses.csv'
    $results | Export-Csv $groupCsv -NoTypeInformation
    if (-not $licensedGroups.Count) { Write-Warning 'No group assigns a licence (group-based licensing not in use).' }
    Write-Host "Group-based licences: $($licensedGroups.Count) group(s), $($results.Count) row(s) -> $groupCsv"
}

# ---- 3. Users on one SKU ----
if ($SkuPartNumber) {
    $sku = $skus | Where-Object SkuPartNumber -eq $SkuPartNumber
    if (-not $sku) { throw "SKU '$SkuPartNumber' is not subscribed. Available: $(($skus.SkuPartNumber | Sort-Object) -join ', ')" }
    $groupNames = @{}
    $users = @(Get-MgUser -All -Filter "assignedLicenses/any(x:x/skuId eq $($sku.SkuId))" -Property Id, DisplayName, UserPrincipalName, AccountEnabled, LicenseAssignmentStates)
    $rows = foreach ($u in $users) {
        foreach ($st in @($u.LicenseAssignmentStates | Where-Object { [string]$_.SkuId -eq [string]$sku.SkuId })) {
            $via = 'Direct'
            if ($st.AssignedByGroup) {
                if (-not $groupNames.ContainsKey($st.AssignedByGroup)) { $groupNames[$st.AssignedByGroup] = (Get-MgGroup -GroupId $st.AssignedByGroup -Property DisplayName).DisplayName }
                $via = "Group: $($groupNames[$st.AssignedByGroup])"
            }
            [pscustomobject]@{
                UserPrincipalName = $u.UserPrincipalName
                DisplayName       = $u.DisplayName
                AccountEnabled    = $u.AccountEnabled
                AssignedVia       = $via
                State             = $st.State
                Error             = $st.Error
            }
        }
    }
    $rows = @($rows)
    $skuCsv = Join-Path $OutDir "Users_$SkuPartNumber.csv"
    $rows | Export-Csv $skuCsv -NoTypeInformation
    Write-Host "$SkuPartNumber : $($users.Count) user(s), consumed units $($sku.ConsumedUnits) -> $skuCsv"
    if ($users.Count -ne $sku.ConsumedUnits) { Write-Warning "User count ($($users.Count)) differs from ConsumedUnits ($($sku.ConsumedUnits)): check licences in an error state or on deleted users." }
    $disabled = @($rows | Where-Object { -not $_.AccountEnabled })
    if ($disabled.Count) { Write-Warning "$($disabled.Count) assignment(s) are on disabled accounts: candidates to reclaim." }
}
