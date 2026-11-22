#Requires -Version 5.1
<#
.SYNOPSIS
    Builds an Intune Win32 app package (.intunewin) with IntuneWinAppUtil, after checking the source files.

.DESCRIPTION
    Wraps Microsoft's Win32 Content Prep Tool (IntuneWinAppUtil.exe) with the checks that are easy to forget:

      * Source integrity: optional SHA256 pin (-ExpectedSha256) and an Authenticode check of the installer
        (-VerifyFile, default the MSI). An invalid or missing signature stops the build unless -AllowUnsigned.
      * Secret guard: -SecretFile (for example a TLS pre-shared key file that is packaged next to the installer)
        must exist and match -SecretPattern. Only the format is checked; the content is never printed.
      * MSI inspection: ProductCode, UpgradeCode, ProductVersion, Manufacturer are read through the
        WindowsInstaller COM object and printed with the signer and chain, ready to paste into the Intune wizard.
      * Command generation (-GenerateCmd): writes install.cmd and uninstall.cmd into the source folder from
        the templates pattern in Templates\ (SYSTEM context, 64-bit paths, logging, 3010 tolerated, 1605 on uninstall
        treated as success). Existing files are never overwritten without -Force.
      * Detection stub (-DetectionStub): writes Detect.ps1 for an Intune custom detection script (MSI product code
        in the uninstall key, or file version), for use when the built-in MSI rule is not enough.
      * Tool handling: -ToolPath, or -DownloadTool to fetch the pinned release from Microsoft's GitHub repository
        and verify that it is signed by Microsoft.
      * Output check: the .intunewin must exist and be non-empty; its SHA256 and size are returned.

    The script builds the package only. It never uploads anything to Intune.

.PARAMETER SourceDir
    Folder with everything the package needs (installer, install.cmd, config files). The whole folder is packaged.

.PARAMETER SetupFile
    The setup file inside SourceDir that Intune runs (install.cmd, setup.exe or a .msi). It names the .intunewin.

.PARAMETER OutDir
    Output folder for the .intunewin. Default: .\out next to SourceDir.

.PARAMETER ToolPath
    Path to IntuneWinAppUtil.exe. Default: .\IntuneWinAppUtil.exe if present.

.PARAMETER DownloadTool
    Download the pinned IntuneWinAppUtil release (-ToolVersion) next to the script when ToolPath does not exist.

.PARAMETER ToolVersion
    Release tag of microsoft/Microsoft-Win32-Content-Prep-Tool to download. Default v1.8.7.

.PARAMETER VerifyFile
    File in SourceDir whose hash and signature are checked. Default: the first *.msi in SourceDir, else SetupFile.

.PARAMETER ExpectedSha256
    Expected SHA256 of VerifyFile (from the vendor's download page or your change record).

.PARAMETER AllowUnsigned
    Accept an unsigned VerifyFile. Without it an unsigned or invalid file stops the build.

.PARAMETER SecretFile
    File in SourceDir that must exist and pass the SecretPattern format check (content never printed).

.PARAMETER SecretPattern
    Regex the secret file's trimmed content must match. Default: 32 to 512 hex characters on one line.

.PARAMETER GenerateCmd
    Generate install.cmd and uninstall.cmd for -VerifyFile when it is an MSI.

.PARAMETER MsiProperties
    MSI properties for the generated install.cmd, for example @{ SERVER = '192.0.2.10'; LISTENPORT = '10050' }.
    Do not put secrets here; they would land in a file that is stored in the tenant.

.PARAMETER DetectionStub
    Write Detect.ps1 (custom detection script) into OutDir.

.PARAMETER Force
    Overwrite generated files that already exist.

.EXAMPLE
    .\Build-Win32Package.ps1 -SourceDir C:\Work\app\src -SetupFile app.msi -DownloadTool

.EXAMPLE
    .\Build-Win32Package.ps1 -SourceDir C:\Work\agent\src -SetupFile install.cmd -ToolPath C:\Tools\IntuneWinAppUtil.exe `
        -ExpectedSha256 0000000000000000000000000000000000000000000000000000000000000000 `
        -SecretFile psk.key -GenerateCmd -MsiProperties @{ SERVER = '192.0.2.10'; TLSCONNECT = 'psk' }

.NOTES
    Required: Windows PowerShell 5.1 or pwsh 7 on Windows (WindowsInstaller COM, IntuneWinAppUtil.exe). No Azure or Graph access.
    Traps: IntuneWinAppUtil names the output after the setup file (install.cmd gives install.intunewin) and an
    existing output is not replaced reliably, so it is deleted first. The Intune Management Extension starts
    cmd scripts with a 32-bit cmd, where %ProgramFiles% points to Program Files (x86); the generated scripts
    use %ProgramW6432%. Delete the secret file from SourceDir when the package is built.
    Delivery standard and Intune wizard values: see Win32-Packaging.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$SetupFile,
    [string]$OutDir,
    [string]$ToolPath,
    [switch]$DownloadTool,
    [string]$ToolVersion = 'v1.8.7',
    [string]$VerifyFile,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256,
    [switch]$AllowUnsigned,
    [string]$SecretFile,
    [string]$SecretPattern = '^[0-9a-fA-F]{32,512}$',
    [switch]$GenerateCmd,
    [hashtable]$MsiProperties,
    [switch]$DetectionStub,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SourceDir = (Resolve-Path $SourceDir).Path
if (-not (Test-Path (Join-Path $SourceDir $SetupFile))) { throw "SetupFile not found in SourceDir: $SetupFile" }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $SourceDir -Parent) 'out' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-MsiInfo([string]$Msi) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Msi, 0))
    $props = [ordered]@{}
    foreach ($name in 'ProductName', 'ProductVersion', 'ProductCode', 'UpgradeCode', 'Manufacturer', 'ALLUSERS', 'ARPSYSTEMCOMPONENT') {
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$name'"))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        $props[$name] = if ($rec) { $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) } else { $null }
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    }
    $props
}

# --- 1. Tool -------------------------------------------------------------------------------------
if (-not $ToolPath) { $ToolPath = Join-Path $here 'IntuneWinAppUtil.exe' }
if (-not (Test-Path $ToolPath)) {
    if (-not $DownloadTool) { throw "IntuneWinAppUtil.exe not found at $ToolPath. Pass -ToolPath or -DownloadTool." }
    $url = "https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/$ToolVersion/IntuneWinAppUtil.exe"
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $ToolPath -UseBasicParsing
}
$toolSig = Get-AuthenticodeSignature $ToolPath
if ($toolSig.Status -ne 'Valid' -or $toolSig.SignerCertificate.Subject -notmatch 'Microsoft') {
    throw "IntuneWinAppUtil.exe is not validly signed by Microsoft (status $($toolSig.Status), signer $($toolSig.SignerCertificate.Subject))."
}
Write-Host ("Tool: {0} (file version {1})" -f $ToolPath, (Get-Item $ToolPath).VersionInfo.FileVersion)

# --- 2. Source checks ----------------------------------------------------------------------------
if (-not $VerifyFile) {
    $msi = @(Get-ChildItem $SourceDir -Filter *.msi -File)
    $VerifyFile = if ($msi.Count -ge 1) { $msi[0].Name } else { $SetupFile }
}
$verifyPath = Join-Path $SourceDir $VerifyFile
if (-not (Test-Path $verifyPath)) { throw "VerifyFile not found: $verifyPath" }

$hash = (Get-FileHash $verifyPath -Algorithm SHA256).Hash
if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.ToUpper()) { throw "SHA256 mismatch for $VerifyFile. Expected $ExpectedSha256, got $hash." }

$sig = Get-AuthenticodeSignature $verifyPath
if ($sig.Status -ne 'Valid') {
    if ($AllowUnsigned -and $sig.Status -eq 'NotSigned') { Write-Warning "$VerifyFile is NOT signed (allowed by -AllowUnsigned)." }
    else { throw "$VerifyFile signature status is $($sig.Status). Fix or replace the installer, or pass -AllowUnsigned for NotSigned." }
}

$msiInfo = $null
if ($verifyPath -like '*.msi') { $msiInfo = Get-MsiInfo $verifyPath }

Write-Host "Source file : $VerifyFile"
Write-Host "SHA256      : $hash"
if ($sig.SignerCertificate) {
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    [void]$chain.Build($sig.SignerCertificate)
    Write-Host "Signature   : $($sig.Status), $($sig.SignerCertificate.Subject)"
    Write-Host "Thumbprint  : $($sig.SignerCertificate.Thumbprint)"
    Write-Host ("Chain       : " + (($chain.ChainElements | ForEach-Object { $_.Certificate.Subject }) -join '  <  '))
}
if ($msiInfo) { $msiInfo.GetEnumerator() | ForEach-Object { Write-Host ("MSI {0,-18}: {1}" -f $_.Key, $_.Value) } }

if ($SecretFile) {
    $sp = Join-Path $SourceDir $SecretFile
    if (-not (Test-Path $sp)) { throw "Secret file not found in SourceDir: $SecretFile" }
    $txt = (Get-Content $sp -Raw).Trim()
    if ($txt -notmatch $SecretPattern) { throw "Secret file $SecretFile does not match the expected format (content not shown)." }
    Remove-Variable txt
    Write-Warning "$SecretFile is inside SourceDir and will be packaged. Delete it from SourceDir once the package is built."
}

# --- 3. Generated install / uninstall commands ---------------------------------------------------
if ($GenerateCmd) {
    if (-not $msiInfo) { throw '-GenerateCmd needs an MSI as VerifyFile.' }
    $name = ($msiInfo['ProductName'] -replace '[^A-Za-z0-9]', '')
    $propText = ''
    if ($MsiProperties) { $propText = ($MsiProperties.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ' ' }
    $install = @"
@echo off
rem $($msiInfo['ProductName']) $($msiInfo['ProductVersion']) - Intune Win32 install (SYSTEM context)
setlocal
set "LOG=%ProgramData%\Microsoft\IntuneManagementExtension\Logs\$name-install.log"
msiexec /i "%~dp0$VerifyFile" /qn /norestart $propText /l*v "%LOG%"
set "RC=%ERRORLEVEL%"
rem 3010 = success, reboot pending: let Intune apply the restart behaviour
if "%RC%"=="3010" exit /b 3010
exit /b %RC%
"@
    $uninstall = @"
@echo off
rem $($msiInfo['ProductName']) - Intune Win32 uninstall (SYSTEM context)
msiexec /x $($msiInfo['ProductCode']) /qn /norestart /l*v "%ProgramData%\Microsoft\IntuneManagementExtension\Logs\$name-uninstall.log"
set "RC=%ERRORLEVEL%"
rem 1605 = product not installed: already gone, treat as success
if "%RC%"=="1605" exit /b 0
exit /b %RC%
"@
    foreach ($pair in @(@('install.cmd', $install), @('uninstall.cmd', $uninstall))) {
        $path = Join-Path $SourceDir $pair[0]
        if ((Test-Path $path) -and -not $Force) { Write-Warning "$($pair[0]) exists, not overwritten (use -Force)."; continue }
        Set-Content -Path $path -Value $pair[1] -Encoding Ascii
        Write-Host "Wrote $path"
    }
}

# --- 4. Package ----------------------------------------------------------------------------------
$pkg = Join-Path $OutDir (([IO.Path]::GetFileNameWithoutExtension($SetupFile)) + '.intunewin')
if (Test-Path $pkg) { Remove-Item $pkg -Force }
& $ToolPath -c $SourceDir -s $SetupFile -o $OutDir -q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil exited with code $LASTEXITCODE" }
if (-not (Test-Path $pkg) -or (Get-Item $pkg).Length -eq 0) { throw "Package was not produced: $pkg" }

# --- 5. Detection stub ---------------------------------------------------------------------------
if ($DetectionStub) {
    $detect = Join-Path $OutDir 'Detect.ps1'
    if ((Test-Path $detect) -and -not $Force) { Write-Warning 'Detect.ps1 exists, not overwritten (use -Force).' }
    else {
        $code = if ($msiInfo) { $msiInfo['ProductCode'] } else { '{REPLACE-WITH-PRODUCT-CODE}' }
        $ver = if ($msiInfo) { $msiInfo['ProductVersion'] } else { '0.0.0' }
        $stub = @"
# Intune custom detection script. Exit 0 AND write to stdout = detected. Anything else = not detected.
# Runs in 64-bit PowerShell only if "Run script as 32-bit" is set to No in the Intune wizard.
`$ErrorActionPreference = 'Stop'
`$productCode = '$code'
`$minVersion  = [version]'$ver'
`$key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`$productCode"
if (-not (Test-Path `$key)) { exit 1 }
`$v = (Get-ItemProperty `$key).DisplayVersion
# A self-updating app can be newer than the packaged version: compare with -ge, never -eq.
if (`$v -and ([version]`$v -ge `$minVersion)) { Write-Output "Detected `$v"; exit 0 }
exit 1
"@
        Set-Content -Path $detect -Value $stub -Encoding UTF8
        Write-Host "Wrote $detect"
    }
}

$item = Get-Item $pkg
[pscustomobject]@{
    Package     = $item.FullName
    SizeBytes   = $item.Length
    PackageSha256 = (Get-FileHash $pkg -Algorithm SHA256).Hash
    SourceFile  = $VerifyFile
    SourceSha256 = $hash
    ProductCode = if ($msiInfo) { $msiInfo['ProductCode'] } else { $null }
    ProductVersion = if ($msiInfo) { $msiInfo['ProductVersion'] } else { $null }
}
