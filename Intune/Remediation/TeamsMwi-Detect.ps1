<#
.SYNOPSIS
    Intune Remediations detection script: is the classic Teams Machine-Wide Installer still on this device?

.DESCRIPTION
    Exit 1 (issue found, the remediation script runs) when an uninstall entry named "Teams Machine-Wide Installer"
    exists in the 64-bit OR the 32-bit registry view. Exit 0 otherwise.
    While it is installed it reinstalls classic Teams into every new user profile at sign-in, which keeps classic Teams
    vulnerabilities open in Defender Vulnerability Management no matter how often the per-user copies are removed.

    Per-user classic Teams copies (%LOCALAPPDATA%\Microsoft\Teams\current\Teams.exe) are REPORTED in the output but do
    not trigger the remediation: the remediation removes only the machine-wide installer. Remove the per-user copies with
    Microsoft's classic Teams uninstall script (https://aka.ms/uninstallclassicteamsscript) once the installer is gone.

.EXAMPLE
    # Local test, elevated:
    powershell.exe -ExecutionPolicy Bypass -File .\TeamsMwi-Detect.ps1; $LASTEXITCODE

.NOTES
    UNTESTED: the explicit 64/32-bit registry view read replaces the source's Get-ItemProperty; verify on a pilot device.
    Intune: Devices > Scripts and remediations. Run as SYSTEM (logged-on credentials = No). Output is kept short (the
    Remediations output limit is 2048 characters). Works in a 32-bit or 64-bit host: both registry views are opened
    explicitly. (A plain Get-ItemProperty on HKLM:\SOFTWARE\... in the default 32-bit Remediations host is redirected
    to WOW6432Node and misses a 64-bit install.)
    Read-only. Guidance: https://learn.microsoft.com/microsoftteams/teams-classic-client-uninstall
#>
$ErrorActionPreference = 'Stop'

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
    $mwi = @(Get-UninstallEntry 'Teams Machine-Wide Installer' | Sort-Object KeyName -Unique)
    $classic = @(Get-ChildItem 'C:\Users\*\AppData\Local\Microsoft\Teams\current\Teams.exe' -ErrorAction SilentlyContinue)
    $note = if ($classic.Count) { " Per-user classic Teams in $($classic.Count) profile(s) (not remediated here)." } else { '' }
    if ($mwi.Count) {
        Write-Output ("Teams Machine-Wide Installer present: " + (($mwi | ForEach-Object { "$($_.KeyName) v$($_.Version) [$($_.View)]" }) -join '; ') + ".$note")
        exit 1
    }
    Write-Output "Teams Machine-Wide Installer not present.$note"
    exit 0
} catch {
    # Fail loud: an error must not read as "not present".
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
