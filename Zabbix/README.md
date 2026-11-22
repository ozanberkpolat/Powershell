# Zabbix API scripts (PowerShell)

JSON-RPC helpers and reporting/alerting scripts for the Zabbix API. Everything environment specific (URL, token,
host groups, host and scenario names, ports) is a parameter. Nothing is stored in the scripts.

Requirements: Windows PowerShell 5.1 or pwsh 7, network access to the Zabbix front end (often a VPN), a Zabbix 6.4+
API token. Create it under Users > API tokens. Read scripts need read access; the two write scripts need write access
to the host. Keep the token in a file readable only by you (`C:\secure\zabbix.token`, one line) or pass a `SecureString`.
Set `ZABBIX_URL` and `ZABBIX_TOKEN_FILE` once to drop `-Url` and `-TokenFile` from every call.

| Script | Reads / writes | What it does |
|---|---|---|
| `Invoke-ZabbixApi.ps1` | read | Library to dot-source: `Connect-ZabbixApi`, `Invoke-ZabbixApi`, `Test-ZabbixReachable`, `Resolve-ZabbixHostGroup`, `Save-ZabbixEvidence`. Bearer token, proxy bypass, reachability test, empty `*.get` = error |
| `Get-ZabbixHostsByGroup.ps1` | read | Enabled hosts of one or more host groups with OS (inventory, else `system.sw.os` / `system.uname`) |
| `Get-ZabbixUtilizationItems.ps1` | read | Picks one CPU util item, memory item, core count and filesystem items per host; flat CSV with a `Trended` flag |
| `Get-ZabbixTrends.ps1` | read | Chunked `trend.get` streamed to CSV/JSON (a fleet-month is about a million rows) |
| `Get-ZabbixWebScenarios.ps1` | read | Web scenario items (`web.test.fail/time/in`) of a host group |
| `Get-ZabbixHostAvailability.ps1` | read | Quarterly availability evidence for one host: hourly `agent.ping` gaps, boot times, peer check on the same proxy, trigger and proxy events |
| `New-ZabbixPortChecks.ps1` | **write** | `net.tcp.listen` items, then High triggers per port. Two stages, refuses to create triggers for ports not yet reporting 1. `-WhatIf` supported |
| `Set-ZabbixWebScenarioAlerting.ps1` | **write** | Required status code + tags on a web scenario, then a High trigger on N failed runs. `-WhatIf` supported |

## Typical flow: monthly utilisation and uptime data

```powershell
$z = @{ Url = 'https://zabbix.contoso.com'; TokenFile = 'C:\secure\zabbix.token' }
.\Get-ZabbixHostsByGroup.ps1       @z -GroupName 'Contoso-Servers' -OutFile hosts.csv
.\Get-ZabbixUtilizationItems.ps1   @z -GroupName 'Contoso-Servers' -OutFile items.csv
.\Get-ZabbixTrends.ps1             @z -ItemsFile items.csv -From 2026-05-01T00:00:00+02:00 -Till 2026-05-31T23:59:59+02:00 -OutFile trends.csv
.\Get-ZabbixWebScenarios.ps1       @z -GroupName 'Contoso-Websites' -OutFile web.csv
.\Get-ZabbixTrends.ps1             @z -ItemsFile web.csv -ChunkSize 150 -From 2026-05-01T00:00:00+02:00 -Till 2026-05-31T23:59:59+02:00 -OutFile web-trends.csv
```

Availability evidence for one host: `.\Get-ZabbixHostAvailability.ps1 @z -HostName SRV01 -From 2026-07-01T00:00:00+03:00 -To 2026-10-01T00:00:00+03:00`.

## Traps these scripts already handle

- **An empty result is a fault.** Wrong group name, missing permission and renamed items all return zero rows. `.get` calls throw on zero rows unless the script expects it. A missing group name prints the names that exist.
- **Web scenario items are type 9**: `item.get` hides them unless `webitems = true` is passed.
- **A single row unrolls to an object** in PowerShell. `Invoke-ZabbixApi` returns arrays with a leading comma so `.Count` stays correct.
- **System proxy.** A corporate proxy cannot reach a private address that exists only on a VPN and the error looks like "VPN down". The helper goes direct unless `-UseSystemProxy`, and tests TCP first, so a network failure is reported as one.
- **`apiinfo.version` must be called without credentials.**
- **Per-mode CPU items** (idle, user, system...) are not utilisation, and per-core items multiply the fetch. Exactly one aggregate item is chosen per host. Memory prefers `available` over `free` over a percent item; `total` is a capacity value, not trended.
- **Filesystem items**: `used` beats `free` beats `pused`; a non-dependent item beats a dependent one because it has longer history. `vfs.fs.dependent.size` exists on newer templates only.
- **Trend storage.** `trend.get` returns nothing for items with `trends = 0`, for periods older than the retention, and for text items.
- **`time_till` is inclusive.** Pass `period end - 1 second` or you get an extra hour row.
- **Triggers before items fire at once.** The port script creates items first and refuses to create triggers until each one has reported 1; the web script refuses until the last 3 values are 0.
- **`httptest.update` replaces steps and tags.** The web script resends every step field and merges tags.
- **Trigger expressions use the technical host name** (`host`), not the visible name.
- **Proxy field name** is `proxyid` on 7.0+ and `proxy_hostid` on 6.4. The availability script handles both.
- **Everything is idempotent.** Existing items and triggers are skipped, and before/after JSON evidence goes to `.\evidence`.
