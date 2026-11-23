<#
.SYNOPSIS
Reads the facts you need to package a Win32 app from an MSI or EXE: MSI properties, platform, hash, Authenticode signer chain and ready-made Intune detection rules.

.DESCRIPTION
Read-only. For an .msi it opens the Windows Installer database through the WindowsInstaller COM object and reads
ProductName, ProductVersion, ProductCode, UpgradeCode, Manufacturer, ALLUSERS, ARPSYSTEMCOMPONENT and the package
platform (Summary Information Template: Intel / x64 / Arm64). Any other Property table row can be added with
-Property, or all rows dumped with -AllProperties. For every file type it reports size, SHA256, the Authenticode
status, signer, thumbprint, certificate chain and time stamper, and (for an EXE) the file and product version.

It then prints the values for the Intune "Detection rules" page: the MSI rule (ProductCode, product version check
off by default), the equivalent registry rule on the Uninstall key, and for an EXE a file rule. Use it before
Build-Win32Package.ps1: that script reads the same MSI properties to generate install and uninstall commands; this one
shows more (platform, all rows, signer chain, detection) and also accepts an EXE. The two are independent; neither
needs the other.

Warnings are printed for the traps that cause reinstall loops or silent failures: an unsigned file, an invalid
signature, an MSI that leaves ALLUSERS empty (per-user install, wrong for SYSTEM context), a 32-bit MSI (registry
rules need the WOW6432Node view) and a missing ProductCode.

.PARAMETER Path
Path to the .msi or .exe (or any file; non-MSI files get signature, hash and version only).

.PARAMETER Property
Extra rows of the MSI Property table to read, for example SERVER or INSTALL_ROOT. Missing rows are reported as empty.

.PARAMETER AllProperties
Dump the whole MSI Property table (sorted). Public properties are upper case; they are what you can set on the msiexec command line.

.PARAMETER OutFile
Also write the result as JSON to this path.

.PARAMETER RequireSigned
Throw when the file has no valid Authenticode signature. Use it in a packaging pipeline.

.EXAMPLE
.\Inspect-Msi.ps1 -Path C:\Work\app\src\app.msi

.EXAMPLE
.\Inspect-Msi.ps1 -Path .\setup.exe -RequireSigned -OutFile .\evidence\setup-info.json

.EXAMPLE
.\Inspect-Msi.ps1 -Path .\app.msi -Property SERVER, INSTALL_ROOT -AllProperties

.NOTES
Needs Windows (WindowsInstaller COM object). No role, no network, no changes to the machine; the MSI is opened read-only.
Windows PowerShell 5.1 or pwsh 7. Never invent a ProductCode: copy it from this output.
Traps kept from real packaging work:
- The MSI detection rule must leave "product version check" OFF for apps that update themselves; a "version equals"
  rule flips to not-detected after the first auto-update and Intune reinstalls in a loop (0x87D1041C).
- ProductVersion in the MSI is the MSI version (3 fields compared by Windows Installer), not always the file or ARP display version.
- A signed MSI with an expired signer certificate still reports "Valid" when it carries a trusted time stamp; check TimeStamper.
- A 32-bit MSI on 64-bit Windows registers under WOW6432Node; a plain registry detection rule misses it unless
  "associated with a 32-bit app on 64-bit clients" is set.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Path,
    [string[]]$Property,
    [switch]$AllProperties,
    [string]$OutFile,
    [switch]$RequireSigned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ((Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -eq $false) { throw 'Windows only (WindowsInstaller COM object).' }   # 5.1 has no $IsWindows
$file = (Resolve-Path -LiteralPath $Path).Path
$item = Get-Item -LiteralPath $file
$warnings = [System.Collections.Generic.List[string]]::new()

function Invoke-Com($obj, [string]$member, [string]$kind, $arguments) {
    $obj.GetType().InvokeMember($member, $kind, $null, $obj, $arguments)
}

# --- MSI database -------------------------------------------------------------------------------
$msi = $null
if ($item.Extension -ieq '.msi') {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = Invoke-Com $installer 'OpenDatabase' 'InvokeMethod' @($file, 0)   # 0 = msiOpenDatabaseModeReadOnly

    function Get-MsiRows([string]$Query) {
        $view = Invoke-Com $db 'OpenView' 'InvokeMethod' @($Query)
        [void](Invoke-Com $view 'Execute' 'InvokeMethod' $null)
        $rows = @()
        while ($rec = Invoke-Com $view 'Fetch' 'InvokeMethod' $null) {
            $rows += , @((Invoke-Com $rec 'StringData' 'GetProperty' 1), (Invoke-Com $rec 'StringData' 'GetProperty' 2))
        }
        [void](Invoke-Com $view 'Close' 'InvokeMethod' $null)
        $rows
    }
    function Get-MsiProp([string]$Name) {
        if ($Name -notmatch '^[A-Za-z0-9_.]+$') { throw "Invalid property name: $Name" }   # it goes into a SQL string
        $r = Get-MsiRows "SELECT Property, Value FROM Property WHERE Property='$Name'"
        if ($r.Count) { $r[0][1] } else { $null }
    }

    $props = [ordered]@{}
    foreach ($p in @('ProductName', 'ProductVersion', 'ProductCode', 'UpgradeCode', 'Manufacturer', 'ALLUSERS', 'ARPSYSTEMCOMPONENT') + @($Property)) {
        if ($p) { $props[$p] = Get-MsiProp $p }
    }
    $all = $null
    if ($AllProperties) {
        $all = [ordered]@{}
        foreach ($r in (Get-MsiRows 'SELECT Property, Value FROM Property' | Sort-Object { $_[0] })) { $all[$r[0]] = $r[1] }
    }

    # Summary Information property 7 = Template, "Intel", "x64", "Arm64" or "Intel;1033" (platform;languages)
    $summary = Invoke-Com $db 'SummaryInformation' 'GetProperty' 0
    $template = [string](Invoke-Com $summary 'Property' 'GetProperty' 7)
    $platform = ($template -split ';')[0]
    $msi = [ordered]@{ Properties = $props; Platform = $platform; AllProperties = $all }

    if (-not $props['ProductCode']) { $warnings.Add('No ProductCode row: MSI detection and msiexec /x cannot be used.') }
    if (-not $props['ALLUSERS']) { $warnings.Add('ALLUSERS is empty: the MSI installs per user unless the command line sets ALLUSERS=1. Intune runs as SYSTEM; test the install context.') }
    if ($platform -eq 'Intel') { $warnings.Add('32-bit MSI (Template=Intel): on 64-bit Windows it registers under WOW6432Node; tick "32-bit app on 64-bit client" on registry rules.') }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
}

# --- Signature, hash, version -------------------------------------------------------------------
$sig = Get-AuthenticodeSignature -LiteralPath $file
$chain = @()
if ($sig.SignerCertificate) {
    $x = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    [void]$x.Build($sig.SignerCertificate)
    $chain = @($x.ChainElements | ForEach-Object { $_.Certificate.Subject })
}
if ($sig.Status -eq 'NotSigned') { $warnings.Add('File is not signed.') }
elseif ($sig.Status -ne 'Valid') { $warnings.Add("Signature status is $($sig.Status): $($sig.StatusMessage)") }
if ($RequireSigned -and $sig.Status -ne 'Valid') { throw "RequireSigned: signature status is $($sig.Status) for $file" }

$vi = $item.VersionInfo
$result = [ordered]@{
    File             = $item.Name
    SizeBytes        = $item.Length
    SHA256           = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    SignatureStatus  = "$($sig.Status)"
    Signer           = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
    SignerThumbprint = if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null }
    SignerNotAfter   = if ($sig.SignerCertificate) { $sig.SignerCertificate.NotAfter.ToString('o') } else { $null }
    Chain            = $chain
    TimeStamper      = if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { $null }
    FileVersion      = $vi.FileVersion
    ProductVersion   = $vi.ProductVersion
}
if ($msi) {
    $result['MsiPlatform'] = $msi.Platform
    $result['MsiProperties'] = $msi.Properties
    if ($msi.AllProperties) { $result['MsiAllProperties'] = $msi.AllProperties }
}

# --- Detection rules for the Intune wizard ------------------------------------------------------
$det = [ordered]@{}
if ($msi -and $msi.Properties['ProductCode']) {
    $pc = $msi.Properties['ProductCode']
    $det['MsiRule'] = "Rules format: MSI. MSI product code: $pc. MSI product version check: No (Yes only for apps that never update themselves)."
    $det['RegistryRule'] = "Key: HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$pc, detection method: key exists" + $(if ($msi.Platform -eq 'Intel') { ' (32-bit app on 64-bit client: Yes)' } else { '' })
    $det['UninstallCommand'] = "msiexec /x $pc /qn /norestart /l*v `"C:\Windows\Temp\app_uninstall.log`""
    $det['InstallCommand'] = "msiexec /i `"$($item.Name)`" /qn /norestart /l*v `"C:\Windows\Temp\app_install.log`""
}
elseif ($item.Extension -ieq '.exe') {
    $det['FileRule'] = "Path: <install folder>, file or folder: $($item.Name), detection method: File or folder exists (or version >= $($vi.FileVersion) if the app does not self-update)."
}
if ($det.Count) { $result['Detection'] = $det }
$result['Warnings'] = @($warnings)
$result['CapturedAt'] = (Get-Date).ToString('o')

if ($OutFile) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    New-Item -ItemType Directory -Force (Split-Path -Parent $full) | Out-Null
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $full -Encoding utf8
}
$warnings | ForEach-Object { Write-Warning $_ }
[pscustomobject]$result
