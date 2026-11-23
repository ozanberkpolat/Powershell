<#
.SYNOPSIS
    Intune custom detection script for the Zabbix agent 2 Win32 package: binary version, service, PSK file and PSK settings.

.DESCRIPTION
    Detected (stdout text AND exit 0) only when all of these hold:
      * zabbix_agent2.exe exists under the 64-bit Program Files and its file version is at least $MinVersion
      * the "Zabbix Agent 2" service exists and is not disabled
      * psk.key exists next to it
      * zabbix_agent2.conf has TLSConnect=psk and the expected TLSPSKIdentity
    Anything else: no output, exit 1 (Intune then runs the install command).

    Edit the two values at the top before you upload it. Intune detection scripts take no parameters.

.EXAMPLE
    # Local test, elevated, 64-bit PowerShell:
    powershell.exe -ExecutionPolicy Bypass -File .\Detect-ZabbixAgent2.ps1; $LASTEXITCODE

.NOTES
    UNTESTED: written for this package (production used the MSI ProductCode rule); test on a pilot host before assigning.
    Upload as the detection rule "Use a custom detection script", "Run script as 32-bit process on 64-bit clients" = No.
    The version check is "at least", never "equals": a newer agent installed by a later package must not trigger a
    reinstall loop of the older one. Reads only; runs as SYSTEM.
#>
$ErrorActionPreference = 'Stop'

$MinVersion  = [version]'7.0.0'     # CHANGE: the agent version in the package
$PskIdentity = 'PSK-IDENTITY'       # CHANGE: the identity passed to install.cmd

# $env:ProgramW6432 is the 64-bit Program Files even in a 32-bit host.
$dir = Join-Path $env:ProgramW6432 'Zabbix Agent 2'
$exe = Join-Path $dir 'zabbix_agent2.exe'
$conf = Join-Path $dir 'zabbix_agent2.conf'
if (-not (Test-Path $exe) -or -not (Test-Path (Join-Path $dir 'psk.key')) -or -not (Test-Path $conf)) { exit 1 }

$fv = (Get-Item $exe).VersionInfo
$ver = [version]('{0}.{1}.{2}' -f $fv.FileMajorPart, $fv.FileMinorPart, $fv.FileBuildPart)
if ($ver -lt $MinVersion) { exit 1 }

$svc = Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'"
if (-not $svc -or $svc.StartMode -eq 'Disabled') { exit 1 }

$settings = @{}
foreach ($line in Get-Content $conf) {
    if ($line -match '^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$') { $settings[$Matches[1]] = $Matches[2] }
}
if ($settings['TLSConnect'] -ne 'psk' -or $settings['TLSPSKIdentity'] -ne $PskIdentity) { exit 1 }

Write-Output "Zabbix agent 2 $ver detected, service $($svc.State), PSK identity configured"
exit 0
