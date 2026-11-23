# Zabbix templates for Azure (HTTP, no agent)

Three templates that watch Azure through the ARM and Azure Resource Graph REST APIs with a Zabbix script item. They need no
agent on the monitored resource, no external script on the Zabbix server and no Azure module. Format version 6.4, imports into 6.4 and 7.0.

| File | Monitors | One host per |
|---|---|---|
| `azure-logic-app-runs-by-http.yaml` | Logic App (Consumption) state, failed / timed out / cancelled runs in a window, failure percentage, last failed run with error code, idle time | Logic App |
| `azure-appgw-backend-health-by-http.yaml` | Application Gateway operational and provisioning state, healthy and unhealthy backend host count, "no metric data" | gateway |
| `azure-update-manager-patching-by-http.yaml` | Azure Update Manager scheduled patch runs per VM (failed, "succeeded but installed nothing", never ran, too old, window too small) through Resource Graph with low-level discovery | one collector host for the whole tenant |

Every id, tenant, subscription, client id and secret is a macro; nothing from a real environment is stored. All template, item and
trigger UUIDs are freshly generated, so importing does not collide with other templates. The template group is `Templates/Azure`.

## Azure side

Reader is enough for all three (it includes `Microsoft.Insights/metrics/read`, the Logic App runs list and Resource Graph).

Service principal (default):

```bash
az ad sp create-for-rbac --name sp-zabbix-azure-ro --role Reader --scopes /subscriptions/<subscription-id>
# Update Manager, tenant wide: assign Reader on the tenant root management group so new subscriptions are covered
az role assignment create --assignee <app-id> --role Reader --scope /providers/Microsoft.Management/managementGroups/<tenant-id>
```

The output holds `appId`, `password` and `tenant`. Subscription-scoped assignments drift: a new subscription is silently outside the monitoring.
The client secret expires (24 months at most): put the expiry in a calendar; an expired secret shows as "Login failed with status 401" in the Collector error item.

Managed identity (optional, `{$AZURE.AUTH.MODE}` = `msi`): only works when the Zabbix server itself is an Azure VM with a system-assigned or
user-assigned identity that has Reader. The script asks the instance metadata service at `169.254.169.254` (never through the proxy), so no secret
is stored. For a user-assigned identity put its client id in `{$AZURE.APP.ID}`. UNTESTED: the msi branch was written from the Microsoft docs and
has no live run behind it; test it with the Get data item first.

## Import and macro setup

1. Data collection > Templates > Import, choose the file, tick *Create new* and *Update existing*.
2. Create a host (no interface needed) in any group and link the template. Logic App and Application Gateway: one host per resource. Update Manager: one host.
3. **Set the macros on the HOST** (Host > Macros > Inherited and host macros > Change), not on the template. The files declare the secret with an
   empty value, and a re-import with *Update existing* resets template-level macro values to what is in the file. Symptom of ignoring this: a
   monitor that worked for weeks starts reporting `Required param is not set: password.` after a template update.

| Macro | Type | Set on host | Meaning |
|---|---|---|---|
| `{$AZURE.TENANT.ID}` | text | yes | Entra tenant (directory) ID |
| `{$AZURE.APP.ID}` | text | yes | Service principal application (client) ID, or user-assigned identity client id |
| `{$AZURE.PASSWORD}` | **secret text** | yes | Client secret. Empty in the files. Keep it a Secret macro |
| `{$AZURE.AUTH.MODE}` | text | optional | `sp` (default) or `msi` |
| `{$AZURE.RESOURCE.ID}` | text | yes (Logic App, App Gateway) | Full ARM resource ID of the monitored resource |
| `{$AZURE.PROXY}` / `{$AZURE.UPD.PROXY}` | text | optional | HTTP proxy for the Azure calls |
| `{$AZURE.TIMEOUT}` / `{$AZURE.UPD.TIMEOUT}` | text | optional | Script item timeout |

Resource IDs:

```text
/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Logic/workflows/<logic-app-name>
/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/applicationGateways/<gateway-name>
```

4. Open the host > Items > the `Get data` item > **Test** > Get value. The JSON must hold data and the `Collector error` item must be empty.

First place to look when an alert arrives: the `Collector error` item (Update Manager: `azure.upd.collector.err`).

| Collector error | Cause |
|---|---|
| `Required param is not set: <name>.` | Macro empty (see step 3) |
| `Login failed with status 401` / `400` | Wrong tenant, app id or secret, or the secret expired |
| `Request failed with status 403` | The identity has no Reader on the resource |
| `Request failed with status 404` | Wrong `{$AZURE.RESOURCE.ID}` (case does not matter, the provider path does) |
| `Request failed with status 429` | Throttling; do not shorten the item interval |

## Logic App runs

Built on the runs API, not on Azure Monitor metrics: metrics lag several minutes and never say which run failed. The item reads every run that
started in `{$AZURE.LOGICAPP.WINDOW}` minutes (default 15, polled every 5 minutes, follows `nextLink` up to 5 pages) and publishes counts by status.

| Trigger | Priority | Fires when |
|---|---|---|
| Workflow is not enabled | High | `state <> Enabled` (a disabled Logic App stops silently) |
| Failed runs detected | High | failed runs in the window `> {$AZURE.LOGICAPP.RUNS.FAILED.MAX}` (default 0). Resolves when the failing run leaves the window |
| High run failure percentage | High | failed plus timed out above `{$AZURE.LOGICAPP.RUNS.FAILURE.PCT.CRIT}` % with at least 3 runs |
| No run for too long | Average | no run for `{$AZURE.LOGICAPP.IDLE.MAX}` seconds, or never. Default 0 = off. Uses the newest run overall, not the window |
| Provisioning state is not Succeeded | Warning | the last deployment did not finish |
| Collector reported an error | Average | collector error text not empty; all others depend on it |

Notes: Standard (single tenant) Logic Apps are `Microsoft.Web/sites` workflows and are not covered. Pick the window at least twice the poll
interval so a run is never missed between two polls. `Run list truncated` = 1 means more than 1250 runs in the window and the counts are a lower bound.

## Application Gateway backend health

Reads `HealthyHostCount` and `UnhealthyHostCount` (average per minute, last 10 minutes) and the gateway's `operationalState` / `provisioningState`.

- Metrics arrive 1 to 3 minutes late, so the newest point that exists is used. **When Azure returns no point the value is -1, never 0**: a stopped
  gateway or a metrics outage must not read as "0 unhealthy". The `No backend health metrics` trigger covers it.
- `Unhealthy backend hosts detected` needs the count above `{$AZURE.APPGW.BACKEND.UNHEALTHY.MAX}` for `{$AZURE.APPGW.BACKEND.UNHEALTHY.FOR}` (default 5m).
- `No healthy backend host` (Disaster) fires when the healthy count stays at 0 while data exists. A gateway that deliberately has no backend
  servers will trigger it; disable it on that host.
- Per-server detail is not collected: the `backendhealth` API is a long-running operation (202, then poll the Location header), which a script item cannot do
  reliably. Read it on demand:

```bash
az network application-gateway show-backend-health -g <resource-group> -n <gateway-name> \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health}" -o table
```

## Update Manager scheduled patching

Discovery is driven from the maintenance **assignment inventory** (`microsoft.maintenance/configurationassignments`), not from the patch result
table, because a scheduled run that never executed leaves no result row at all (deallocated VM at the window start, broken patch extension,
`patchMode` not `AutomaticByPlatform`, schedule never assigned). A machine that is assigned but has no result appears as status 6 "No result - never ran" and alerts.
One master item (every hour) runs four Resource Graph queries; 12 dependent items per VM and the triggers below hang off it.

| Alert (per VM) | Priority | Meaning |
|---|---|---|
| Scheduled patch run FAILED | High | Azure reported Failed; read "Last patch run error" |
| Succeeded but installed nothing | High | `installed=0`, `pending>0`, status Succeeded or Warnings. The silent failure signature, for example held packages making apt exit 100 and reject the whole batch |
| Assigned to a schedule but never ran | Average | No result row at all |
| Did not run in the expected period | Average | Last run older than `{$AZURE.UPD.MAXAGE}` (default 40d, sized for monthly; change it if your schedule differs) |
| Completed with warnings | Warning | Some packages failed to install |
| Maintenance window too small | Warning | A window problem, not a patch problem. Microsoft recommends at least 25 minutes for regular updates and 30 for service packs, the last 10 are reserved for the reboot |
| Unrecognised status value | Info | Azure returned a status the template does not know (schema drift guard) |

Collector alerts: not returning data, reported an error, **cannot see any virtual machine** and **fewer subscriptions visible than in the last 7 days**.

- **Permission canary.** Resource Graph returns HTTP 200 and an empty set when Reader is revoked, and filters by permission with no hint that the answer is
  partial. Without the canary a revoked role looks like "nothing is scheduled". `azure.upd.count.vmsvisible` is `> 0` normal, `0` = asked successfully and saw no VM
  (permission loss), `-1` = could not ask (macro empty, bad secret, throttling). Losing Reader on one subscription of many only lowers the distinct subscription
  count, which the 7-day peak comparison catches. It self-calibrates; close the problem when a subscription was retired on purpose.
- `{$AZURE.UPD.SUBSCRIPTIONS}` empty = the whole tenant, as far as the identity can read. Fill it with `id1,id2` only to narrow the scope deliberately.
- Resource Graph keeps patch results about 30 days (assessments about 7). Zabbix history is the long-term record, and a collector outage longer than 30 days loses that window for good.
- Scope is Azure VMs only (`microsoft.compute/virtualmachines`); Arc and Arc-VMware machines are not included, and the usual `split(id,'/',8)` idiom is not portable between those types.
- The discovery key is `{#RG}` plus `{#VMNAME}`: the same VM name in the same resource group name in two subscriptions would collide.
- `properties.startedBy` is undocumented (`Platform` / `User` are observed values) and is published as an item, never used as a filter. Check yours with
  `patchinstallationresources | distinct tostring(properties.startedBy)`.
- When you edit the template: a trigger prototype can be **silently not created**, the reason is only in *Discovery rules > Info*. The usual cause is the 255 character limit of `opdata`:
  `{?last(//key[...])}` stores the expanded item key (about 200 characters with long names), so use at most ONE such macro per `opdata` and `{ITEM.LASTVALUE1}` for the rest.
  Count with the longest names Azure allows (resource group 90, VM 64 characters) before you import.
- Typical root cause of "succeeded but installed nothing" on Linux: `apt-mark hold` packages (kernel, vendor agents) make the extension's apt call exit 100. Exclude them by name in the maintenance configuration:
  `az maintenance configuration update -g <rg> -n <config> --package-name-masks-to-exclude "linux-azure*" "linux-image-azure*"` (UNTESTED: confirm the parameter names with `az maintenance configuration update -h`).

## Companion: scheduled VM restart Logic App (described, not shipped)

A Logic App ARM template that restarts a list of VMs on a schedule is the usual fix for an agent that leaks over weeks, and Zabbix should see it as one more
Logic App. The version this work came from embeds environment specific connections, so it is not copied here. Rebuild it as: a Recurrence trigger
(daily, fixed hour, explicit time zone, start time as a parameter so redeploys do not shift the schedule); a `For each` over a parameter array of VM resource IDs;
inside it an ARM-connector `POST .../virtualMachines/<vm>/restart` using the Logic App's **system-assigned managed identity** (role *Virtual Machine Contributor* on those VMs only,
not on the subscription); a failure array that collects failed VM ids; and a final condition that fails the run (Terminate with status Failed) when the array is not empty,
so the `Failed runs detected` trigger above fires. Link the template to a host for that Logic App.
