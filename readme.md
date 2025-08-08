
# PowerShell Automation Scripts

A structured collection of PowerShell scripts for automating common Azure and On-Premises tasks related to identity, access, auditing, and resource management.

---

## 📁 Repository Structure

### 🔷 Azure/

Scripts tailored for Microsoft Azure environments:

- **Audit/**  
  Scripts for tenant audits, activity logging, compliance checks, and environment reviews.

- **Entra/**  
  Entra ID (formerly Azure AD) automation, including user, group, role, and policy management.

- **Graph/**  
  Microsoft Graph API integrations—token auth, data pulls, batch operations, and more.

- **Subscription-Management/**  
  Manage Azure subscriptions, role assignments, policy enforcement, and budget automation.

---

### 🖥️ On-Prem/

Scripts for hybrid/on-premises infrastructure:

- **Account-Management/**  
  Manage Active Directory users, groups, and organizational units.

---

## ⚙️ Usage

Each script is standalone unless noted otherwise. You can run them directly in PowerShell 7+ or Windows PowerShell 5.1.

### Example:
```powershell
.\Azure\Entra\Create-EntraUser.ps1 -UserPrincipalName "test@domain.com"
```

Ensure necessary permissions and context (e.g., `Connect-AzAccount`, `Connect-MgGraph`) before execution.

---

## 🔐 Requirements

- PowerShell 7+ (recommended)
- Required modules (install via `Install-Module` if needed):
  - `Az`
  - `Microsoft.Graph`
  - `ActiveDirectory` (for on-prem)

---

## ✅ Best Practices

- Always run scripts in a test environment first.
- Check for hardcoded values or placeholders before use.
- Review script headers for parameter documentation.

---


## ✍️ Author

Maintained by [ozanberkpolat](https://github.com/ozanberkpolat)

