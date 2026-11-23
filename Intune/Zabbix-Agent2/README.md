# Zabbix agent 2 for AVD session hosts (Intune Win32 app)

Installs Zabbix agent 2 with TLS PSK on Azure Virtual Desktop session hosts (or any Windows device) through Intune.
The server address and PSK identity are install-command parameters; the PSK value ships as a file that the install
script locks to SYSTEM and Administrators. No hostname is configured, so each session host reports with its computer name.

| File | What it does |
|---|---|
| `install.cmd` | `install.cmd <server> <psk-identity> [host-metadata]`. Places `psk.key` first (ACL SYSTEM + Administrators), installs the MSI with the TLS PSK properties, optionally replaces the config with a packaged `zabbix_agent2.conf`, sets delayed start, starts the service. 3010 is passed through |
| `uninstall.cmd` | Uninstalls with the packaged MSI (no ProductCode to maintain), removes the PSK, copied config and log. 1605 = success |
| `Detect-ZabbixAgent2.ps1` | Custom detection: binary version at least N, service present and not disabled, PSK file present, PSK settings in the config. Edit the two values at the top |

## Build

Source folder layout (keep it outside any git repository, because of `psk.key`):

```
C:\Work\zabbix-agent2\src\
    install.cmd
    uninstall.cmd
    zabbix_agent2-<version>-windows-amd64-openssl.msi   (from the Zabbix download page, check its SHA256 there)
    psk.key                                            (one line, the hex PSK; never commit it)
    zabbix_agent2.conf                                 (optional: full config replacing the MSI's one)
```

```powershell
..\Build-Win32Package.ps1 -SourceDir C:\Work\zabbix-agent2\src -SetupFile install.cmd -DownloadTool `
    -ExpectedSha256 <sha256-from-the-download-page> -SecretFile psk.key
Remove-Item C:\Work\zabbix-agent2\src\psk.key     # once the .intunewin exists
```

`Build-Win32Package.ps1` checks the MSI hash and Authenticode signature, checks the PSK file format (32 to 512 hex
characters) without printing it, and builds `install.intunewin`. Do not use `-GenerateCmd` here; the two scripts in this
folder are the ones to package.

## Intune wizard values

| Field | Value |
|---|---|
| Install command | `install.cmd 192.0.2.10 PSK-IDENTITY AVD` (your server or proxy address and PSK identity) |
| Uninstall command | `uninstall.cmd` |
| Install behavior | System |
| Return codes | defaults (0, 1707, 3010, 1641, 1618) |
| Detection | Custom script `Detect-ZabbixAgent2.ps1`, run as 32-bit = No |
| Requirements | x64 |

The PSK identity on the Zabbix side: the host (or the auto-registration action for `HostMetadata=AVD`) must use the same
identity and PSK. If the agent talks to a proxy, `<server>` is the proxy address.

## Traps

- The Intune Management Extension runs `.cmd` files with a 32-bit `cmd.exe`, so `%ProgramFiles%` is `Program Files (x86)`.
  The scripts use `%ProgramW6432%`; an older copy that used `%ProgramFiles%` put the PSK in the wrong folder.
- The PSK must exist before the MSI starts the service, or the first start fails TLS.
- Without delayed start the service hit the service-control timeout at boot on busy hosts and stayed stopped.
- The `.intunewin` contains the PSK and is stored in the tenant. Anyone with Intune app read access can download it;
  rotate the PSK when that group changes.
- If App Control for Business is enforced, allow the agent first (see `../WDAC/`), or it installs and is then blocked.
