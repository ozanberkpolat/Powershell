<#
.SYNOPSIS
    Intune Remediations script: uninstalls the classic Teams Machine-Wide Installer, but only when new Teams is present.

.DESCRIPTION
    1. Relaunches itself in 64-bit PowerShell when Intune started it in the 32-bit host (the Remediations default):
       the Appx cmdlets do not work in a 32-bit PowerShell on 64-bit Windows, and a silently failing
       Get-AppxPackage reads as "new Teams is missing".
    2. Refuses (exit 1) unless new Teams (MSTeams) is installed for a user OR provisioned for new users. An AVD or
       shared host typically has it provisioned only (teamsbootstrapper.exe -p), with no per-user install yet; checking
       Get-AppxPackage alone wrongly refused those hosts. Without new Teams the users would be left with no Teams client.
    3. Uninstalls every "Teams Machine-Wide Installer" MSI entry (64-bit and 32-bit registry views) with msiexec /x and
       a verbose log under the Intune Management Extension log folder. Exit codes 0, 3010 and 1605 are success;
       anything else fails the remediation (the source version ignored the msiexec result and always reported success).
    4. Checks again: exit 0 only when no entry is left.

    Per-user classic Teams copies are not touched. Removing the machine-wide installer makes classic Teams uninstall
    for each user at their next sign-in; for an immediate clean-up run Microsoft's script
    (https://aka.ms/uninstallclassicteamsscript).

.EXAMPLE
    # Local test, elevated:
    powershell.exe -ExecutionPolicy Bypass -File .\TeamsMwi-Remediate.ps1; $LASTEXITCODE

.NOTES
    UNTESTED: the 64-bit relaunch through Sysnative and the provisioned-package check are new against the source; run once
    on a pilot device from the 32-bit Remediations host and confirm the output names the installed/provisioned state.
    Intune: pair with TeamsMwi-Detect.ps1 in one script package. Run as SYSTEM (logged-on credentials = No).
    "Run script in 64-bit PowerShell" may stay No: the script relaunches itself. Encode as UTF-8 without BOM if script
    signature check is enforced. Needs local admin (SYSTEM).
    Guidance: https://learn.microsoft.com/microsoftteams/teams-classic-client-uninstall (admin-deployed Machine-Wide
    Installer without Microsoft 365 Apps: deploy new Teams machine-wide first, then uninstall the installer).
    Non-persistent VDI: fix the golden image instead; a remediation on pooled hosts is undone by the next reimage.
#>
$ErrorActionPreference = 'Stop'

# 1. 64-bit host. Sysnative is the 64-bit System32 as seen from a 32-bit process.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

function Get-UninstallEntry([string]$DisplayName) {
    foreach ($view in [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        if (-not $root) { continue }
        foreach ($name in $root.GetSubKeyNames()) {
            $k = $root.OpenSubKey($name)
            if ($k -and $k.GetValue('DisplayName') -eq $DisplayName) {
                [pscustomobject]@{ View = "$view"; KeyName = $name; Version = $k.GetValue('DisplayVersion') }
            }
        }
    }
}

try {
    # 2. New Teams installed for someone, or provisioned for new users.
    $installed = @(Get-AppxPackage -AllUsers -Name MSTeams)
    $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'MSTeams' })
    if ($installed.Count -eq 0 -and $provisioned.Count -eq 0) {
        Write-Output 'New Teams (MSTeams) is neither installed nor provisioned: Machine-Wide Installer NOT removed. Deploy new Teams first.'
        exit 1
    }

    # 3. Uninstall every entry.
    $mwi = @(Get-UninstallEntry 'Teams Machine-Wide Installer' | Sort-Object KeyName -Unique)
    $logDir = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
    $failed = @()
    foreach ($m in $mwi) {
        if ($m.KeyName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { $failed += "$($m.KeyName): not an MSI product code"; continue }
        $log = Join-Path $logDir 'TeamsMWI-uninstall.log'
        $p = Start-Process msiexec.exe -ArgumentList "/x $($m.KeyName) /qn /norestart /l*v `"$log`"" -Wait -PassThru
        if (@(0, 3010, 1605) -notcontains $p.ExitCode) { $failed += "$($m.KeyName): msiexec exit $($p.ExitCode)" }
    }

    # 4. Verify.
    $left = @(Get-UninstallEntry 'Teams Machine-Wide Installer')
    if ($failed.Count -or $left.Count) {
        Write-Output ("Removal incomplete. " + ($failed -join '; ') + " Entries left: $($left.Count). Log: $logDir\TeamsMWI-uninstall.log")
        exit 1
    }
    Write-Output "Removed $($mwi.Count) Teams Machine-Wide Installer entr$(if ($mwi.Count -eq 1) { 'y' } else { 'ies' }). New Teams: installed for $($installed.Count) user(s), provisioned: $($provisioned.Count -gt 0)."
    exit 0
} catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
