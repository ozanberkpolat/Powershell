#Requires -Version 5.1
<#
.SYNOPSIS
    Post-install / post-update health test for a Win32 desktop app: binary version, duplicate installs, uninstall
    entries, the "Open with" shell verb (machine and per-user) and Explorer context-menu handler DLLs.

.DESCRIPTION
    An update that "succeeded" can still leave a broken app: the version on disk is old, a second copy in the other
    Program Files folder wins, or the shell verb / context-menu handler still points at a DLL the update removed, so
    right-click "Open with <app>" fails for every user. This script checks the things that broke in practice and
    returns one object with every check and an overall Pass. It changes nothing.

    Checks
      Exe          ExePath exists; its file version is at least MinimumVersion.
      OtherArch    No copy of the same exe under the other Program Files folder (x64 vs x86 side by side is a
                   duplicate install; the older one often keeps the file associations).
      Uninstall    Entries whose DisplayName matches DisplayNamePattern, in the 64-bit and 32-bit registry views.
                   None, or more than one, is reported.
      ShellVerb    HKLM ...\Classes\Applications\<exe>\shell\open\command (both views) points to ExePath. Per-user
                   overrides in every LOADED user hive are listed and must point to ExePath too (a stale per-user
                   override beats a correct machine value). Unloaded profiles are listed as not checked.
      Handlers     Context-menu handlers (HKLM ...\Classes\*\shellex\ContextMenuHandlers) whose CLSID's InprocServer32
                   DLL lives in the app folder or matches HandlerDllPattern: the DLL must exist.
      RequiredFile Files that must exist next to the exe (RequiredFile, wildcards allowed).

.PARAMETER ExePath
    Full path of the app's main executable, for example C:\Program Files\Contoso Editor\editor.exe.

.PARAMETER MinimumVersion
    Lowest acceptable file version. Compared as a version, never as a string prefix.

.PARAMETER DisplayNamePattern
    Regex for the app's uninstall entry DisplayName. Default: the exe's product name.

.PARAMETER HandlerDllPattern
    Extra regex for context-menu handler DLL paths that belong to the app (for handlers registered outside its folder).

.PARAMETER RequiredFile
    File names (wildcards allowed) that must exist in the exe's folder, for example 'EditorShell*.dll'.

.PARAMETER SkipShellVerb
    The app registers no "Applications\<exe>" open verb; skip that check.

.PARAMETER ExitCode
    Print one summary line and exit 0 (pass) or 1 (fail), for Intune Remediations detection or Run Command.

.EXAMPLE
    .\Test-AppInstallHealth.ps1 -ExePath 'C:\Program Files\Contoso Editor\editor.exe' -MinimumVersion 8.6.0 -RequiredFile 'EditorShell*.dll'

.EXAMPLE
    # As a Remediations detection script body (no parameters there: wrap the call)
    & .\Test-AppInstallHealth.ps1 -ExePath 'C:\Program Files\Contoso Editor\editor.exe' -MinimumVersion 8.6.0 -ExitCode

.NOTES
    UNTESTED: the generic context-menu handler and per-user hive checks are new code against a one-app diagnostic; run it
    on a known-good and a known-broken device first.
    Read-only. Run elevated or as SYSTEM to read every hive; works in Windows PowerShell 5.1 and pwsh 7, 32-bit or 64-bit
    host (registry views are opened explicitly; the 64-bit Program Files comes from ProgramW6432).
    Traps from production use: the x86 Program Files path must be read as ${env:ProgramFiles(x86)} ("$env:ProgramFiles(x86)"
    expands ProgramFiles and appends a literal "(x86)"); a version check with -like "8.6*" accepts 8.60; Windows 11's
    modern context menu is an MSIX sparse package (listed under Appx, informational only); HKCR is a merged view, so
    machine and per-user values are read separately here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExePath,
    [Parameter(Mandatory)][version]$MinimumVersion,
    [string]$DisplayNamePattern,
    [string]$HandlerDllPattern,
    [string[]]$RequiredFile,
    [switch]$SkipShellVerb,
    [switch]$ExitCode
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) { $checks.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail }) }
function Open-Hklm([Microsoft.Win32.RegistryView]$View, [string]$Path) {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View).OpenSubKey($Path)
}
$views = [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32
function Test-SamePath([string]$Command, [string]$Path) { $Command -and $Command.ToLowerInvariant().Contains($Path.ToLowerInvariant()) }

$exeName = Split-Path $ExePath -Leaf
$appDir = Split-Path $ExePath -Parent

# --- Exe and version -----------------------------------------------------------------------------
$productName = $null
if (Test-Path -LiteralPath $ExePath) {
    $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
    $productName = $vi.ProductName
    $ver = New-Object version $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart
    Add-Check 'Exe' ($ver -ge $MinimumVersion) "version $ver (minimum $MinimumVersion)"
} else {
    Add-Check 'Exe' $false "$ExePath not found"
}

# --- Other architecture --------------------------------------------------------------------------
$pf64 = $env:ProgramW6432; $pf86 = ${env:ProgramFiles(x86)}
if ($pf64 -and $pf86) {
    $other = $null
    if ($ExePath.StartsWith($pf64, [StringComparison]::OrdinalIgnoreCase)) { $other = $pf86 + $ExePath.Substring($pf64.Length) }
    elseif ($ExePath.StartsWith($pf86, [StringComparison]::OrdinalIgnoreCase)) { $other = $pf64 + $ExePath.Substring($pf86.Length) }
    if ($other) {
        $dup = Test-Path -LiteralPath $other
        Add-Check 'OtherArch' (-not $dup) $(if ($dup) { "second copy at $other (v$((Get-Item -LiteralPath $other).VersionInfo.FileVersion))" } else { 'no copy in the other Program Files folder' })
    }
}

# --- Uninstall entries ---------------------------------------------------------------------------
if (-not $DisplayNamePattern) { $DisplayNamePattern = if ($productName) { [regex]::Escape($productName) } else { [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($exeName)) } }
$entries = @(foreach ($v in $views) {
    $root = Open-Hklm $v 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    if (-not $root) { continue }
    foreach ($n in $root.GetSubKeyNames()) {
        $k = $root.OpenSubKey($n)
        $dn = if ($k) { [string]$k.GetValue('DisplayName') } else { '' }
        if ($dn -and $dn -match $DisplayNamePattern) { "$dn $($k.GetValue('DisplayVersion')) [$v, $n]" }
    }
})
$entries = @($entries | Sort-Object -Unique)
Add-Check 'Uninstall' ($entries.Count -eq 1) $(if ($entries.Count) { $entries -join '; ' } else { "no entry matching '$DisplayNamePattern'" })

# --- Shell verb ------------------------------------------------------------------------------------
if (-not $SkipShellVerb) {
    $verbPath = "SOFTWARE\Classes\Applications\$exeName\shell\open\command"
    $machine = @(foreach ($v in $views) { $k = Open-Hklm $v $verbPath; if ($k) { [pscustomobject]@{ Where = "HKLM $v"; Cmd = [string]$k.GetValue('') } } })
    if ($machine.Count -eq 0) { Add-Check 'ShellVerb' $false "machine key missing: HKLM\$verbPath" }
    foreach ($m in $machine) { Add-Check 'ShellVerb' (Test-SamePath $m.Cmd $ExePath) "$($m.Where): $($m.Cmd)" }

    $profiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | Where-Object { $_.PSChildName -like 'S-1-5-21-*' }
    $unloaded = 0
    foreach ($p in $profiles) {
        $sid = $p.PSChildName
        $hive = [Microsoft.Win32.Registry]::Users.OpenSubKey($sid)
        if (-not $hive) { $unloaded++; continue }
        $k = $hive.OpenSubKey("SOFTWARE\Classes\Applications\$exeName\shell\open\command")
        if ($k) { $cmd = [string]$k.GetValue(''); Add-Check 'ShellVerbUser' (Test-SamePath $cmd $ExePath) "$sid override: $cmd" }
    }
    if ($unloaded) { Write-Verbose "$unloaded user profile(s) not loaded; their per-user overrides were not checked." }
}

# --- Context-menu handlers ---------------------------------------------------------------------------
foreach ($v in $views) {
    $cmh = Open-Hklm $v 'SOFTWARE\Classes\*\shellex\ContextMenuHandlers'
    if (-not $cmh) { continue }
    foreach ($n in $cmh.GetSubKeyNames()) {
        $clsid = [string]$cmh.OpenSubKey($n).GetValue('')
        if ($clsid -notmatch '^\{') { $clsid = $n }
        if ($clsid -notmatch '^\{') { continue }
        $srv = Open-Hklm $v "SOFTWARE\Classes\CLSID\$clsid\InprocServer32"
        if (-not $srv) { continue }
        $dll = ([Environment]::ExpandEnvironmentVariables([string]$srv.GetValue(''))).Trim('"')
        $mine = $dll -and ($dll.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) -or ($HandlerDllPattern -and $dll -match $HandlerDllPattern))
        if ($mine) { Add-Check 'Handlers' (Test-Path -LiteralPath $dll) "$n [$v] $dll" }
    }
}

# --- Required files ----------------------------------------------------------------------------------
foreach ($f in @($RequiredFile | Where-Object { $_ })) {
    $hit = @(Get-ChildItem -LiteralPath $appDir -Filter $f -File -ErrorAction SilentlyContinue)
    Add-Check 'RequiredFile' ($hit.Count -gt 0) "$f in ${appDir}: $(if ($hit.Count) { ($hit | ForEach-Object { $_.Name }) -join ', ' } else { 'missing' })"
}

# --- Informational: modern (Windows 11) context menu packages -----------------------------------------
$appx = @()
try { $appx = @(Get-AppxPackage -AllUsers | Where-Object { $_.InstallLocation -and $_.InstallLocation.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$($_.Name) $($_.Version)" }) }
catch { Write-Verbose "Appx query skipped: $($_.Exception.Message)" }   # 32-bit host or no Appx module: informational only

$failed = @($checks | Where-Object { -not $_.Ok })
$result = [pscustomobject]@{
    Computer = $env:COMPUTERNAME; ExePath = $ExePath; Pass = ($failed.Count -eq 0)
    Failed = @($failed | ForEach-Object { "$($_.Check): $($_.Detail)" }); Checks = $checks.ToArray(); AppxPackages = $appx
}
if ($ExitCode) {
    if ($result.Pass) { Write-Output "PASS $exeName ($($checks.Count) checks)"; exit 0 }
    Write-Output ("FAIL ${exeName}: " + ($result.Failed -join ' | '))
    exit 1
}
$result
