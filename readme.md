# PowerShell Automation Scripts

A structured collection of PowerShell scripts for automating Azure and On-Premises tasks across identity, networking, disaster recovery, backup, cost management, and more.

---

## Repository Structure

### Azure/

| Folder | Description |
|--------|-------------|
| **Audit/** | Tenant audits, app registration reviews, authentication method checks, and privilege access reporting |
| **Cost/** | Cost analysis, resource comparison, and spend breakdowns across subscriptions |
| **Disaster-Recovery/** | ASR network mapping audits, VM failover network validation, VNet dependency checks, NSG/route table comparisons |
| **Disk-Management/** | Snapshot creation from existing disks, disk creation from snapshots, disk attach automation |
| **Entra ID/** | User, group, role, and policy automation for Entra ID (formerly Azure AD) |
| **Entra_Connect/** | Utilities for Entra Connect sync troubleshooting |
| **Graph/** | Microsoft Graph API integrations — permissions, service principals, SharePoint site access |
| **IAM/** | Role assignments, Key Vault access policies, and secret-scoped RBAC |
| **Integration/** | Azure Data Factory linked service inspection and version reporting |
| **Networking/** | App Gateway listener enumeration, DNS record retrieval, private endpoint listing, network segmentation analysis |
| **Recovery-Services_Vault/** | Backup audits, orphaned backup detection, SQL backup retention management, disabling unreachable backup items |
| **Subscription-Management/** | Subscription-wide VM listing and resource inventory |
| **Tagging/** | VM tag policy compliance checks and maintenance config tag management |
| **Tools/** | Tooling integrations: Maester, Entra Exporter, Zero Trust Assessment, M365 DSC |

### Azure core additions

New folders `Azure/Common/`, `Azure/Compute/`, `Azure/Monitoring/`, `Azure/Storage/`, top-level `AVD/` and `GOTCHAS.md` (hard-won traps). Dot-source the helpers after `Connect-AzAccount`; every script that changes Azure supports `-WhatIf`.

| Path | Description |
|------|-------------|
| `Azure/Common/Az-Helpers.ps1` | `Search-Graph` (Resource Graph across subscriptions, `$skipToken` paging), `Invoke-Arm` / `Invoke-ArmRequest` (ARM REST with 429/Retry-After retry and nextLink), `Invoke-LaKql` (Log Analytics query by workspace ID) |
| `Azure/Common/Graph-Helpers.ps1` | `Get-GraphAll` (Microsoft Graph paging) |
| `Azure/Compute/Invoke-VmRunCommand.ps1` | Run a script on many VMs (Windows/Linux), Conflict retry, parallel, protected parameters, evidence folder, exit code |
| `Azure/Compute/Remove-StaleRunCommands.ps1` | Report and delete managed Run Command resources (25 per VM limit) |
| `Azure/Compute/Push-InstallerViaRunCommand.ps1` | Push an installer in base64 chunks to VMs without internet, verify SHA-256, install |
| `Azure/Recovery-Services_Vault/Invoke-RestoreTest.ps1` | Restore a backed-up VM into an isolated subnet, evidence, access checks, cleanup (`RestoreTest-Runbook.md`) |
| `Azure/Storage/Get-StorageKeyUsage.ps1` | Who calls listKeys / generates SAS (Activity Log, 7-day slices) |
| `Azure/Storage/Get-StorageAuthMix.ps1` | Transactions by authentication type (shared key / OAuth / SAS) before disabling shared key |
| `Azure/Cost/Get-MonthlyCostByService.ps1` | Month-over-month cost per service / resource group / resource; supersedes `Get-AzureCostAnalysis.ps1` |
| `Azure/Cost/Get-Reservations.ps1` | Reservations, orders, savings plans, expiry, utilization, auto-renew flag |
| `Azure/Cost/Get-ReservationCoverage.ps1` | Reservation coverage per region x instance size flexibility group |
| `Azure/Monitoring/Sync-AppServiceDiagnosticSettings.ps1` | Audit App Service diagnostic routing and partial categories; create/repoint settings |
| `Azure/Graph/Grant-ManagedIdentityM365Access.ps1` | Managed identity to Graph app role, SharePoint folder/site permission, Key Vault role |
| `M365/Set-AppMailboxScope.ps1` | Exchange Online RBAC for Applications scoped to one mailbox |
| `AVD/Register-SessionHost.ps1`, `AVD/Test-HybridJoin.ps1`, `AVD/README.md` | Session host re-registration, hybrid join diagnosis, AVD lessons and required endpoints |

### Windows, Exchange, M365 and governance additions

New top-level folders `Windows/` (in-guest scripts and Run Command orchestration for Windows VMs) and `Exchange-OnPrem/`, plus `Azure/Reporting/`. In-guest scripts run under Windows PowerShell 5.1 (locally or through `Azure/Compute/Invoke-VmRunCommand.ps1`), take string parameters and end with one `RESULT=` / `STATUS=` line. Everything that changes something is a dry run or `-WhatIf`-capable by default.

| Path | Description |
|------|-------------|
| `M365/Connect-ExoSigned.psm1` | `Connect-ExchangeOnline` on App Control (WDAC) clients: signs the temporary tmpEXO module with a code-signing certificate (by subject or thumbprint) so it does not fall into Constrained Language Mode |
| `M365/Send-AcsEmail.ps1` | Azure Communication Services Email over REST with an HMAC-signed request, no modules; key from a SecureString or `ACS_CONNECTION_STRING` |
| `Windows/Get-InstalledSoftwareProbe.ps1` | Read-only software inventory via Run Command: machine, per-user and portable installs, MSI/EXE type, processes and Explorer-held shell extension DLLs |
| `Windows/Update-AppViaRunCommand.ps1` | Fleet update of an EXE-installed app in waves: probe, defer or polite close, chunked delivery, install, 3-way post-install check (version, Open-with command, shell extension) |
| `Windows/Extend-OsPartition.ps1` | In-guest assess / extend of C: after an Azure disk resize (GPT/MBR, Recovery partition after C:, rescan wait) |
| `Exchange-OnPrem/Invoke-ExchangeGracefulShutdown.ps1` | Standalone Exchange: read-only check, graceful shutdown (drain, ServerWideOffline, dismount, eseutil clean check), resume and verify |
| `Exchange-OnPrem/Test-ExchangeEndpoints.ps1` | OWA/ECP/EWS/MAPI/ActiveSync/Autodiscover evidence with native curl.exe, app pools, certificates, real client traffic from IIS logs |
| `Azure/Tagging/Build-TaggingWorkbook.ps1` | Environment + Criticality classification workbook (XLSX) from Resource Graph for owners to confirm, with drop-downs and draft rules |
| `Azure/Subscription-Management/New-LabParticipant.ps1` | Training lab: per-participant resource group, RG-scoped Contributor, built-in deny policies (VM sizes, resource types), budget alert |
| `Azure/Subscription-Management/Remove-LabResources.ps1` | Ordered lab teardown: locks, role assignments (incl. PIM), backup vaults, diagnostic setting/workspace, policies/budgets, resource groups, custom roles |
| `Azure/Networking/Get-PrivateEndpointConsumers.ps1` | Private endpoint subnets, endpoints, NSG rules, covering routes and Traffic Analytics consumers, with a verdict before enabling NSGs |
| `AVD/Install-OfficeShared.ps1`, `AVD/office-shared-computer.xml` | Microsoft 365 Apps with shared computer activation via ODT: connectivity/TLS-inspection check, signed setup.exe, install and registry verification |
| `Azure/Reporting/os-lifecycle.csv` | OS end-of-support dates (Windows Server 2012-2025, RHEL 7-10, Ubuntu LTS). RHEL: mainstream = end of Full Support, extended = end of Maintenance Support (ELS add-on not included). Ubuntu: mainstream = end of standard support, extended = end of ESM / Ubuntu Pro (month precision, last day of the month) |

### ITSM/

| Folder | Description |
|--------|-------------|
| **ITSM/** | Service management integrations — Xurrent (4me) API connectivity |

### Functions/

Azure Functions scripts for license count alerting and secret/certificate expiration monitoring.

### M365/

Microsoft 365 automation — license assignment reporting.

### On-Prem/

Active Directory user and account lifecycle management: disabling expired accounts, deleting disabled users, password expiration notifications.

---

## Requirements

- PowerShell 7+ (recommended)
- Modules (install via `Install-Module` as needed):
  - `Az` — for all Azure scripts
  - `Az.RecoveryServices` — for DR and backup scripts
  - `Microsoft.Graph` — for Graph and Entra scripts
  - `ActiveDirectory` — for On-Prem scripts

---

## Usage

Most scripts are standalone. Set required environment variables before running:

```powershell
$env:AZURE_SUBSCRIPTION_ID = "<your-subscription-id>"
$env:AZURE_SUBSCRIPTION_NAME = "<your-subscription-name>"
```

Authenticate first:

```powershell
Connect-AzAccount
Connect-MgGraph -Scopes "..."
```

Then run any script directly:

```powershell
.\Azure\Disaster-Recovery\Check-ASRNetworkMappings.ps1 -DrRegion "germanywestcentral"
.\Azure\Recovery-Services_Vault\Disable-NotReachableSQLBackups.ps1
```

---

## Best Practices

- Run in a test or staging environment before production.
- No credentials are hardcoded — all secrets are read from environment variables.
- Review script parameters at the top of each file before executing.

---

## Author

Maintained by [ozanberkpolat](https://github.com/ozanberkpolat)

### Cleanup, monitoring and M365 additions

Cleanup scripts report by default and change nothing until `-Apply` is passed; every write is then also guarded by `-WhatIf` / `-Confirm`.

| Path | Description |
|------|-------------|
| `Azure/Networking/Remove-DanglingNics.ps1` | Unattached NICs (no VM, private endpoint, private link service or hosted workload) with IPs and NSGs; `-Apply` re-checks each NIC live, backs up its JSON, then deletes |
| `Azure/Networking/Remove-EmptyPrivateDnsZoneLinks.ps1` | Unlink SOA-only private DNS zones (which shadow public names with NXDOMAIN) from one VNet; re-checks emptiness, skips auto-registration links, polls the async deletes |
| `Azure/Storage/Remove-WadTables.ps1` | Delete legacy WAD* diagnostic tables through the management plane; refuses while a diagnostics extension still writes to the account; logs names first |
| `Azure/Monitoring/Set-BlobDiagnosticsPolicy.ps1` | Blob StorageRead/Write/Delete logs to Log Analytics: built-in DeployIfNotExists policy per subscription with identity roles and remediation, or direct diagnostic settings |
| `Azure/Entra_Connect/Upgrade-StagingSwap.md` | Runbook: Entra Connect upgrade with an active/staging pair (upgrade staging, swap with one exporter at a time, upgrade the other, rollback) |
| `M365/Repair-SPOSiteUserMismatch.ps1` | SharePoint Online site user ID mismatch: scan sites for a re-created user's old record, back up group memberships, remove and restore; Constrained Language Mode safe |
| `M365/License_Assignments.ps1` | Extended: SKU consumption (enabled / warning / suspended / consumed), group-based licence report, users on one SKU with direct or group assignment |
