#Requires -Version 7.0
<#
.SYNOPSIS
    Update a desktop application (EXE installer) on many Windows VMs through Run Command, in waves, with
    in-use handling and a post-install check that does not trust the installer exit code.

.DESCRIPTION
    Generalised from a fleet-wide remediation of a text editor finding. Per VM, a guest script running as SYSTEM:

      Detect (sent first, read-only; also what -DetectOnly runs)
        - refuses a machine with a 32-bit copy installed (X86-PRESENT) unless -AllowX86: removing a 32-bit
          copy can delete the "Open with" registration that the 64-bit installer does not recreate;
        - skips Windows multi-session hosts (SKIPPED-MULTISESSION) unless -AllowMultiSession;
        - refuses a 64-bit install that is not at -ExePath (NONSTANDARD-PATH): the installer reuses the old
          install folder, so the update would land elsewhere and the version check would fail;
        - compares versions on 4 numeric parts (ALREADYCURRENT runs the same checks read-only);
        - the application running: SKIPPED-INUSE (default) or, with -InUse PoliteClose, WOULD-UPDATE.
      Only VMs that answer WOULD-UPDATE receive the installer (Push-InstallerViaRunCommand.ps1: base64
      chunks, length and SHA-256 verified), so nothing is shipped to a current or busy machine.
      Install
        - optional polite close in each user's own session (see NOTES), then the silent installer with a
          bounded wait (an installer still running at the timeout is left alone, never killed);
        - success is NOT the exit code. All of:
            (a) the file version of -ExePath equals -TargetVersion;
            (b) with -OpenWith Check/Repair: HKLM\SOFTWARE\Classes\Applications\<exe>\shell\open\command is
                exactly "<ExePath>" "%1";
            (c) with -ShellExtensionClsid: that CLSID's InprocServer32 DLL is under -ShellExtensionDir and exists.
          (a) or (c) failing stops with FAIL-VERSION / FAIL-SHELLEXT. (b) failing is FAIL-OPENCMD, or with
          -OpenWith Repair the key is written, read back and reported UPDATED-REPAIRED. The pre-repair state
          (key existed, kind, base64 of the old value, topmost key created) is in the STATUS line so the
          write can be reverted exactly.

    Waves: a Wave column in -TargetsCsv groups VMs (pilot, nonprod, prod ...), processed in file order of
    first appearance. After each wave, any VM whose code is not in -GateCodes stops the run before the next
    wave.

    Every VM ends with ONE line STATUS=<CODE>;host=...;k=v. Failure codes never contain the words UPDATED
    or ALREADYCURRENT, so a substring match on those cannot turn a failure green.
    Codes: UPDATED-PASS, UPDATED-REPAIRED, ALREADYCURRENT, WOULD-UPDATE, NOTINSTALLED, SKIPPED-INUSE,
    SKIPPED-MULTISESSION, X86-PRESENT, NONSTANDARD-PATH, FAIL-VERSION, FAIL-SHELLEXT, FAIL-OPENCMD,
    REPAIR-UNVERIFIED, CURRENT-FAIL-OPENCMD, CURRENT-FAIL-SHELLEXT, FAILED.

.PARAMETER TargetsCsv
    CSV with ResourceId (or Name + ResourceGroup + Subscription) and an optional Wave column.
.PARAMETER VmName
    Instead of a CSV: VM names (+ -ResourceGroup / -Subscription). One wave.
.PARAMETER InstallerPath
    Local installer file (EXE). Not needed with -DetectOnly.
.PARAMETER TargetVersion
    Version the update must reach, for example 8.9.8.1. Compared on 4 numeric parts.
.PARAMETER DisplayName
    Wildcard for the uninstall DisplayName, for example 'Notepad++*'.
.PARAMETER ExePath
    Where the 64-bit executable must be, for example 'C:\Program Files\Notepad++\notepad++.exe'.
.PARAMETER ProcessName
    Process name meaning "in use". Default: the exe file name without .exe.
.PARAMETER InstallerArguments
    Silent switches. Default /S (NSIS). Inno Setup: '/VERYSILENT /NORESTART'. MSI packages are out of scope.
.PARAMETER InstallTimeoutMinutes
    Bounded wait for the installer. Default 10.
.PARAMETER InUse
    Defer (default): a running application means SKIPPED-INUSE. PoliteClose: close it in the user's session first.
.PARAMETER OpenWith
    Off (default), Check or Repair for the Applications\<exe>\shell\open\command key.
.PARAMETER ShellExtensionClsid
    CLSID of the application's shell extension to verify, with -ShellExtensionDir.
.PARAMETER ShellExtensionDir
    Folder the shell extension DLL must be in, for example 'C:\Program Files\Notepad++\contextMenu\'.
.PARAMETER AllowX86
    Do not refuse machines that also have a 32-bit copy.
.PARAMETER AllowMultiSession
    Also update Windows multi-session hosts (AVD). Do this in a drain window.
.PARAMETER DetectOnly
    Only run the detect script everywhere and report. Nothing is sent or changed.
.PARAMETER GateCodes
    Codes that let the next wave start.
.PARAMETER Throttle
    VMs in parallel within a wave. Default 5.
.PARAMETER OutputFolder
    Result CSVs per wave and a summary. Default ./app-update-<timestamp>.

.EXAMPLE
    # Read-only first
    ./Windows/Update-AppViaRunCommand.ps1 -TargetsCsv ./targets.csv -DisplayName 'Notepad++*' `
        -ExePath 'C:\Program Files\Notepad++\notepad++.exe' -TargetVersion 8.9.8.1 -DetectOnly

.EXAMPLE
    # $clsid = the application's shell extension CLSID, read from a healthy machine:
    #   HKLM\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\<name> (default value)
    ./Windows/Update-AppViaRunCommand.ps1 -TargetsCsv ./targets.csv -InstallerPath ./npp.Installer.x64.exe -TargetVersion 8.9.8.1 `
        -DisplayName 'Notepad++*' -ExePath 'C:\Program Files\Notepad++\notepad++.exe' -OpenWith Check `
        -ShellExtensionClsid $clsid -ShellExtensionDir 'C:\Program Files\Notepad++\contextMenu\' -WhatIf

.NOTES
    Role: Virtual Machine Contributor (Run Command). Installing software is a change: raise it and activate PIM.
    Modules: Az.Accounts. Uses Azure/Compute/Invoke-VmRunCommand.ps1 (detect) and
    Azure/Compute/Push-InstallerViaRunCommand.ps1 (delivery and install). Guest: Windows PowerShell 5.1 as SYSTEM.
    Traps kept from real use:
      - The exit code is not success. Installers returned 0 while the version, the "Open with" command or the
        shell extension was wrong. Check the result on disk and in the registry.
      - Versions: [version]'8.9' is LESS than [version]'8.9.0' in .NET (missing parts are -1), so always
        normalise to 4 parts. A 3-part compare calls 8.9.8.0 current against an 8.9.8.1 hotfix. Compare
        FileMajorPart..FilePrivatePart, not ProductVersion strings (they can read like '8.981').
      - Removing a 32-bit copy deleted HKLM\SOFTWARE\Classes\Applications\<exe>\shell\open\command and the
        64-bit installer did not recreate it: "Open with" broke silently. Hence X86-PRESENT and check (b).
        An unreadable WOW6432Node hive also stops the run; it must not read as "no 32-bit copy".
      - HKCR merges HKCU\Software\Classes over HKLM: a per-user copy of the key masks an HKLM repair.
      - New-Item -Force on an EXISTING registry key wipes its values and subkeys: create only when missing.
      - The registry path contains the literal key name '*' (shell extensions); always use -LiteralPath.
      - On Windows 11 the shell extension can be registered through a sparse package and not listed under
        *\shellex\ContextMenuHandlers: resolve the CLSID directly. A DLL held by Explorer is replaced at
        reboot (PendingFileRenameOperations); (c) still passes, so it is flagged.
      - Polite close: Run Command runs as SYSTEM in session 0 and cannot send WM_CLOSE to another session,
        and taskkill without /F from there is refused. A scheduled task registered AS the user with
        LogonType Interactive (no password, the user is logged on) runs "taskkill /IM <exe>" without /F
        inside their session, so the application exits normally and saves its session. A forced kill skips
        that write (session files were found days older than the running process). Only safe when the
        application does not stop on a "save changes?" prompt; if it is still running after 90 s the VM is
        deferred, never killed.
      - Never kill a running installer at the timeout; report and leave it.
      - Run Command output is capped near 4 KB: each value is trimmed and one STATUS line is printed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByCsv')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByCsv')][string]$TargetsCsv,
    [Parameter(Mandatory, ParameterSetName = 'ByName')][string[]]$VmName,
    [Parameter(ParameterSetName = 'ByName')][string]$ResourceGroup,
    [Parameter(ParameterSetName = 'ByName')][string]$Subscription,

    [string]$InstallerPath,
    [Parameter(Mandatory)][string]$TargetVersion,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]:\\.+\.exe$')][string]$ExePath,
    [string]$ProcessName,
    [string]$InstallerArguments = '/S',
    [int]$InstallTimeoutMinutes = 10,
    [ValidateSet('Defer', 'PoliteClose')][string]$InUse = 'Defer',
    [ValidateSet('Off', 'Check', 'Repair')][string]$OpenWith = 'Off',
    [ValidatePattern('^\{[0-9A-Fa-f-]{36}\}$')][string]$ShellExtensionClsid,
    [string]$ShellExtensionDir,
    [switch]$AllowX86,
    [switch]$AllowMultiSession,
    [switch]$DetectOnly,
    [string[]]$GateCodes = @('UPDATED-PASS', 'UPDATED-REPAIRED', 'ALREADYCURRENT', 'SKIPPED-INUSE', 'NOTINSTALLED'),
    [int]$Throttle = 5,
    [string]$OutputFolder = "./app-update-$(Get-Date -Format yyyyMMdd-HHmmss)"
)

$ErrorActionPreference = 'Stop'
if (-not $DetectOnly) {
    if (-not $InstallerPath) { throw 'Pass -InstallerPath, or -DetectOnly.' }
    if (-not (Test-Path $InstallerPath)) { throw "Installer not found: $InstallerPath" }
}
if ([bool]$ShellExtensionClsid -ne [bool]$ShellExtensionDir) { throw 'Pass -ShellExtensionClsid and -ShellExtensionDir together.' }
try { [void][version]$TargetVersion } catch { throw "TargetVersion '$TargetVersion' is not a version." }
if (-not $ProcessName) { $ProcessName = [IO.Path]::GetFileNameWithoutExtension($ExePath) }
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
$rcScript = Join-Path $PSScriptRoot '../Azure/Compute/Invoke-VmRunCommand.ps1'
$pushScript = Join-Path $PSScriptRoot '../Azure/Compute/Push-InstallerViaRunCommand.ps1'

# ---- guest script (Windows PowerShell 5.1, SYSTEM). Wrapped in & { } so "return" ends only this block
#      and the staging cleanup of Push-InstallerViaRunCommand.ps1 still runs. ---------------------------------
$guestBody = @'
& {
$ErrorActionPreference = 'Stop'
$cfg = ConvertFrom-Json '__CFG__'
$mode = '__MODE__'
$file = '{{FILE}}'
$exe = $cfg.ExePath
$exeLeaf = Split-Path $exe -Leaf
$x86Exe = $exe -replace '^([A-Za-z]:\\Program Files)\\', '$1 (x86)\'
$appKey = "HKLM:\SOFTWARE\Classes\Applications\$exeLeaf"
$openCmdKey = "$appKey\shell\open\command"
$expectedCmd = '"' + $exe + '" "%1"'
$noExpand = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
$f = [ordered]@{}

function Clean([object]$v) { if ($null -eq $v) { return '' }; $s = ("$v" -replace '[\r\n;]', ' '); if ($s.Length -gt 200) { $s = $s.Substring(0, 200) + '...' }; $s }
function B64([object]$v) { if ($null -eq $v) { return '' }; [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$v)) }
function Say([string]$code) {
    $parts = @("STATUS=$code", "host=$env:COMPUTERNAME")
    foreach ($k in $f.Keys) { $parts += "$k=$(Clean $f[$k])" }
    Write-Output ($parts -join ';')
}
function ConvertTo-Ver([string]$s) {
    # 4 parts always: [version]'8.9' < [version]'8.9.0' in .NET, and hotfixes use the 4th part.
    try {
        $v = [version](($s -replace '[^0-9.]', '').Trim('.'))
        [version]('{0}.{1}.{2}.{3}' -f $v.Major, [Math]::Max($v.Minor, 0), [Math]::Max($v.Build, 0), [Math]::Max($v.Revision, 0))
    } catch { $null }
}
function Get-Uninstall([string]$root) {
    @(Get-ChildItem -LiteralPath $root -ErrorAction Stop | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop } |
        Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -like $cfg.DisplayName })
}
function Get-OpenCmd {
    if (-not (Test-Path -LiteralPath $openCmdKey)) { return @{ exists = $false; has = $false; value = $null; kind = '' } }
    $k = Get-Item -LiteralPath $openCmdKey
    if (@($k.GetValueNames()) -notcontains '') { return @{ exists = $true; has = $false; value = $null; kind = '' } }
    @{ exists = $true; has = $true; value = $k.GetValue('', $null, $noExpand); kind = [string]$k.GetValueKind('') }
}
function Test-ShellExt {
    if (-not $cfg.ShellExtensionClsid) { return $true }
    $ipk = "HKLM:\SOFTWARE\Classes\CLSID\$($cfg.ShellExtensionClsid)\InprocServer32"
    $dll = if (Test-Path -LiteralPath $ipk) { (Get-Item -LiteralPath $ipk).GetValue('') } else { $null }
    $f.shellExtDll = $dll
    $ok = [bool]($dll -and $dll -like "$($cfg.ShellExtensionDir.TrimEnd('\'))\*" -and (Test-Path -LiteralPath $dll))
    if ($ok) {
        $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        $leaf = [regex]::Escape((Split-Path $dll -Leaf))
        $f.shellExtPendingReplace = [bool](@($pfr | Where-Object { $_ -match $leaf }).Count -gt 0)
    }
    $ok
}
function Invoke-Checks {
    if (Test-Path -LiteralPath $exe) {
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        $f.afterVersion = '{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart
    } else { $f.afterVersion = 'EXE-MISSING' }
    $okA = ($f.afterVersion -ne 'EXE-MISSING') -and ([version]$f.afterVersion -eq $tv)
    $okC = Test-ShellExt
    $o = Get-OpenCmd
    $okB = $true
    if ($cfg.OpenWith -ne 'Off') {
        $f.openCmd = if (-not $o.exists) { '<KEY-ABSENT>' } elseif (-not $o.has) { '<NO-DEFAULT>' } else { $o.value }
        $okB = $o.exists -and $o.has -and ($o.value -ceq $expectedCmd)
        # HKCR merges HKCU over HKLM: a per-user copy masks the machine value.
        $ov = @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object {
            Test-Path -LiteralPath "Registry::HKEY_USERS\$($_.PSChildName)\Software\Classes\Applications\$exeLeaf\shell\open\command" })
        if ($ov.Count) { $f.hkuOverrides = ($ov.PSChildName | Select-Object -First 3) -join ',' }
    }
    @{ a = $okA; b = $okB; c = $okC; open = $o }
}
function Get-Owners {
    $map = @{}
    foreach ($p in Get-Process -Name $cfg.ProcessName -ErrorAction SilentlyContinue) {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
        if (-not $cim) { continue }
        $o = $cim | Invoke-CimMethod -MethodName GetOwner -ErrorAction SilentlyContinue
        if (-not $o -or -not $o.User) { continue }
        $acct = if ($o.Domain) { "$($o.Domain)\$($o.User)" } else { $o.User }
        $map[$acct] = $p.SessionId
    }
    $map
}
function Close-Politely {
    $owners = Get-Owners
    $tasks = @()
    foreach ($acct in $owners.Keys) {
        $name = 'PoliteClose_' + ($acct -replace '[^A-Za-z0-9]', '_')
        try {
            $action = New-ScheduledTaskAction -Execute 'taskkill.exe' -Argument "/IM $exeLeaf"
            # Interactive: runs with the logged-on user's own token, no password stored.
            $principal = New-ScheduledTaskPrincipal -UserId $acct -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName $name
            $tasks += $name
        } catch { $f.closeError = $_.Exception.Message }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 90 -and @(Get-Process -Name $cfg.ProcessName -ErrorAction SilentlyContinue).Count) { Start-Sleep -Seconds 3 }
    foreach ($t in $tasks) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    $f.closedUsers = $owners.Count
    -not @(Get-Process -Name $cfg.ProcessName -ErrorAction SilentlyContinue).Count
}

try {
    $tv = ConvertTo-Ver $cfg.TargetVersion
    if (-not $tv) { $f.reason = 'bad-target-version'; Say 'FAILED'; return }

    # 32-bit copy: an unreadable WOW6432Node hive must stop the run, not read as "none".
    try { $wow = Get-Uninstall 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
    catch { $f.reason = 'x86-check-unreadable: ' + $_.Exception.Message; Say 'X86-PRESENT'; return }
    $f.x86 = ((Test-Path -LiteralPath $x86Exe) -or ($wow.Count -gt 0))
    if ($f.x86 -and -not $cfg.AllowX86) { Say 'X86-PRESENT'; return }

    $os = Get-CimInstance Win32_OperatingSystem
    if (-not $cfg.AllowMultiSession -and (-not $os.Caption -or $os.Caption -match 'multi-session' -or $os.OperatingSystemSKU -eq 175)) {
        $f.os = $os.Caption; Say 'SKIPPED-MULTISESSION'; return
    }

    $u64 = @(Get-Uninstall 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    $current = if ($u64.Count -and $u64[0].DisplayVersion) { $u64[0].DisplayVersion }
               elseif (Test-Path -LiteralPath $exe) { "$((Get-Item -LiteralPath $exe).VersionInfo.FileVersion)".Trim() } else { $null }
    if (-not $current) { Say 'NOTINSTALLED'; return }
    $f.from = $current

    # The installer reuses the previous install folder: a non-default location would be upgraded in place
    # and then fail check (a). Refuse before touching it.
    $loc = if ($u64.Count -and $u64[0].PSObject.Properties.Name -contains 'InstallLocation') { "$($u64[0].InstallLocation)".Trim('"').TrimEnd('\') } else { '' }
    $f.installDir = $loc
    if (-not (Test-Path -LiteralPath $exe) -or ($loc -and $loc -ne (Split-Path $exe))) { Say 'NONSTANDARD-PATH'; return }

    $cv = ConvertTo-Ver $current
    if ($cv -and $cv -ge $tv) {
        $r = Invoke-Checks
        if (-not $r.c) { Say 'CURRENT-FAIL-SHELLEXT'; return }
        if (-not $r.b) { Say 'CURRENT-FAIL-OPENCMD'; return }
        Say 'ALREADYCURRENT'; return
    }

    $running = @(Get-Process -Name $cfg.ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count) { $f.sessions = (@($running | Select-Object -ExpandProperty SessionId -Unique) -join ',') }
    if ($mode -eq 'detect') {
        if ($running.Count -and $cfg.InUse -ne 'PoliteClose') { Say 'SKIPPED-INUSE'; return }
        $f.to = $cfg.TargetVersion; Say 'WOULD-UPDATE'; return
    }

    # ---------- install ----------
    if (-not (Test-Path -LiteralPath $file)) { $f.reason = 'staged-file-missing'; Say 'FAILED'; return }
    if (@(Get-Process -Name $cfg.ProcessName -ErrorAction SilentlyContinue).Count) {
        if ($cfg.InUse -ne 'PoliteClose' -or -not (Close-Politely)) { $f.note = 'in-use-at-install'; Say 'SKIPPED-INUSE'; return }
    }
    $p = Start-Process -FilePath $file -ArgumentList $cfg.InstallerArguments -PassThru
    if (-not $p.WaitForExit([int]$cfg.InstallTimeoutMinutes * 60000)) {
        # Never kill a running installer mid-write.
        $f.reason = 'installer-timeout'; $f.installerPid = $p.Id; Say 'FAILED'; return
    }
    $f.installerExit = $p.ExitCode
    Start-Sleep -Seconds 3

    # ---------- post-install check: the exit code is NOT the success criterion ----------
    $r = Invoke-Checks
    if (-not $r.a) { Say 'FAIL-VERSION'; return }
    if (-not $r.c) { Say 'FAIL-SHELLEXT'; return }
    if ($r.b) { Say 'UPDATED-PASS'; return }
    if ($cfg.OpenWith -ne 'Repair') { Say 'FAIL-OPENCMD'; return }

    # ---------- repair: record exactly what is overwritten, so it can be reverted ----------
    $a = $r.open
    $f.PRE_REPAIR_KEY_EXISTS = $a.exists
    $f.PRE_REPAIR_HAS_DEFAULT = $a.has
    $f.PRE_REPAIR_KIND = $a.kind
    $f.PRE_REPAIR_VALUE_B64 = if ($a.has) { B64 $a.value } else { '' }
    $created = ''
    foreach ($k in @($appKey, "$appKey\shell", "$appKey\shell\open", $openCmdKey)) { if (-not (Test-Path -LiteralPath $k)) { $created = $k; break } }
    $f.repairCreated = $created
    $f.repaired = $true   # set BEFORE writing: a throw below must not read as "no write"
    try {
        # New-Item -Force on an EXISTING key wipes it; create only when missing.
        if (-not (Test-Path -LiteralPath $openCmdKey)) { New-Item -Path $openCmdKey -Force | Out-Null }
        Set-Item -LiteralPath $openCmdKey -Value $expectedCmd
    } catch { $f.reason = 'repair-write-failed: ' + $_.Exception.Message; Say 'REPAIR-UNVERIFIED'; return }
    $v = Get-OpenCmd
    $f.openCmd = $v.value
    if ($v.exists -and $v.has -and ($v.value -ceq $expectedCmd)) { Say 'UPDATED-REPAIRED' } else { Say 'REPAIR-UNVERIFIED' }
}
catch { $f.reason = $_.Exception.Message; Say 'FAILED' }
}
'@

$cfg = [ordered]@{
    TargetVersion = $TargetVersion; DisplayName = $DisplayName; ExePath = $ExePath; ProcessName = $ProcessName
    InstallerArguments = $InstallerArguments; InstallTimeoutMinutes = $InstallTimeoutMinutes; InUse = $InUse; OpenWith = $OpenWith
    ShellExtensionClsid = $ShellExtensionClsid; ShellExtensionDir = $ShellExtensionDir
    AllowX86 = [bool]$AllowX86; AllowMultiSession = [bool]$AllowMultiSession
}
$cfgText = ($cfg | ConvertTo-Json -Compress) -replace "'", "''"
$detectScript = $guestBody.Replace('__CFG__', $cfgText).Replace('__MODE__', 'detect')
$installScript = $guestBody.Replace('__CFG__', $cfgText).Replace('__MODE__', 'install')

# ---- targets and waves ----------------------------------------------------------------------------
function Get-VmId($row) {
    if ($row.PSObject.Properties.Name -contains 'ResourceId' -and $row.ResourceId) { return $row.ResourceId }
    if ($row.Name -and $row.ResourceGroup -and $row.Subscription) { return "/subscriptions/$($row.Subscription)/resourceGroups/$($row.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($row.Name)" }
    throw "Row needs ResourceId or Name+ResourceGroup+Subscription: $($row | ConvertTo-Json -Compress)"
}
$waves = [ordered]@{}
if ($PSCmdlet.ParameterSetName -eq 'ByCsv') {
    $rows = @(Import-Csv $TargetsCsv)
    if (-not $rows.Count) { throw "No rows in $TargetsCsv." }
    foreach ($row in $rows) {
        $w = if ($row.PSObject.Properties.Name -contains 'Wave' -and $row.Wave) { $row.Wave } else { 'all' }
        if (-not $waves.Contains($w)) { $waves[$w] = [System.Collections.Generic.List[string]]::new() }
        $waves[$w].Add((Get-VmId $row))
    }
} else {
    $waves['all'] = $null
}

New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
function Get-StatusCode([string]$text) {
    $line = ($text -split "`r?`n" | Where-Object { $_ -like 'STATUS=*' } | Select-Object -First 1)
    if (-not $line) { return @('NO-STATUS-RETURNED', '') }
    @((($line -replace '^STATUS=', '') -split ';')[0], $line)
}
function Set-NameArgs([hashtable]$h, $ids) {
    if ($null -eq $ids) { $h.VmName = $VmName; if ($ResourceGroup) { $h.ResourceGroup = $ResourceGroup }; if ($Subscription) { $h.Subscription = $Subscription } }
    else { $h.ResourceId = @($ids) }
}

$all = [System.Collections.Generic.List[object]]::new()
$waveNames = @($waves.Keys)
for ($i = 0; $i -lt $waveNames.Count; $i++) {
    $wave = $waveNames[$i]
    $ids = $waves[$wave]
    Write-Host "=== wave '$wave' ===" -ForegroundColor Cyan
    $rows = @()
    if ($DetectOnly) {
        $h = @{ Script = $detectScript; OsType = 'Windows'; PassThru = $true; Parallel = $true; ThrottleLimit = $Throttle; EvidenceFolder = (Join-Path $OutputFolder "detect-$wave") }
        Set-NameArgs $h $ids
        $res = @(& $rcScript @h)
        if (-not $res.Count) { throw "Wave '$wave': Invoke-VmRunCommand.ps1 returned no results." }
        $rows = foreach ($x in $res) {
            $sc = if ($x.State -eq 'Succeeded') { Get-StatusCode (Get-Content -Raw (Join-Path $x.Evidence 'stdout.txt')) } else { @("RUNCOMMAND-$($x.State)", $x.Error) }
            [pscustomobject]@{ Wave = $wave; Vm = $x.Vm; Code = $sc[0]; Detail = $sc[1] }
        }
    } else {
        $target = if ($null -eq $ids) { "$($VmName -join ', ')" } else { "$($ids.Count) VM(s)" }
        if (-not $PSCmdlet.ShouldProcess("wave '$wave': $target", "Update to $TargetVersion with $(Split-Path $InstallerPath -Leaf)")) { continue }
        $csv = Join-Path $OutputFolder "push-$wave.csv"
        $h = @{ FilePath = $InstallerPath; InstallScript = $installScript; PrecheckScript = $detectScript; PrecheckOkPattern = 'STATUS=WOULD-UPDATE;'
                Throttle = $Throttle; LogCsv = $csv; Confirm = $false }
        Set-NameArgs $h $ids
        & $pushScript @h | Out-Host
        if (-not (Test-Path $csv)) { throw "Wave '$wave' produced no result file ($csv). Stopping." }
        $rows = foreach ($x in Import-Csv $csv) {
            $code = $x.Code
            # A VM dropped at the precheck carries its detect STATUS line in Detail.
            if ($code -eq 'SKIPPED-PRECHECK') { $sc = Get-StatusCode $x.Detail; $code = $sc[0] }
            [pscustomobject]@{ Wave = $wave; Vm = $x.Vm; Code = $code; Detail = $x.Detail }
        }
    }
    $rows = @($rows)
    if (-not $rows.Count) { throw "Wave '$wave' produced no results. Stopping." }
    $rows | ForEach-Object { $all.Add($_) }
    Write-Host (($rows | Group-Object Code | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')
    $gate = if ($DetectOnly) { @($GateCodes) + 'WOULD-UPDATE' } else { $GateCodes }
    $bad = @($rows | Where-Object { $_.Code -notin $gate })
    if ($bad.Count -and $i -lt $waveNames.Count - 1) {
        Write-Warning ("GATE STOP after wave '{0}': {1}" -f $wave, (($bad | ForEach-Object { "$($_.Vm)=$($_.Code)" }) -join ', '))
        break
    }
}

$all | Export-Csv (Join-Path $OutputFolder 'summary.csv') -NoTypeInformation -Encoding utf8
$all | Format-Table Wave, Vm, Code -AutoSize
Write-Host "Output: $OutputFolder" -ForegroundColor Cyan
$failCodes = 'FAIL-VERSION', 'FAIL-SHELLEXT', 'FAIL-OPENCMD', 'REPAIR-UNVERIFIED', 'FAILED', 'NO-STATUS-RETURNED', 'CHUNK-FAILED', 'INVOKE-FAILED'
$failed = @($all | Where-Object { $_.Code -in $failCodes -or $_.Code -like 'RUNCOMMAND-*' })
if ($failed.Count) { Write-Error "$($failed.Count) VM(s) failed: $($failed.Vm -join ', ')" -ErrorAction Continue; exit 1 }
