#Requires -Version 5.1
<#
.SYNOPSIS
    Builds an App Control for Business (WDAC) base policy for AVD session hosts from the inbox AllowMicrosoft template.

.DESCRIPTION
    Starts from the inbox AllowMicrosoft.xml template (Windows plus every Microsoft-signed binary: AVD agent,
    boot loader, SxS stack, Edge and EdgeUpdate, Defender, Intune Management Extension and AgentExecutor, VM agent
    and extension handlers, FSLogix, Azure Monitor Agent). Windows Update, cumulative updates and Defender platform
    updates are Microsoft-signed and covered by the same signers.

    Adds the Managed Installer option (13) so Win32 apps deployed by Intune run without per-app rules, once the
    Intune "Managed installer" setting is enabled for the device group.
    Script enforcement is OFF by default (option 11): Run Command, the DSC extension, Intune scripts and
    remediations stay in FullLanguage. Audit mode is ON by default (option 3).

    Safety behaviour kept from production use:
      * The policy GUID is the identity of the policy in Intune. If -PolicyGuid is not given and an XML from an
        earlier build exists in -OutDir, its GUID is reused. A new GUID is generated only for a first build and
        is printed so you can record it. Changing it later makes Intune deploy a SECOND base policy.
      * -Version may never go below the existing build (Intune applies an update only with a higher VersionEx).
      * Set-CIPolicyIdInfo -PolicyId only sets the PolicyInfo string, not the GUID, so the GUID is written into
        the XML directly (PolicyID and BasePolicyID).
      * The finished XML is compiled to a .cip and every rule option is compared with the expected set, so a
        template change in a new Windows build is noticed instead of shipped.

    Local file generation only. Writes nothing to Intune or Azure.
    ConfigCI must run in Windows PowerShell 5.1, not pwsh 7 (implicit remoting breaks the cmdlets).

.PARAMETER PolicyGuid
    Fixed policy identity. Omit to reuse the GUID of an earlier build in OutDir, or to generate one on the first build.

.PARAMETER PolicyName
    Policy name (PolicyInfo Name). Must not contain a double hyphen (it ends up in an XML comment).

.PARAMETER Version
    Four-part version. Must be higher than the version already deployed for an in-place update.

.PARAMETER OutDir
    Output folder. Default: the script folder.

.PARAMETER Enforce
    Drop option 3 (Audit Mode). Do this only after weeks of clean audit logs.

.PARAMETER EnableScriptEnforcement
    Drop option 11, so unsigned scripts run in Constrained Language Mode. Breaks Run Command and DSC unless the
    scripts are signed by a signer you add to the policy.

.PARAMETER EnableIsg
    Add options 14 and 15 (Intelligent Security Graph authorisation, invalidate EAs on reboot).

.EXAMPLE
    powershell.exe -NoProfile -File .\Build-AvdBasePolicy.ps1 -PolicyName Contoso_AVD_Base

.EXAMPLE
    powershell.exe -NoProfile -File .\Build-AvdBasePolicy.ps1 -PolicyName Contoso_AVD_Base -Enforce -Version 10.0.2.0

.NOTES
    Required: Windows PowerShell 5.1 (powershell.exe), ConfigCI module (ships with Windows 10/11 and Server),
    the template C:\Windows\schemas\CodeIntegrity\ExamplePolicies\AllowMicrosoft.xml. No Azure or Graph access.
    Traps: see README.md in this folder. Run via powershell.exe -File, not from a pwsh 7 session.
    Do not assign this base and another base policy to the same device: the two intersect and a file needs
    permission from both.
#>
[CmdletBinding()]
param(
    [string]$PolicyGuid,
    [string]$PolicyName = 'AVD_Base',
    [string]$Version = '10.0.1.0',
    [string]$OutDir,                     # default: script folder (PSScriptRoot is empty in 5.1 param defaults)
    [switch]$Enforce,
    [switch]$EnableScriptEnforcement,
    [switch]$EnableIsg
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run in Windows PowerShell 5.1 (powershell.exe). ConfigCI under pwsh 7 uses implicit remoting and fails.'
}

if (-not $OutDir) { $OutDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($PolicyName -match '--') { throw "PolicyName must not contain '--' (breaks the XML header comment)." }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$template = Join-Path $env:windir 'schemas\CodeIntegrity\ExamplePolicies\AllowMicrosoft.xml'
if (-not (Test-Path $template)) { throw "Template not found: $template" }

$xml = Join-Path $OutDir "$PolicyName.xml"

# Intune/CSP only applies a policy update with a higher VersionEx; refuse to go backwards.
# The earlier build also supplies the GUID when none is given.
$prevGuid = $null
if (Test-Path $xml) {
    [xml]$prev = Get-Content $xml -Raw -Encoding UTF8
    $prevVersion = [version]$prev.SiPolicy.VersionEx
    $prevGuid = $prev.SiPolicy.PolicyID
    if ([version]$Version -lt $prevVersion) { throw "Version $Version is lower than the existing build ($prevVersion)." }
    if ([version]$Version -eq $prevVersion) { Write-Warning "Rebuilding at the same version $Version. Bump -Version before uploading a changed policy." }
}

if ($PolicyGuid) {
    $guid = '{' + ([guid]$PolicyGuid).ToString().ToUpper() + '}'
    if ($prevGuid -and ($prevGuid -ne $guid)) { throw "PolicyGuid $guid differs from the existing build ($prevGuid). Changing the identity deploys a second base policy." }
} elseif ($prevGuid) {
    $guid = $prevGuid
} else {
    $guid = '{' + ([guid]::NewGuid()).ToString().ToUpper() + '}'
    Write-Warning "New policy identity generated: $guid. Record it; pass it as -PolicyGuid on every later build."
}
$cip = Join-Path $OutDir "$guid.cip"

Copy-Item $template $xml -Force
if (Test-Path $cip) { Remove-Item $cip -Force }

# --- Identity -----------------------------------------------------------------------------------
[xml]$doc = Get-Content $xml -Raw -Encoding UTF8
$doc.SiPolicy.PolicyID     = $guid
$doc.SiPolicy.BasePolicyID = $guid
$doc.Save($xml)

Set-CIPolicyIdInfo -FilePath $xml -PolicyName $PolicyName -PolicyId (Get-Date -Format 'yyyy-MM-dd')
Set-CIPolicyVersion -FilePath $xml -Version $Version

# --- Rule options -------------------------------------------------------------------------------
# Template already carries: 0 UMCI, 5 Inherit Default (reserved, no effect), 6 Unsigned SIP, 9 Adv Boot Menu,
# 16 Update No Reboot, 17 Allow Supplemental, 19 Dynamic Code Security (audit-safe on 24H2+).
$add = @(
    10  # Enabled:Boot Audit On Failure (a boot-start driver the policy blocks drops the whole policy to audit for that boot)
    13  # Enabled:Managed Installer (Intune Management Extension; enable the "Managed installer" tab in Intune too)
    20  # Enabled:Revoked Expired As Unsigned
)
if (-not $Enforce)                 { $add += 3 }        # Enabled:Audit Mode
if (-not $EnableScriptEnforcement) { $add += 11 }       # Disabled:Script Enforcement
if ($EnableIsg)                    { $add += 14, 15 }   # ISG + Invalidate EAs on Reboot

foreach ($o in $add) { Set-RuleOption -FilePath $xml -Option $o }
if ($Enforce)                 { Set-RuleOption -FilePath $xml -Option 3  -Delete }
if ($EnableScriptEnforcement) { Set-RuleOption -FilePath $xml -Option 11 -Delete }

# --- Header comment -----------------------------------------------------------------------------
[xml]$doc = Get-Content $xml -Raw -Encoding UTF8
$mode = if ($Enforce) { 'Enforce' } else { 'Audit' }
$scriptNote = if ($EnableScriptEnforcement) { 'enforcement ON (unsigned scripts run in CLM)' } else { 'enforcement OFF (option 11)' }
$isgNote = if ($EnableIsg) { 'ON' } else { 'OFF' }
$note = @"

  $PolicyName  v$Version  ($mode)
  Scope  : AVD session hosts (Windows 11 multi-session). Do not assign together with another base policy.
  Base   : AllowMicrosoft.xml (Windows + all Microsoft-signed code) + Managed Installer (Intune Management Extension).
  Script : $scriptNote
  ISG    : $isgNote
  Build  : Build-AvdBasePolicy.ps1, $(Get-Date -Format 'yyyy-MM-dd')

"@
$doc.InsertBefore($doc.CreateComment($note), $doc.SiPolicy) | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter($xml, $false, $utf8)
try { $doc.Save($writer) } finally { $writer.Dispose() }

# --- Validate -----------------------------------------------------------------------------------
ConvertFrom-CIPolicy -XmlFilePath $xml -BinaryFilePath $cip | Out-Null

[xml]$check = Get-Content $xml -Raw -Encoding UTF8
$opts = @($check.SiPolicy.Rules.Rule | ForEach-Object { $_.Option })

$expected = @(
    'Enabled:UMCI', 'Enabled:Unsigned System Integrity Policy', 'Enabled:Advanced Boot Options Menu',
    'Enabled:Inherit Default Policy', 'Enabled:Dynamic Code Security', 'Enabled:Update Policy No Reboot',
    'Enabled:Allow Supplemental Policies', 'Enabled:Boot Audit On Failure', 'Enabled:Managed Installer',
    'Enabled:Revoked Expired As Unsigned'
)
if (-not $Enforce)                 { $expected += 'Enabled:Audit Mode' }
if (-not $EnableScriptEnforcement) { $expected += 'Disabled:Script Enforcement' }
if ($EnableIsg)                    { $expected += 'Enabled:Intelligent Security Graph Authorization', 'Enabled:Invalidate EAs on Reboot' }

$missing = @($expected | Where-Object { $opts -notcontains $_ })
$extra   = @($opts | Where-Object { $expected -notcontains $_ })
if ($missing.Count -gt 0) { throw "Missing rule options: $($missing -join ', ')" }
if ($extra.Count -gt 0)   { throw "Unexpected rule options: $($extra -join ', ')" }
if ($check.SiPolicy.PolicyType -ne 'Base Policy')     { throw "PolicyType is '$($check.SiPolicy.PolicyType)'" }
if ($check.SiPolicy.PolicyID -ne $guid)               { throw "PolicyID is $($check.SiPolicy.PolicyID)" }
if ($check.SiPolicy.BasePolicyID -ne $guid)           { throw "BasePolicyID is $($check.SiPolicy.BasePolicyID)" }
if ($check.SiPolicy.VersionEx -ne $Version)           { throw "VersionEx is $($check.SiPolicy.VersionEx)" }
if (-not (Test-Path $cip) -or (Get-Item $cip).Length -eq 0) { throw "Binary not produced: $cip" }

[pscustomobject]@{
    Policy   = $PolicyName
    PolicyID = $guid
    Version  = $Version
    Mode     = $mode
    Options  = ($opts | Sort-Object) -join '; '
    Xml      = $xml
    Cip      = $cip
}
