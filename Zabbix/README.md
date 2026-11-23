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
| `Get-ZabbixMonthlyBundle.ps1` | read | Monthly bundle: hosts, chosen items, VM trends, web scenario items and trends as CSV plus `manifest.json`, cut on whole months in a given time zone (DST-safe). Uses the four scripts above |
| `Set-ZabbixServiceTree.ps1` | **write** | Business service tree from a JSON file: problem-tag leaves, parents = most critical child, existing nodes kept. `-WhatIf` supported |
| `Set-ZabbixHostTags.ps1` | **write** | Merges business-service tags into hosts (host.update replaces the list), environment tag census against PROD/NONPROD templates, optional reconcile. `-WhatIf` supported |
| `New-ZabbixTenantReadOnlyRole.ps1` | **write** | Role that sees only services tagged for one tenant, users moved onto it, optional user group, optional removal of service read from shared roles. `-WhatIf` supported |

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

## Monthly report bundle

```powershell
.\Get-ZabbixMonthlyBundle.ps1 @z -VmGroupName 'Contoso-Servers' -WebGroupName 'Contoso-Websites' -TimeZone 'Eastern Standard Time' -Zip
```

Writes `zabbix-bundle-<yyyy-MM>\` with `hosts.csv`, `items.csv`, `vm-trends.csv`, `web.csv`, `web-trends.csv` and
`manifest.json` (window, time zone, groups, row counts). The collector only fetches and selects; how the rows become a
report (business hours, thresholds, availability, sizing verdicts) is documented in [`report-rules.md`](report-rules.md).

## Business service tree for one tenant

Order matters: problem tags come from host, item and trigger tags, so tag first, then build the tree, then scope a role to it.

```powershell
.\Set-ZabbixHostTags.ps1 @z -TagFile .\examples\host-tags.example.csv -CensusGroupName 'Contoso-Servers' -WhatIf
.\Set-ZabbixServiceTree.ps1 @z -DefinitionFile .\examples\service-tree.example.json -WhatIf
.\New-ZabbixTenantReadOnlyRole.ps1 @z -RoleName 'Contoso Read Only' -TemplateRoleName 'Read-only user' -ServiceTagValue contoso -UserName 'contoso.viewer' -WhatIf
```

Drop `-WhatIf` to apply. Examples: [`examples/service-tree.example.json`](examples/service-tree.example.json),
[`examples/host-tags.example.csv`](examples/host-tags.example.csv).

More traps:

- **host.update replaces the whole tag list**, and sending back AUTOMATIC (discovered) tags turns them into manual ones. The tag script merges and refuses when automatic tags are present.
- **"PROD" is a substring of "NONPROD"**: the template-to-environment map is matched in order, longer pattern first.
- **role.update with a partial rules object resets the rest.** The role script reads the full rules and changes only the `services.*` keys. `readonly` is returned by role.get but cannot be sent.
- **Service access by tag includes child services**: tag the tenant's root service, not every leaf.
- **A parent that was not created has no id**: in `-WhatIf` its children are listed as planned and never looked up as roots.
- **Windows hosts have no `system.boottime`** and `system.uptime` keeps no trends: the availability script then takes reboots from the restart trigger, with a look-back before the period for the starting boot.

## Agent helpers and templates

| Path | What it is |
|---|---|
| `UserParameters/ibmmq/` | Zabbix Agent 2 `UserParameter` helper (bash, read-only `dspmq` / `runmqsc DISPLAY`): queue managers, local queue depth with the dead letter queue flagged, channel status, as JSON for low-level discovery. Fails loud instead of returning an empty list. See its `README.md` |
| `Templates/` | Importable Zabbix 6.4+ templates that monitor Azure over REST with no agent: Logic App runs, Application Gateway backend health, Update Manager scheduled patching. Service principal or managed identity, secret macro empty in the files. See `Templates/README.md` |
