# Win32 app packaging for Intune: delivery standard

Companion to `Build-Win32Package.ps1` and `Templates/`. It describes how a Win32 app gets from a vendor installer
to a piloted Intune assignment, and which values go into the Intune wizard. Windows only: `IntuneWinAppUtil.exe` has no Linux or macOS build.

## Delivery standard

1. **Intake.** App and exact version, where the installer comes from, new app or update of an existing one, target
   groups and intent (required, available, uninstall), pilot group, anything special (close a running app, user
   deferral, per-user install, reboot). Never guess a group or a naming convention; read it from the tenant or ask.
2. **Read the current state first** (read-only Graph, see below): existing apps with the same name, their commands,
   detection rules, supersedence graph and assignments. Copy the existing conventions unless told otherwise.
3. **Research the installer.** Type (MSI, Inno, NSIS, WiX Burn, MSIX), silent switches, ProductCode and UpgradeCode,
   per-machine or per-user, what it leaves behind (uninstall key, file version), whether it upgrades in place, and
   whether the app updates itself. Never invent a switch or a product code: verify it with `setup.exe /?` or a test install log.
4. **Choose the packaging style.**
   - *Plain*: silent install through `install.cmd` / `uninstall.cmd` or the MSI directly. Default.
   - *PSAppDeployToolkit v4* when the install must close running apps, let the user defer, show progress, or run several
     steps. Install command `Invoke-AppDeployToolkit.exe -DeploymentType Install`, uninstall `... -DeploymentType Uninstall`,
     install behavior System, leave `DeployMode` off. Use the v4 function names (`Start-ADTMsiProcess`, `Start-ADTProcess`,
     `Show-ADTInstallationWelcome`), not the v3 ones.
5. **Verify the source** (hash, signature, signer chain) and **build** with `Build-Win32Package.ps1`.
6. **App Control first** if the tenant enforces App Control for Business: ship the supplemental policy (see `WDAC/`) to
   the pilot group before the app, otherwise the install succeeds and the app is blocked at run time.
7. **Pilot, then broad.** Assign Required to a small pilot device group, check the list below, then add the production group.
8. **Verify after upload.** Read the app back with Graph and compare every field with your package plan.

## New version: supersedence or in-place update

- **Supersedence** (default for a new version): a new app that supersedes the old one. "Uninstall previous version" OFF
  when the new installer upgrades in place, ON when it is a different product or the installer cannot upgrade.
  A superseding app gets no automatic assignment: assign it yourself. A supersedence graph holds at most 11 nodes; check
  the existing relationships before adding another link. Auto-update through supersedence works for Available assignments only.
- **In-place update** (same app, new content): only content, detection and commands change; no rollback; one app at a time.
- Re-read the detection rule for every new version: a detection that still matches the old version reports success without installing.

## Intune wizard values (Apps > Windows > Add > Windows app (Win32))

| Field | Value |
|---|---|
| App package file | the `.intunewin` (MSI metadata fills some fields; still compare every one) |
| Install command | `install.cmd`, or `msiexec /i "app.msi" /qn /norestart /l*v "C:\Windows\Temp\app_install.log"` |
| Uninstall command | `uninstall.cmd`, or `msiexec /x {ProductCode} /qn /norestart /l*v "C:\Windows\Temp\app_uninstall.log"`. The uninstall field gets no environment variable expansion, so use a fixed log path |
| Install behavior | **System** |
| Device restart behavior | Determine behavior based on return codes |
| Return codes | Defaults: 0 success, 1707 success, 3010 soft reboot, 1641 hard reboot, 1618 retry. Check the list in the portal |
| Requirements | Architecture x64 (a separate Arm64 MSI is a separate app) and a minimum OS |
| Detection | MSI rule with the ProductCode, **product version check = No** unless the app never updates itself |
| Assignments | Required to the pilot group first. Availability and deadline: as soon as possible |

### Detection and self-updating apps

Intune re-checks Required apps and reinstalls when detection fails (error `0x87D1041C`, "installed but not detected").
- An app that updates itself can change the version on disk and in the uninstall key. A "version equals" rule then
  flips to not-detected and starts a reinstall loop. Use ProductCode only, or "greater than or equal".
- If the updater replaces the MSI with a different ProductCode, MSI detection breaks; fall back to a file rule
  (file or folder exists) on a stable file, and never compare versions.
- Check after the first auto-update in the pilot that the uninstall key is still there and the status stays Installed.

### Context traps

- The Intune Management Extension runs `.cmd` files with a **32-bit** `cmd.exe`: `%ProgramFiles%` is `Program Files (x86)`.
  Use `%ProgramW6432%` for 64-bit paths. PowerShell scripts need "Run script as 32-bit" set to No for 64-bit behaviour.
- Everything runs as SYSTEM. A SYSTEM process has no user profile and no mapped drives; per-user installs need a different approach.
- Secrets inside the package are stored in the tenant. Prefer a file that the install script locks to SYSTEM and
  Administrators (`icacls ... /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F"`), and delete the plain file from the source folder after packaging.
- An unsigned vendor release happens (check the signature of EVERY version you package). Unsigned installers also need an App Control hash rule.

## Inspecting an MSI and its signer

Run these on the Windows packaging machine. `Build-Win32Package.ps1` prints the same values.

```powershell
# Properties: ProductCode, UpgradeCode, ProductVersion, Manufacturer, ALLUSERS
$i  = New-Object -ComObject WindowsInstaller.Installer
$db = $i.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$i,@('C:\Work\app.msi',0))
$v  = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,@("SELECT Property,Value FROM Property"))
[void]$v.GetType().InvokeMember('Execute','InvokeMethod',$null,$v,$null)
while ($r = $v.GetType().InvokeMember('Fetch','InvokeMethod',$null,$v,$null)) {
  '{0} = {1}' -f $r.StringData(1), $r.StringData(2)
}

# Hash and signature, with the issuing chain
Get-FileHash C:\Work\app.msi -Algorithm SHA256
$s = Get-AuthenticodeSignature C:\Work\app.msi
$s.Status; $s.SignerCertificate.Subject; $s.SignerCertificate.Thumbprint
$c = New-Object Security.Cryptography.X509Certificates.X509Chain; [void]$c.Build($s.SignerCertificate)
$c.ChainElements | ForEach-Object { $_.Certificate.Subject }

# Extract without installing, then inventory the signers of every file inside
msiexec /a C:\Work\app.msi /qn TARGETDIR=C:\Work\extract
Get-ChildItem C:\Work\extract -Recurse -File -Include *.exe,*.dll,*.sys,*.ocx |
  ForEach-Object { $x = Get-AuthenticodeSignature $_.FullName
    [pscustomobject]@{ File = $_.Name; Status = $x.Status; Signer = $x.SignerCertificate.GetNameInfo('SimpleName',$false) } } |
  Group-Object Status, Signer | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize
```

Test the commands before upload as SYSTEM in a 32-bit context (for example with PsExec: `psexec -s -i -d C:\Windows\SysWOW64\cmd.exe`).

## Reading the current state with Graph (read-only)

Scope `DeviceManagementApps.Read.All`. Use `Invoke-MgGraphRequest -Method GET` or the Intune portal.

| What | Endpoint |
|---|---|
| Win32 apps | `GET /beta/deviceAppManagement/mobileApps?$filter=isof('microsoft.graph.win32LobApp')&$select=id,displayName,displayVersion,publisher` |
| One app in full (commands, detection, requirements, return codes) | `GET /beta/deviceAppManagement/mobileApps/{id}` |
| Supersedence and dependencies | `GET /beta/deviceAppManagement/mobileApps/{id}/relationships` |
| Assignments | `GET /beta/deviceAppManagement/mobileApps/{id}/assignments` (resolve group IDs with `GET /v1.0/groups/{id}?$select=displayName`) |

Install status reports (`deviceManagement/reports/getDeviceInstallStatusReport`) are POST calls; export them from the admin center when needed.
A 401 or 403 from `*.manage.microsoft.com` means the signed-in identity has no Intune scope: do not retry, grant the read scope or use the portal.
Uploading is a write (`DeviceManagementApps.ReadWrite.All` and an Intune role): the MSEndpointMgr `IntuneWin32App` module
(`Connect-MSIntuneGraph`, `Add-IntuneWin32App`, `Add-IntuneWin32AppSupersedence`) does it; read its help for exact parameters.

## Pilot checklist (run on a pilot device, elevated PowerShell)

1. Intune > the app > Device install status: every pilot device Installed. On failure read
   `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload.log` and the MSI log named in the install command.
2. App Control policy present: `Test-Path 'C:\Windows\System32\CodeIntegrity\CiPolicies\Active\{PolicyGuid}.cip'`.
3. Uninstall key and version: `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{ProductCode}' | Select DisplayName, DisplayVersion`. Repeat after the app's first auto-update.
4. Code Integrity blocks for the app in the last two days:
   `Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational'; Id=3076,3077; StartTime=(Get-Date).AddDays(-2)} -ErrorAction SilentlyContinue | Where-Object Message -match 'AppName'`.
   Empty means clean; an entry's 3089 event with the same ActivityID names the signer.
5. MSI and script blocks: log `Microsoft-Windows-AppLocker/MSI and Script`, events 8028 (audit) and 8029 (enforced).
6. Uninstall once on a test device and check that detection turns false and no files remain.

## Worked example: Zabbix agent 2 with TLS PSK

`Zabbix-Agent2/` applies this standard to an agent that needs a secret file: the PSK ships as `psk.key`, the install
script locks it to SYSTEM and Administrators before the MSI starts the service, server and PSK identity are install
command parameters, and detection is a custom script (version at least N, service, PSK settings). See `Zabbix-Agent2/README.md`.

## After the update: health test and remediations

- `Test-AppInstallHealth.ps1` (read-only) checks an updated app the way users break on it: file version (compared as a
  version, not a string prefix), a second copy in the other Program Files folder, uninstall entries in both registry
  views, the "Open with" shell verb for the machine and for every loaded user hive, and context-menu handler DLLs that
  still exist. `-ExitCode` turns it into a pass/fail for a Remediations detection script or Run Command.
- `Remediation/TeamsMwi-Detect.ps1` and `Remediation/TeamsMwi-Remediate.ps1` are a Remediations pair that removes the
  classic Teams Machine-Wide Installer. Settings: run as SYSTEM, signature check off (or UTF-8 without BOM when on),
  64-bit host may stay No (the remediation relaunches itself in 64-bit PowerShell because the Appx cmdlets fail in the
  32-bit host). The remediation refuses unless new Teams is installed or provisioned, treats msiexec 0/3010/1605 as
  success and anything else as failure, and verifies the entries are gone. Per-user classic Teams copies are reported
  by the detection script only; remove them with Microsoft's script (https://aka.ms/uninstallclassicteamsscript).
  On non-persistent AVD fix the golden image instead.
