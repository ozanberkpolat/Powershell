#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only software inventory on Windows VMs through Run Command: machine, per-user and portable installs,
    install type, and what is holding the files right now.

.DESCRIPTION
    Vulnerability findings (Defender for Endpoint, Qualys) see the binary on disk; a check of the machine
    uninstall keys alone misses per-user installs and copied (portable) folders and calls the machine clean.
    This probe looks in every place and changes nothing:

      1. Machine uninstall entries, 64-bit and 32-bit (WOW6432Node) hives: version, MSI or EXE install
         type (decides the silent switches), install location.
      2. Per-user uninstall entries in every LOADED user hive (HKEY_USERS).
      3. Optional (-IncludeUnloadedProfiles): uninstall entries in the NTUSER.DAT of users who are not
         logged on, loaded under a temporary key and unloaded again.
      4. -FileName found on disk under -SearchRoot (portable copies, folder-copy deployments), with file
         version. A binary without an uninstall entry is reported as FILEONLY.
      5. In use: running -ProcessName processes with their session IDs, and processes in -ModuleHostProcess
         (default explorer) that have -ModuleName loaded (a shell extension DLL held by Explorer makes an
         in-place upgrade restart Explorer, which matters a lot on a session host).

    One VM = one PROBE=<json> line in the Run Command output. The script collects them into a CSV and a JSON
    file. Runs locally with -Local (no Azure).

.PARAMETER VmName
    VM names (with -ResourceGroup / -Subscription to disambiguate). Or -ResourceId, or -TargetsCsv.
.PARAMETER TargetsCsv
    CSV with a ResourceId column, or Name + ResourceGroup + Subscription columns.
.PARAMETER DisplayName
    Wildcard for the uninstall DisplayName, for example '7-Zip*' or 'Notepad++*'.
.PARAMETER FileName
    Executable to search on disk, for example 7z.exe. Optional.
.PARAMETER SearchRoot
    Folders searched for -FileName. Default Program Files, Program Files (x86), C:\Users, C:\ProgramData,
    C:\Tools, C:\Temp, D:\ (missing ones are skipped).
.PARAMETER ProcessName
    Process names (without .exe) that mean "in use", for example 7zFM,7zG.
.PARAMETER ModuleName
    DLL file name to look for inside -ModuleHostProcess, for example 7-zip.dll.
.PARAMETER ModuleHostProcess
    Processes inspected for -ModuleName. Default explorer.
.PARAMETER IncludeUnloadedProfiles
    Also read the hives of users who are not logged on (reg load / reg unload).
.PARAMETER Local
    Run on this machine instead of through Run Command.
.PARAMETER OutputFolder
    Where the CSV/JSON go. Default ./software-probe-<timestamp>.
.PARAMETER Parallel
    Passed to Invoke-VmRunCommand.ps1 (VMs in parallel).

.EXAMPLE
    ./Windows/Get-InstalledSoftwareProbe.ps1 -TargetsCsv ./targets.csv -DisplayName '7-Zip*' -FileName 7z.exe `
        -ProcessName 7zFM,7zG -ModuleName 7-zip.dll -Parallel

.EXAMPLE
    ./Windows/Get-InstalledSoftwareProbe.ps1 -VmName vm-app-01 -ResourceGroup rg-app -DisplayName 'Notepad++*' -FileName notepad++.exe -IncludeUnloadedProfiles

.EXAMPLE
    ./Windows/Get-InstalledSoftwareProbe.ps1 -Local -DisplayName 'Notepad++*' -FileName notepad++.exe

.NOTES
    Role: Virtual Machine Contributor (Run Command is an ARM action, Microsoft.Compute/virtualMachines/runCommand/action,
    even when the script only reads). With PIM, activate first; this script does not escalate and stops on 403.
    Modules: Az.Accounts (through Azure/Compute/Invoke-VmRunCommand.ps1). Guest: Windows PowerShell 5.1 as SYSTEM.
    Traps kept from real use:
      - HKLM uninstall keys alone miss per-user and portable installs while the scanner still flags the file.
        A machine reported as "not installed" by the keys had the binary in a user profile.
      - An MSI install keys its uninstall entry on a GUID and sets WindowsInstaller=1; an EXE (NSIS, Inno)
        install does not. The silent switches differ, so the type is reported.
      - A folder-copy install has no uninstall entry: the file version is the only version there is.
      - Loading an unloaded NTUSER.DAT takes a lock on it. A user who logs on in that moment can get a
        temporary profile, so -IncludeUnloadedProfiles is opt-in, and the hive is unloaded straight after
        (garbage collection first, or reg unload fails on an open handle).
      - Shell extensions live inside explorer.exe of every interactive session, so "nobody runs the app" is
        not "nothing holds the DLL". Upgrading in place can trip Restart Manager and restart Explorer.
      - Run Command output is capped at about 4 KB; each list in the probe is trimmed and one JSON line is
        printed.
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')][string[]]$VmName,
    [Parameter(ParameterSetName = 'ByName')][string]$ResourceGroup,
    [Parameter(ParameterSetName = 'ByName')][string]$Subscription,
    [Parameter(Mandatory, ParameterSetName = 'ById')][string[]]$ResourceId,
    [Parameter(Mandatory, ParameterSetName = 'ByCsv')][string]$TargetsCsv,
    [Parameter(Mandatory, ParameterSetName = 'Local')][switch]$Local,

    [Parameter(Mandatory)][string]$DisplayName,
    [string]$FileName,
    [string[]]$SearchRoot = @('%ProgramFiles%', '%ProgramFiles(x86)%', 'C:\Users', 'C:\ProgramData', 'C:\Tools', 'C:\Temp', 'D:\'),
    [string[]]$ProcessName = @(),
    [string]$ModuleName,
    [string[]]$ModuleHostProcess = @('explorer'),
    [switch]$IncludeUnloadedProfiles,
    [string]$OutputFolder = "./software-probe-$(Get-Date -Format yyyyMMdd-HHmmss)",
    [switch]$Parallel
)

$ErrorActionPreference = 'Stop'

# ---- guest probe: Windows PowerShell 5.1 compatible, read-only ------------------------------------
$probe = @'
$ErrorActionPreference = 'Stop'
$r = [ordered]@{ host = $env:COMPUTERNAME; ok = $true }
function Trim-List($list, [int]$max) { @($list | Select-Object -First $max) }
function Read-Uninstall([string]$root, [string]$scope) {
    $out = @()
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not ($p.PSObject.Properties.Name -contains 'DisplayName')) { continue }
        if ($p.DisplayName -notlike $cfg.DisplayName) { continue }
        $isMsi = ($k.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') -or ($p.PSObject.Properties.Name -contains 'WindowsInstaller' -and $p.WindowsInstaller -eq 1)
        $out += [ordered]@{ scope = $scope; name = $p.DisplayName; version = $p.DisplayVersion; type = $(if ($isMsi) { 'MSI' } else { 'EXE' }); location = $p.InstallLocation; key = $k.PSChildName }
    }
    $out
}
$sub = @('Software\Microsoft\Windows\CurrentVersion\Uninstall', 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $r.os = $os.Caption
    $r.multiSession = [bool]($os.Caption -match 'multi-session' -or $os.OperatingSystemSKU -eq 175)

    # 1. machine
    $machine = @(Read-Uninstall "HKLM:\$($sub[0])" 'machine64') + @(Read-Uninstall "HKLM:\$($sub[1])" 'machine32')
    # 2. loaded user hives
    $users = @()
    foreach ($sid in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue).PSChildName) {
        if ($sid -like '*_Classes') { continue }
        foreach ($s in $sub) { $users += @(Read-Uninstall "Registry::HKEY_USERS\$sid\$s" "user:$sid") }
    }
    # 3. unloaded profiles (opt-in)
    $r.unloadedProfilesRead = 0
    if ($cfg.IncludeUnloadedProfiles) {
        foreach ($pr in Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue) {
            $sid = $pr.PSChildName
            $path = (Get-ItemProperty -LiteralPath $pr.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
            if (-not $path -or (Test-Path "Registry::HKEY_USERS\$sid")) { continue }
            $dat = Join-Path $path 'NTUSER.DAT'
            if (-not (Test-Path -LiteralPath $dat)) { continue }
            $tmp = 'TmpProbe_' + ($sid -replace '[^0-9]', '')
            & reg.exe load "HKU\$tmp" "$dat" *> $null
            if ($LASTEXITCODE -ne 0) { continue }
            try {
                foreach ($s in $sub) { $users += @(Read-Uninstall "Registry::HKEY_USERS\$tmp\$s" "profile:$(Split-Path $path -Leaf)") }
                $r.unloadedProfilesRead++
            } finally {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                & reg.exe unload "HKU\$tmp" *> $null
            }
        }
    }
    # 4. files on disk
    $files = @()
    if ($cfg.FileName) {
        foreach ($root in $cfg.SearchRoot) {
            $root = [Environment]::ExpandEnvironmentVariables($root)
            if (-not $root -or $root -match '%' -or -not (Test-Path -LiteralPath $root)) { continue }
            $files += @(Get-ChildItem -LiteralPath $root -Filter $cfg.FileName -Recurse -Force -File -ErrorAction SilentlyContinue |
                Select-Object -First 5 | ForEach-Object { [ordered]@{ path = $_.FullName; version = "$($_.VersionInfo.FileVersion)".Trim() } })
        }
    }
    # 5. in use
    $procs = @()
    foreach ($pn in $cfg.ProcessName) { $procs += @(Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object { "$($_.ProcessName):$($_.SessionId)" }) }
    $holders = @()
    if ($cfg.ModuleName) {
        foreach ($hp in $cfg.ModuleHostProcess) {
            foreach ($p in Get-Process -Name $hp -ErrorAction SilentlyContinue) {
                try { if (@($p.Modules | Where-Object { $_.ModuleName -ieq $cfg.ModuleName }).Count) { $holders += "$($p.ProcessName):$($p.Id):$($p.SessionId)" } }
                catch { $holders += "$($p.ProcessName):$($p.Id):unreadable" }
            }
        }
    }
    $r.explorerSessions = (@(Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SessionId -Unique) -join ',')

    $r.machine = Trim-List $machine 4
    $r.users = Trim-List $users 6
    $r.files = Trim-List $files 8
    $r.running = (Trim-List $procs 10) -join ','
    $r.moduleHolders = (Trim-List $holders 10) -join ','
    $r.state = if ($machine.Count) { 'INSTALLED' } elseif ($users.Count) { 'PERUSER' } elseif ($files.Count) { 'FILEONLY' } else { 'ABSENT' }
}
catch { $r.ok = $false; $r.error = ($_.Exception.Message -replace '[\r\n]', ' ') }
Write-Output ('PROBE=' + ($r | ConvertTo-Json -Compress -Depth 4))
'@

$cfg = [ordered]@{
    DisplayName = $DisplayName; FileName = $FileName; SearchRoot = $SearchRoot; ProcessName = $ProcessName
    ModuleName = $ModuleName; ModuleHostProcess = $ModuleHostProcess; IncludeUnloadedProfiles = [bool]$IncludeUnloadedProfiles
}
$cfgJson = ($cfg | ConvertTo-Json -Compress -Depth 4) -replace "'", "''"
$guest = "`$cfg = ConvertFrom-Json '$cfgJson'`n" + $probe

function ConvertFrom-ProbeLine([string]$vm, [string]$text) {
    $line = ($text -split "`r?`n" | Where-Object { $_ -like 'PROBE=*' } | Select-Object -First 1)
    if (-not $line) { return [pscustomobject]@{ Vm = $vm; State = 'NO-PROBE-OUTPUT'; Detail = (($text -split "`r?`n" | Select-Object -First 2) -join ' | ') } }
    $o = $line.Substring(6) | ConvertFrom-Json
    $o | Add-Member -NotePropertyName Vm -NotePropertyValue $vm -Force
    $o
}

New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
if ($Local) {
    $out = (& ([scriptblock]::Create($guest)) | Out-String)
    $probes = @(ConvertFrom-ProbeLine $env:COMPUTERNAME $out)
} else {
    $rc = Join-Path $PSScriptRoot '../Azure/Compute/Invoke-VmRunCommand.ps1'
    $rcArgs = @{ Script = $guest; OsType = 'Windows'; EvidenceFolder = (Join-Path $OutputFolder 'run-command'); PassThru = $true; Parallel = [bool]$Parallel }
    switch ($PSCmdlet.ParameterSetName) {
        'ByName' { $rcArgs.VmName = $VmName; if ($ResourceGroup) { $rcArgs.ResourceGroup = $ResourceGroup }; if ($Subscription) { $rcArgs.Subscription = $Subscription } }
        'ById' { $rcArgs.ResourceId = $ResourceId }
        'ByCsv' {
            $rows = @(Import-Csv $TargetsCsv)
            if (-not $rows.Count) { throw "No rows in $TargetsCsv." }
            $rcArgs.ResourceId = @($rows | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'ResourceId' -and $_.ResourceId) { $_.ResourceId }
                elseif ($_.Name -and $_.ResourceGroup -and $_.Subscription) { "/subscriptions/$($_.Subscription)/resourceGroups/$($_.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($_.Name)" }
                else { throw "Row needs ResourceId or Name+ResourceGroup+Subscription: $($_ | ConvertTo-Json -Compress)" }
            })
        }
    }
    $results = @(& $rc @rcArgs)
    if (-not $results.Count) { throw 'Invoke-VmRunCommand.ps1 returned no results.' }
    $probes = foreach ($res in $results) {
        if ($res.State -ne 'Succeeded') { [pscustomobject]@{ Vm = $res.Vm; State = "RUNCOMMAND-$($res.State)"; Detail = $res.Error }; continue }
        ConvertFrom-ProbeLine $res.Vm (Get-Content -Raw (Join-Path $res.Evidence 'stdout.txt'))
    }
}

$probes = @($probes)
$probes | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputFolder 'probe.json') -Encoding utf8
$flat = $probes | ForEach-Object {
    [pscustomobject]@{
        Vm               = $_.Vm
        State            = $_.state
        MachineVersion   = (@($_.machine) | ForEach-Object { "$($_.version) ($($_.type),$($_.scope))" }) -join '; '
        UserInstalls     = (@($_.users) | ForEach-Object { "$($_.scope)=$($_.version)" }) -join '; '
        Files            = (@($_.files) | ForEach-Object { "$($_.path)=$($_.version)" }) -join '; '
        Running          = $_.running
        ModuleHolders    = $_.moduleHolders
        ExplorerSessions = $_.explorerSessions
        MultiSession     = $_.multiSession
        Error            = $(if ($_.error) { $_.error } else { $_.Detail })
    }
}
$flat | Export-Csv (Join-Path $OutputFolder 'probe.csv') -NoTypeInformation -Encoding utf8
$flat | Format-Table Vm, State, MachineVersion, UserInstalls, Running, ModuleHolders -AutoSize -Wrap
Write-Host "Output: $OutputFolder" -ForegroundColor Cyan
$bad = @($flat | Where-Object { $_.State -notin 'INSTALLED', 'PERUSER', 'FILEONLY', 'ABSENT' })
if ($bad.Count) { Write-Error "$($bad.Count) VM(s) gave no usable probe: $($bad.Vm -join ', ')" -ErrorAction Continue; exit 1 }
