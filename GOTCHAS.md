# Gotchas

Hard-won traps from running Azure, Graph and PowerShell by hand. Each one cost time at least once. Scripts in this repo already handle the ones marked (handled); the rest are for you to keep in mind. KQL traps are listed briefly at the end and belong in the KQL repo.

## PowerShell and shell

- **Returning `, $array` from a helper breaks `@()`**: a function that returns `, $all` emits ONE object (the array), so `@(Helper)` nests it into a one-element array and 46 rows collapse into one. Emit plain output and wrap at the call site: `$rows = @(Search-Graph ...)`. Never pipe a possibly single-row result into `.Count` without `@()`. (handled in `Azure/Common`)
- **ConfigCI cmdlets** (`New-CIPolicy`, `ConvertFrom-CIPolicy`, ...) work only in Windows PowerShell 5.1, not in `pwsh` 7. A rule ID after `ID_ALLOW_` must continue with a letter.
- **Windows `az.cmd` mangles parentheses and special characters** in arguments. Call Azure CLI through its Python module (`python -m azure.cli ...`) when a query contains JMESPath parentheses, or use `--query` from a file. Pass `--subscription` on every command; never rely on the default subscription. In Git Bash set `MSYS_NO_PATHCONV=1` so `/subscriptions/...` is not rewritten to a Windows path.
- **`az` and `ConvertFrom-Json`**: an empty output is an empty string, which `ConvertFrom-Json` rejects. A documented 204 or empty body is a valid empty result, not a failure. (handled)
- **Dates from `ConvertFrom-Json`** become `[datetime]` in the local culture when rendered with `"$v"`. Parse with `[datetimeoffset]` and format with the invariant culture. Reservation `expiryDateTime` has 7 fraction digits. (handled)
- **Constrained Language Mode** (App Control / WDAC on the host): `Add-Type`, many .NET calls and unsigned module loads fail. `Connect-ExchangeOnline` then needs a signed temporary module.
- **Quoting a script for Run Command inside PowerShell**: an expandable string expands `$_` and `$x` locally and the filter arrives empty. Build guest scripts in single-quoted here-strings (`@' ... '@`). Convert CRLF to LF for Linux scripts or bash fails with `$'\r': command not found`. (handled)
- **`ForEach-Object -Parallel`** runspaces do not share your functions or variables: pass them with `$using:` and rebuild a script block from its text; and they only see the Az context if context autosave is on. (handled)
- **`ShouldProcess` and `-WhatIf` inside helpers**: temp-file writes inside a `SupportsShouldProcess` script are suppressed by `-WhatIf` unless you pass `-WhatIf:$false` to them.
- **Never `Write-Host` a secret or leave one in a script body.** Pass SAS tokens, passwords and registration tokens as protected parameters, env vars or Key Vault references.

## Authentication, PIM and tokens

- **Reader by default, writes need PIM.** Activation lapses mid-session and the failure is a 403, not a clear message. Check the role is active before a write batch. Read-only scripts must state the precondition and stop, never try to escalate.
- **Device-code sign-in is often blocked by Conditional Access.** Use an interactive sign-in on a compliant device.
- **Token audiences differ**: Log Analytics REST needs `https://api.loganalytics.io`, not the ARM audience (403 `InvalidAuthenticationTokenAudience`). Storage data plane needs `https://storage.azure.com`. (handled for Log Analytics)
- **Managed identity roles reach the process only with a new token.** After granting a Graph role, restart the process; cached tokens live up to 24 hours. A server behind a proxy must exclude `169.254.169.254` (IMDS).
- **Managed identities cannot get Graph application permissions in the portal**: grant them with Graph REST / PowerShell. A `*.Selected` role grants nothing until a per-site or per-folder permission is added. (handled)
- **Do not grant Graph `Mail.*` to scope one mailbox**: it applies to every mailbox. Use Exchange RBAC for Applications with a management scope; the Entra permission would override it. Exchange can take minutes to about 2 hours to apply changes. (handled)
- **Never grant anything to a shared user-assigned identity** that many servers use. Verify the `oid` claim of the token equals the identity you granted.
- **Billing roles are not Azure RBAC.** An EA/MCA billing reader sees reservations in the portal while `Microsoft.Capacity` returns 403, and the billing role never appears in IAM and needs no PIM. Query both providers and union. Reservations are tenant-level with their own RBAC that does not inherit from subscriptions. (handled)
- **Cost Management reads can be switched off tenant-wide** on EA/MCA ("Allow Azure subscription users to view and optimize costs"), regardless of RBAC. It shows as a per-subscription failure. (handled)

## ARM, Resource Graph and REST

- **Resource Graph**: without an explicit scope a query sees only the current context; send the subscription list. Paging is by `$skipToken`; `-Skip` has a minimum of 1 in `Search-AzGraph`, so the first page must omit it. Flexible-orchestration scale sets already appear as VMs. A column created by `project` or `extend` cannot be used by a later `where`: filter first, project last. KQL subset: no `countif`, no `leftanti`. (handled)
- **Throttling returns several retry headers** (Cost Management: qpu, client, entity, tenant). The largest value is the one that gates you; waiting for the first one wastes attempts. A `Retry-After` of 0 is a wasted retry, so use a floor. (handled)
- **Cost Management**: a custom window cannot exceed one year, so compare months with one bounded call each; resource-level grouping really pages (follow `nextLink`); never publish half a subscription's months; never report a failed subscription as zero. (handled)
- **Reservation catalog** (`Microsoft.Capacity/catalogs`) pages with `$skip/$take` and returns no `nextLink`: ask for `$take=2000`. The `reservedResourceType` value is `VirtualMachines` in one reference and `VirtualMachine` in another; a wrong one returns empty. A 200 with no autofit properties is not success. (handled)
- **Reservation facts**: stopped but not deallocated VMs still consume a reservation; Spot, A-series (not Av2) and G/GS-series never draw one; instance size flexibility ratios are raw and not normalised; a flat floor beats a percentage floor in big pools. Retired VM series (Dv3, Dsv3, Ev3, Esv3, and the 1-year terms of the older families) cannot be purchased or renewed since 2026-07-01: auto-renew stays on and silently does nothing. Savings plans live under `Microsoft.BillingBenefits` and are not reservations. (handled)
- **Activity Log API** is unreliable over long windows and truncates silently at a record cap: query in 7-day slices, and flag a slice that returns thousands of rows. It keeps 90 days. (handled)
- **Metrics**: use the service namespace and the `/blobServices/default` resource ID; the account level aggregates every service. A service the account kind does not have answers 400/404, which is not zero traffic. Metrics keep 93 days. (handled)
- **Diagnostic settings**: creating one is a PUT that replaces the whole setting (write back metrics and other destinations); a log category cannot be sent to the same workspace by two settings; at most 5 settings per resource; supported categories differ per app kind, read them from the resource; `categoryGroup allLogs` means full coverage, `audit` does not. (handled)
- **NIC PATCH is tags-only**: change a NIC's NSG with the Az cmdlets (a PUT), not a PATCH.
- **Boot diagnostics**: Azure Backup restore drops it even when the source had it. PATCH `diagnosticsProfile.bootDiagnostics.enabled=true` straight away and do not restart. (handled)
- **A route for `168.63.129.16/32` is rejected and unnecessary**: platform traffic to it ignores UDRs and NSGs.
- **Storage service tag is not "my storage"**: `Storage.<region>` includes every storage account in the region, production ones too. An isolated test network must deny it.
- **Microsoft's NSG flow log to VNet flow log migration script does not add a managed identity**: add the identity and Traffic Analytics settings yourself. That script is Microsoft's, link to it instead of copying it.
- **Policy**: a policy that denies public network access on storage also blocks creating a temporary staging account; plan the channel (Run Command, private endpoint) before you need it.

## Run Command

- **One Run Command per VM at a time.** A second one gets `Conflict`; retry with backoff. Different VMs can run in parallel. (handled)
- **Managed Run Commands: 25 per VM**, and at the limit Azure refuses an update of an existing name too. Delete old ones; use unique names. (handled: `Remove-StaleRunCommands.ps1`, `Invoke-VmRunCommand.ps1`)
- **Payload ceiling** about 2 MB; 4 MB is rejected with `RequestedSizeExceeded`. Larger files go in as base64 chunks with length and SHA-256 verification. (handled: `Push-InstallerViaRunCommand.ps1`)
- **The classic invoke returns no exit code** and truncates output at about 4 KB; use the managed variant for exit codes. (handled)
- **Parameters**: Windows gets `-Name value` arguments, Linux gets environment variables; protected parameters work only on managed Run Commands and are not in the Activity Log. (handled)
- **Patches**: `install-patches` can time out and still have installed; confirm with `assess-patches`. A restart is also a state change on restored machines (pending updates install).
- **Update Manager history in Resource Graph is 30 days**: collect daily or backfill from AzureActivity for monthly reports.
- **`AzureAdPrt` in `dsregcmd`** belongs to a signed-in user session; run in a service context (Run Command, SYSTEM) it is not evidence that sign-in is broken.

## Backup, ASR and restore tests

- **Restore drops boot diagnostics**, and the first console frames of a restored Windows machine show "Working on updates" (staged updates install on first boot). Capture after it finishes and note it. (handled)
- **A black console frame is normal once the display idles**, and a Linux console has mean brightness under 1: judge by lit pixels. (handled)
- **Isolated restores cannot reach a domain controller**: switch off Network Level Authentication or RDP fails before asking for a password; enable password SSH on Linux; stop the source's schedulers so the copy does not start work. (handled)
- **Compare disk caching and LUNs** restored vs source; fixing caching needs a deallocate. (handled)
- **Recovery points expire** (30 days on a daily policy): restore oldest first. A VPN split tunnel that does not advertise the isolated range makes the test machine unreachable; connected clients must reconnect to learn new routes.
- **ASR cache storage accounts** look alive or dead only by their replication use; Backup has no staging account. Check before consolidating.
- **Immutable (WORM) backup storage**: decide redundancy at creation and rebuild the account as GRS rather than converting it; keep blob versioning off for container-level immutability; leave the immutability policy unlocked until the setup is validated (a locked policy cannot be undone).
- **Recovery Services vault diagnostic settings**: resource-specific (dedicated) tables vs AzureDiagnostics; a stray `AzureBackup` category setting must be deleted when you move to resource-specific.

## Storage

- **Before disabling shared key**: look at who fetches keys (Activity Log `listKeys`/`ListServiceSas`/`ListAccountSas`) AND who uses them (Transactions by `Authentication` = AccountKey/SAS/OAuth). Both. (handled)
- **Disabling shared key breaks everything still using it** (scripts, mounts, tools with a key or account SAS). Check first, change second.
- **SAS in activity events**: the caller can be an app ID, not a user; resolve it before blaming a person.

## Entra, Exchange, SharePoint, AVD

- **AVD SSO** needs the RDP property AND `remoteDesktopSecurityConfiguration` on BOTH service principals AND (hybrid) the Cloud Kerberos Trust object. Protected Users and privileged-group accounts cannot use Cloud Kerberos Trust by design. (see `AVD/README.md`)
- **Hybrid join** fails quietly when `enterpriseregistration.windows.net` is blocked by a web filter or the TLS certificate is replaced by inspection. Check the certificate issuer, not just reachability. (handled: `AVD/Test-HybridJoin.ps1`)
- **A stale session host record** (registered under a short name before domain join) stays Unavailable; delete it, then re-register. Long-lived registration tokens are secrets: revoke them. (handled: `AVD/Register-SessionHost.ps1`)
- **Drive redirection is bidirectional**; use clipboard transfer direction policies for one-way export.

## KQL traps (details belong in the KQL repo)

- `az monitor log-analytics query` without `--timespan` can silently return 0 rows; the REST API needs an explicit `timespan` too. (handled in `Invoke-LaKql`)
- Sentinel search-job result tables (`_SRCH`) carry the time in `_OriginalTimeGenerated`, not `TimeGenerated`.
- `InsightsMetrics` `diskSizeMB` is KiB on some mounts: without a unit fix a capacity report shows nonsense (such as -104857500 percent). Convert units before ratios.
- Resource Graph KQL is a subset (no `countif`, no `leftanti`, aliases from `project` unusable in a later `where`).
- `AzureActivity` keeps 90 days interactive; older needs a search job, which is a write.

## Windows guests, Exchange on-premises and fleet updates

- **App Control and Exchange Online**: `Connect-ExchangeOnline` writes a tmpEXO_* module to %TEMP%; unsigned, it runs in Constrained Language Mode (Code Integrity event 8029) and the first cmdlet fails. Pass `-SigningCertificate` with a code-signing certificate the policy trusts; the wrapper module must be signed too. (handled: `M365/Connect-ExoSigned.psm1`)
- **An installer exit code of 0 is not success.** Check the result on disk (file version) and in the registry. (handled: `Windows/Update-AppViaRunCommand.ps1`)
- **`[version]` compares missing parts as -1**: `[version]'8.9' -lt [version]'8.9.0'` is true. Normalise to 4 parts; a 3-part compare misses 4th-part hotfixes. Compare FileMajorPart..FilePrivatePart, not ProductVersion strings. (handled)
- **Removing a 32-bit copy of an app can delete `HKLM\SOFTWARE\Classes\Applications\<exe>\shell\open\command`**, and the 64-bit installer does not recreate it: "Open with" breaks silently. HKCR merges HKCU over HKLM, so a per-user copy masks a machine repair. (handled)
- **`New-Item -Force` on an existing registry key wipes its values and subkeys.** Create only when missing. Registry paths with the literal key `*` need `-LiteralPath`.
- **SYSTEM in session 0 cannot close a user's app politely** (no cross-session WM_CLOSE; `taskkill` without /F is refused). A scheduled task registered as the user with LogonType Interactive runs inside their session; a forced kill skips the app's own state save. (handled)
- **HKLM uninstall keys miss per-user and portable installs** that scanners still flag. Loading an offline NTUSER.DAT locks it: keep it opt-in and short. Shell extension DLLs live in every session's explorer.exe. (handled: `Windows/Get-InstalledSoftwareProbe.ps1`)
- **Extending C: after a disk resize**: NTFS only grows into adjacent space; a Recovery partition after C: blocks it (reagentc /disable, delete the partition with override, extend, reagentc /enable, snapshot first). The new size needs a storage rescan, which can lag after start. (handled: `Windows/Extend-OsPartition.ps1`)
- **Pin a VM's private IP to Static before a deallocate**: a Dynamic address can be handed to another VM while it is stopped, and DNS, firewall rules and routes still point at it.
- **Invoke-WebRequest can report OWA as failing while it is healthy** (.NET TLS client artifact). Use native `curl.exe -k` and corroborate with real client traffic in the IIS log. (handled: `Exchange-OnPrem/Test-ExchangeEndpoints.ps1`)
- **Exchange maintenance**: drain transport, set ServerWideOffline, dismount, and require `eseutil /mh` "Clean Shutdown" on every database before deallocating. ForwardSyncDaemon and ProvisioningRps are Inactive by design on premises. DAG members need DAG maintenance instead. (handled)
- **ACS Email HMAC**: hash and send the same UTF-8 bytes; Windows PowerShell 5.1 re-encodes a string body and non-ASCII subjects fail with 401. x-ms-date must use the invariant culture. 202 is "accepted", not "delivered". (handled: `M365/Send-AcsEmail.ps1`)
- **Office on multi-session hosts**: only Microsoft 365 Apps (shared computer activation, licence per user); remove MSI Office first; TLS inspection breaks the CDN download under SYSTEM even with TCP 443 open, so check the certificate issuer. Verify ClickToRun\Configuration, not the setup exit code. (handled: `AVD/Install-OfficeShared.ps1`)
- **Private endpoint NSGs**: `privateEndpointNetworkPolicies` Disabled means NSG rules and UDRs are ignored for endpoint traffic. Zero Traffic Analytics rows is not "no consumers": check the table has data in the window and that flow logs cover the source networks. (handled: `Azure/Networking/Get-PrivateEndpointConsumers.ps1`)
- **Lab teardown order**: locks, role assignments (PIM time-bound ones need an AdminRemove schedule request), backup vault contents (soft delete, immutability), the vault, resource groups, then custom roles (retry while RoleDefinitionHasAssignments propagates). Force-delete a lab workspace or its name stays reserved. (handled: `Azure/Subscription-Management/Remove-LabResources.ps1`)
- **Az policy cmdlets changed output objects between major versions** (`ResourceId` vs `Id`, nested `Properties`). Scripts that must keep working use ARM REST for policy assignments. (handled)
- **Lifecycle end dates can read one day late when taken from a timestamp**: an end of 2029-01-09 (Pacific time) is the instant 2029-01-10 06:59 UTC. Record the Pacific date shown on the lifecycle page, or use the Windows Server release information page, which lists ISO dates.

## Cleanup, DNS, policy and M365 (wave 3)

- **An empty private DNS zone linked to a VNet is not harmless**: it is authoritative for its namespace and answers NXDOMAIN for every name under it. An empty `privatelink.*` zone makes services WITHOUT a private endpoint unresolvable from that VNet (and from everything that uses its DNS). Unlink SOA-only zones; never unlink a zone that holds records or has an auto-registration link. (handled: `Azure/Networking/Remove-EmptyPrivateDnsZoneLinks.ps1`)
- **Resource Graph lags ARM by minutes**: a NIC it reports as unattached may be attached by now. Re-read every resource from ARM right before a delete. Deleting a NIC releases its private IP while DNS records and firewall objects outside Azure still point at it. (handled: `Azure/Networking/Remove-DanglingNics.ps1`)
- **Table storage has no soft delete.** A VM that still runs the legacy diagnostics extension (IaaSDiagnostics) recreates WAD tables within minutes; remove the extension first. Tables can be listed and deleted through the management plane, which needs no data plane role and is not blocked by the storage firewall. A failed list must never read as "0 tables". (handled: `Azure/Storage/Remove-WadTables.ps1`)
- **DeployIfNotExists policy identity**: grant the roles from the definition's `roleDefinitionIds` at the assignment scope AND rights on the target workspace when it is in another subscription. A brand-new identity can return PrincipalNotFound on role assignment for a minute; retry. Remediation started before roles propagate fails partially. (handled: `Azure/Monitoring/Set-BlobDiagnosticsPolicy.ps1`)
- **`$pid` is a read-only automatic variable** in PowerShell: `$pid = $x.identity.principalId` throws. Use another name.
- **Entra Connect staging**: check `(Get-ADSyncScheduler).StagingModeEnabled`, not `SyncCycleEnabled` (a staging server keeps syncing, it only does not export). The scheduler setting is stored in Entra ID and shared by both servers: disabling it on one stops the other. Never set staging mode with `Set-ADSyncScheduler`; never have two servers out of staging mode. (see `Azure/Entra_Connect/Upgrade-StagingSwap.md`)
- **SharePoint site user ID mismatch** (user re-created with the same UPN): every site keeps the old record. `Get-SPOUser` / `Remove-SPOUser` need SharePoint Administrator AND site collection admin on each site. Never fix the user's own OneDrive with `Remove-SPOUser` (a OneDrive URL with a trailing digit is the symptom): use the Site User Mismatch diagnostic, which can report "No issues found" for up to 24 hours after a PIM activation. Removing the record drops direct sharing permissions; only group memberships can be restored. (handled: `M365/Repair-SPOSiteUserMismatch.ps1`)
- **Constrained Language Mode blocks `[pscustomobject]@{}`** and other type casts ("only core types are supported in this language mode"). Scripts meant for App Control hosts write plain delimited text lines instead.
- **Group-based licensing applies to direct members only**; nested groups get nothing. `Get-MgGroupMember` returns directory objects without a filled `UserPrincipalName`; use `Get-MgGroupMemberAsUser`. (handled: `M365/License_Assignments.ps1`)
