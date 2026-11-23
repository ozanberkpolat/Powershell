#Requires -Modules Microsoft.Online.SharePoint.PowerShell
<#
.SYNOPSIS
    SharePoint Online "site user ID mismatch": find every site that still holds a user's old record, save its
    group memberships, then remove the record and restore the memberships for the new account.

.DESCRIPTION
    When a user is deleted and re-created with the same UPN (for example re-created through AD sync), the new
    account gets a new object ID, but every site collection the old account visited still has the old entry
    in its user information list. SharePoint then denies access ("There is a legacy user account ...",
    files shared before the re-creation no longer open). The fix is to remove the old record per site; the
    new account is added back on the next visit. Removing the record also removes its permissions, so they
    are saved first and restored afterwards.

    Two steps, run them separately:

    -Mode Scan (default, read-only)
        Walks every site (Get-SPOSite -Limit All, optionally OneDrive sites too), looks for the user with
        Get-SPOUser and writes:
          <OutDir>/<prefix>-sites.txt    FOUND;<url> | ERROR;<url>;<message> per site
          <OutDir>/<prefix>-backup.txt   <url>;<group>;<IsSiteAdmin> per membership (the restore input)
        Open the backup file and review it before you repair anything.

    -Mode Repair (writes, ShouldProcess)
        For each site in the backup (or only -Site, to test on one site first): Remove-SPOUser, then
        Add-SPOUser -Group for each saved SharePoint group, then Set-SPOUser -IsSiteCollectionAdmin when the
        old record was a site collection admin. Every step is logged to <prefix>-repair.txt.

    Written to run in Windows PowerShell 5.1 and in Constrained Language Mode (App Control / WDAC hosts):
    no [pscustomobject] or other type casts, rows are plain "a;b;c" text lines.

.PARAMETER AdminUrl
    SharePoint admin center URL, for example https://contoso-admin.sharepoint.com
.PARAMETER UserPrincipalName
    The affected user's sign-in name.
.PARAMETER Mode
    Scan (default) or Repair.
.PARAMETER Site
    Repair: only these site URLs (test on one site first). Default: every site in the backup file.
.PARAMETER IncludePersonalSite
    Scan: also scan OneDrive sites (Get-SPOSite -IncludePersonalSite). Slow in large tenants.
.PARAMETER GrantTemporaryAdmin
    Scan and Repair: on a site that answers access denied, add -AdminUpn as site collection admin, do the work,
    and remove that admin again (only where the script added it). Without it such sites are listed as ERROR
    for manual follow-up.
.PARAMETER AdminUpn
    The account running the script, needed with -GrantTemporaryAdmin.
.PARAMETER OutDir
    Folder for the text files. Default: current folder.
.PARAMETER UseSystemBrowser
    Sign in through the system browser (MSAL) instead of the embedded window, when the embedded sign-in fails.

.EXAMPLE
    ./Repair-SPOSiteUserMismatch.ps1 -AdminUrl https://contoso-admin.sharepoint.com -UserPrincipalName alex@contoso.com

.EXAMPLE
    ./Repair-SPOSiteUserMismatch.ps1 -AdminUrl https://contoso-admin.sharepoint.com -UserPrincipalName alex@contoso.com -Mode Repair -Site https://contoso.sharepoint.com/sites/Projects -WhatIf

.NOTES
    Role: SharePoint Administrator (activate PIM first) AND site collection admin on each site: Get-SPOUser,
    Remove-SPOUser and Add-SPOUser need both. Module: Microsoft.Online.SharePoint.PowerShell (update it if
    Connect-SPOService fails).
    Traps kept:
      - Prefer Microsoft's own fix first: the "Site User Mismatch" diagnostic in the Microsoft 365 admin
        center. After a PIM activation of SharePoint Administrator it can report "No issues found" for up to
        24 hours.
      - The user's OWN OneDrive must not be fixed with Remove-SPOUser. A OneDrive URL ending in an extra
        digit (..._contoso_com1) is the symptom: the new account got a new OneDrive. The diagnostic is the
        only supported fix and can reconnect the original OneDrive. The script skips that site.
      - Only SharePoint group memberships and the site collection admin flag are restored. Permissions given
        directly on a library, folder or file (sharing links, unique permissions) are not in a group and are
        lost; the owners have to share again. System groups "Limited Access System Group..." and
        "SharingLinks..." come from sharing and are not re-added.
      - The Groups and IsSiteAdmin properties of Get-SPOUser are not documented: review the backup file
        before repairing.
      - Access granted through an Entra or Microsoft 365 group comes back by itself on the next visit.
      - UNTESTED against a live tenant: the error texts matched for "access denied" and "user not found"
        (English and German) are a best guess; an unmatched error is listed as ERROR, never as not found.
      - Constrained Language Mode blocks [pscustomobject]@{} casts ("only core types are supported in this
        language mode") and method calls on non-core types, $PSCmdlet.ShouldProcess included. This script
        avoids both: under CLM -WhatIf still works but -Confirm does not prompt, so test with -Site first.
        Scan and Repair were run under ConstrainedLanguage against stubbed SPO cmdlets (not a live tenant).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$AdminUrl,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [ValidateSet('Scan', 'Repair')][string]$Mode = 'Scan',
    [string[]]$Site,
    [switch]$IncludePersonalSite,
    [switch]$GrantTemporaryAdmin,
    [string]$AdminUpn,
    [string]$OutDir = '.',
    [switch]$UseSystemBrowser
)

$ErrorActionPreference = 'Stop'
if ($GrantTemporaryAdmin -and -not $AdminUpn) { throw '-GrantTemporaryAdmin needs -AdminUpn (the account running the script).' }
$prefix = ($UserPrincipalName -replace '[^A-Za-z0-9]', '_')
$sitesFile = Join-Path $OutDir "$prefix-sites.txt"
$backupFile = Join-Path $OutDir "$prefix-backup.txt"
$repairFile = Join-Path $OutDir "$prefix-repair.txt"
# The user's own OneDrive: https://<tenant>-my.sharepoint.com/personal/<upn with . and @ as _>[digit]
$ownOneDrive = '/personal/' + ($UserPrincipalName.ToLower() -replace '[.@]', '_')

if ($UseSystemBrowser) { Connect-SPOService -Url $AdminUrl -UseSystemBrowser $true } else { Connect-SPOService -Url $AdminUrl }

function Test-OwnOneDrive([string]$Url) { $x = $Url.ToLower().TrimEnd('/'); ($x -like "*$ownOneDrive") -or ($x -like "*$ownOneDrive[0-9]") }   # no [regex]: keep it CLM-safe

if ($Mode -eq 'Scan') {
    $all = @(if ($IncludePersonalSite) { Get-SPOSite -Limit All -IncludePersonalSite $true } else { Get-SPOSite -Limit All })
    if (-not $all.Count) { throw 'Get-SPOSite returned no site. Check the admin URL and your SharePoint Administrator role.' }
    Write-Host "Scanning $($all.Count) site(s) for $UserPrincipalName ..."
    $tempAdmin = @()
    $lines = foreach ($s in $all) {
        $u = $s.Url
        try {
            if (Get-SPOUser -Site $u -LoginName $UserPrincipalName -ErrorAction Stop) { "FOUND;$u" }
        } catch {
            $msg = $_.Exception.Message
            if ($GrantTemporaryAdmin -and $msg -match 'denied|unauthori|zugriff') {
                try {
                    Set-SPOUser -Site $u -LoginName $AdminUpn -IsSiteCollectionAdmin $true -ErrorAction Stop | Out-Null
                    $tempAdmin += $u
                    if (Get-SPOUser -Site $u -LoginName $UserPrincipalName -ErrorAction Stop) { "FOUND;$u" }
                } catch { "ERROR;$u;$($_.Exception.Message)" }
            } elseif ($msg -notmatch 'not found|cannot be found|nicht gefunden') { "ERROR;$u;$msg" }
        }
    }
    $lines = @($lines)
    $lines | Set-Content -Path $sitesFile -Encoding UTF8 -WhatIf:$false

    $found = @($lines | Where-Object { $_ -like 'FOUND;*' } | ForEach-Object { $_.Split(';')[1] })
    $backup = foreach ($u in $found) {
        if (Test-OwnOneDrive $u) { Write-Warning "Own OneDrive $u : use the Site User Mismatch diagnostic, not this script. Skipped."; continue }
        $usr = Get-SPOUser -Site $u -LoginName $UserPrincipalName
        $groups = @($usr.Groups | Where-Object { $_ -and $_ -notlike 'Limited Access System Group*' -and $_ -notlike 'SharingLinks*' })
        if ($groups.Count) { foreach ($g in $groups) { "$u;$g;$($usr.IsSiteAdmin)" } } else { "$u;;$($usr.IsSiteAdmin)" }
    }
    @($backup) | Set-Content -Path $backupFile -Encoding UTF8 -WhatIf:$false

    foreach ($u in $tempAdmin) {
        try { Set-SPOUser -Site $u -LoginName $AdminUpn -IsSiteCollectionAdmin $false -ErrorAction Stop | Out-Null }
        catch { Write-Warning "Could not remove the temporary site collection admin on $u : $($_.Exception.Message)" }
    }
    $errors = @($lines | Where-Object { $_ -like 'ERROR;*' })
    Write-Host "Sites with the record: $($found.Count)  errors (not checked): $($errors.Count)"
    Write-Host "Site list: $sitesFile"
    Write-Host "Backup   : $backupFile  (site;group;IsSiteAdmin; an empty group = access came from direct sharing and cannot be restored)"
    if ($errors.Count) { Write-Warning "$($errors.Count) site(s) could not be checked (usually: you are not site collection admin there). See $sitesFile." }
    if (-not $found.Count -and -not $errors.Count) { Write-Warning "No site holds a record for $UserPrincipalName." }
    return
}

# ---- Repair ----
# Constrained Language Mode blocks method calls on non-core types, $PSCmdlet.ShouldProcess included.
$fullLanguage = $ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'
if (-not (Test-Path $backupFile)) { throw "Backup file $backupFile not found. Run -Mode Scan first and review it." }
$rows = @(Import-Csv -Path $backupFile -Delimiter ';' -Header Site, Group, IsSiteAdmin)
if (-not $rows.Count) { throw "Backup file $backupFile is empty: nothing to repair." }
$targets = if ($Site) { $Site } else { @($rows | Select-Object -ExpandProperty Site -Unique) }
$failed = 0
foreach ($s in $targets) {
    if (Test-OwnOneDrive $s) { Write-Warning "Own OneDrive $s skipped (use the diagnostic)."; continue }
    $mine = @($rows | Where-Object { $_.Site -eq $s })
    if (-not $mine.Count) { Write-Warning "$s is not in the backup file: skipped (nothing saved to restore)."; continue }
    $what = "Remove old record of $UserPrincipalName and restore $($mine.Count) membership row(s)"
    if ($fullLanguage) { if (-not $PSCmdlet.ShouldProcess($s, $what)) { continue } }
    elseif ($WhatIfPreference) { Write-Host "What if: $what on $s"; continue }   # CLM: $PSCmdlet methods are blocked, so no -Confirm prompt
    $log = @()
    $granted = $false
    if ($GrantTemporaryAdmin) {
        # Probe: access denied means the admin is not site collection admin here; grant it for this site only.
        try { Get-SPOUser -Site $s -LoginName $UserPrincipalName -ErrorAction Stop | Out-Null }
        catch {
            if ($_.Exception.Message -match 'denied|unauthori|zugriff') {
                try { Set-SPOUser -Site $s -LoginName $AdminUpn -IsSiteCollectionAdmin $true -ErrorAction Stop | Out-Null; $granted = $true; $log += "TEMPADMIN_ADDED;$s" }
                catch { $log += "ERROR_TEMPADMIN;$s;$($_.Exception.Message)" }
            }
        }
    }
    try { Remove-SPOUser -Site $s -LoginName $UserPrincipalName -ErrorAction Stop; $log += "REMOVED;$s" }
    catch {
        $log += "ERROR_REMOVE;$s;$($_.Exception.Message)"; $failed++
        if ($granted) { try { Set-SPOUser -Site $s -LoginName $AdminUpn -IsSiteCollectionAdmin $false -ErrorAction Stop | Out-Null; $log += "TEMPADMIN_REMOVED;$s" } catch { $log += "ERROR_TEMPADMIN_REMOVE;$s;$($_.Exception.Message)"; $failed++ } }
        $log | Add-Content -Path $repairFile -Encoding UTF8 -WhatIf:$false; $log | ForEach-Object { Write-Warning $_ }; continue
    }
    foreach ($r in $mine) {
        if (-not $r.Group) { continue }
        try { Add-SPOUser -Site $s -LoginName $UserPrincipalName -Group $r.Group -ErrorAction Stop | Out-Null; $log += "ADDED;$s;$($r.Group)" }
        catch { $log += "ERROR_ADD;$s;$($r.Group);$($_.Exception.Message)"; $failed++ }
    }
    if ($mine[0].IsSiteAdmin -eq 'True') {
        try { Set-SPOUser -Site $s -LoginName $UserPrincipalName -IsSiteCollectionAdmin $true -ErrorAction Stop | Out-Null; $log += "SITEADMIN;$s" }
        catch { $log += "ERROR_SITEADMIN;$s;$($_.Exception.Message)"; $failed++ }
    }
    if ($granted) {
        try { Set-SPOUser -Site $s -LoginName $AdminUpn -IsSiteCollectionAdmin $false -ErrorAction Stop | Out-Null; $log += "TEMPADMIN_REMOVED;$s" }
        catch { $log += "ERROR_TEMPADMIN_REMOVE;$s;$($_.Exception.Message)"; $failed++ }
    }
    $log | Add-Content -Path $repairFile -Encoding UTF8 -WhatIf:$false
    $log | ForEach-Object { Write-Host $_ }
}
Write-Host "Log: $repairFile"
if ($failed) { throw "$failed step(s) failed. See $repairFile." }
