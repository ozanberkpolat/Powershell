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
