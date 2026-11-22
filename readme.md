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
