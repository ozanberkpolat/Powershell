# AVD (Azure Virtual Desktop)

Scripts and field notes for running AVD by hand with PowerShell. Scripts here are standalone: sign in with `Connect-AzAccount` (and `Connect-MgGraph` where noted), then run them.

| File | What it does |
|------|--------------|
| `Register-SessionHost.ps1` | Re-registers a session host with a host pool: removes the stale record, issues a registration token, re-registers the agent in the guest (token as a protected Run Command parameter), waits for Available, revokes the token. Supports `-WhatIf`. |
| `Test-HybridJoin.ps1` | Read-only diagnosis of Entra hybrid join (dsregcmd, AD object and SCP, device registration log, proxy, endpoint reachability and TLS interception, clock). Local or remote through Run Command. |

Both use `Azure/Compute/Invoke-VmRunCommand.ps1` for the guest part and `Azure/Common/Az-Helpers.ps1` for ARM calls.

## Lessons

### Identity model: decide it first
- Hybrid join (AD domain join plus Entra hybrid) and cloud-only Entra join behave differently for SSO, FSLogix permissions and Kerberos. Pick one per host pool and build to it.
- Switching a host from Entra join to hybrid by hand leaves a broken intermediate state (FSLogix profile falling back to the local disk, AAD operational log errors, sign-in failures). Rebuilding the host cleanly is safer than repairing it in place.
- For hybrid join, deploy the VM as a workgroup machine (no Entra join extension), domain-join it with customer-controlled credentials, then let the hybrid join task run. The computer object must be in an OU that is in Entra Connect sync scope, and the device registration SCP must exist. Use `Test-HybridJoin.ps1` to see which part is missing.

### Single sign-on (Entra authentication for RDP)
- The RDP property `enablerdsaadauth:i:1` alone is not enough. Complete sequence:
  1. Enable RDP authentication on BOTH service principals, Microsoft Remote Desktop and Windows Cloud Login. Use the dedicated cmdlet, not a generic patch:
     ```powershell
     $params = @{ '@odata.type' = '#microsoft.graph.remoteDesktopSecurityConfiguration'; isRemoteDesktopProtocolEnabled = $true }
     New-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $msRdSpId  -BodyParameter $params
     New-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $wclSpId   -BodyParameter $params
     ```
     `Update-MgServicePrincipal -AdditionalProperties` fails with 404, and a direct PATCH on the v1.0 or beta servicePrincipals endpoint does not expose the property.
  2. Hide the consent prompt by adding a target device group on the Windows Cloud Login service principal.
  3. For hybrid hosts create the Cloud Kerberos Trust object (needs AD DS): `Set-AzureADKerberosServer -Domain <domain> -UserPrincipalName <admin upn> -SetupCloudTrust`.
  4. Enable Microsoft Entra single sign-on in the host pool RDP properties.

### Kerberos and privileged accounts
- Accounts in **Protected Users** or in privileged groups such as Domain Admins are excluded from Cloud Kerberos Trust by design (the RODC password replication policy denies them, and Protected Users blocks caching of the long-term key). Symptom: normal users sign in, admins get "username or password is incorrect" or sign-in error 70046 even with Conditional Access off and fresh tokens.
- Check with `Get-ADComputer AzureADKerberos -Properties msDS-NeverRevealGroup, msDS-RevealOnDemandGroup`. To confirm, take the account out of the group temporarily and sign in again.
- Fix is organisational: give admins a normal day-to-day account for AVD sign-in and a separate privileged account used inside the session with `runas`.

### FSLogix on Azure Files
- Storage account of kind FileStorage (Premium) joined to AD with `Join-AzStorageAccountForAuth -DomainAccountType ComputerAccount` (AzFilesHybrid module). Default share-level permission "all authenticated users and groups" with role Storage File Data SMB Share Contributor.
- NTFS permissions on the share root with `icacls`: Modify with (OI)(CI) for the users group, Full for administrators, Modify (IO) for CREATOR OWNER, and remove the built-in Users group. Use the localised group names on a non-English OS (or SIDs).
- Per-user folder isolation depends on that root ACL. If users can browse or delete each other's profile folders the root ACL is wrong; fix it before go-live.
- `Debug-AzStorageAccountAuth` can report CheckUserRbacAssignment or CheckGetKerberosTicket FAILED when run from a non-domain-joined context or before the join has replicated. Prove it with a direct `net use` mount and `klist` from a domain-joined host before chasing it.
- A `local_<username>` folder next to the profile VHD is normal FSLogix behaviour (temp redirection target, removed at logoff).

### Publishing and lock-down
- RemoteApp for a web application: publish `msedge.exe` with `--app=<url>` (clean window). `--kiosk` is too restrictive, `--new-window` keeps the full browser UI. Automatic client certificate selection: policy `AutoSelectCertificateForUrls` under `HKLM:\SOFTWARE\Policies\Microsoft\Edge`.
- Drive redirection is bidirectional; it cannot be made one-way. For "export to the local PC but nothing from the PC into the session" use clipboard transfer direction policies (Windows 11 23H2 and later: `Restrict clipboard transfer from server to client` and `from client to server`, `Disable clipboard transfers from client to server`), with the RDP property `drivestoredirect:s:` empty and `redirectclipboard:i:1`. The RDS ADMX templates are not in the default set; copy `terminalserver.admx/.adml` from a session host to the central store. File copy through the clipboard may depend on drive redirection on some clients; test it.
- To see the local C: in the session: connect with the Windows App (not the web client), enable `drivestoredirect` on the host pool, and set the GPO "Do not allow drive redirection" to Disabled (Enabled or Not configured overrides the host pool).
- Locking File Explorer RemoteApp is hard: the GPO "Prevent access to drives from My Computer" also breaks known-folder navigation (Downloads); navigation pane items stay visible even with loopback replace. Users can run scripts from their own profile share unless you add AppLocker or WDAC and NTFS controls.

### Operations
- There is no AVD-native scheduled restart. Use an Azure Automation runbook with an Automation schedule in the right time zone (handles DST), looping `Restart-AzVM`, or a Maintenance Configuration (guest scope, always reboot), which only reboots reliably when there is something to patch.
- Registration tokens are short-lived secrets: issue, use, revoke (`Register-SessionHost.ps1` does that).
- A session host registered under its short name before domain join stays Unavailable under the old record; delete the record, then re-register.

## Required network access

AVD session hosts need outbound access to these endpoints. Microsoft does not publish a fixed IP list for AVD, so define them as FQDN objects or the firewall's Microsoft service objects. Exempt them from web filtering and SSL inspection: a web filter category that blocks `enterpriseregistration.windows.net` breaks hybrid join, and TLS interception breaks agent and Intune traffic. Always check the current Microsoft list ("Required FQDNs and endpoints for Azure Virtual Desktop" and the Intune and Azure Monitor Agent network requirements) before relying on this one.

| Purpose | Port | Endpoints |
|---------|------|-----------|
| AVD service | 443 | `*.wvd.microsoft.com`, `*.service.windows.cloud.microsoft`, `*.windows.cloud.microsoft`, `*.windows.static.microsoft`, `login.microsoftonline.com`, `catalogartifact.azureedge.net`, `*.prod.warm.ingest.monitor.core.windows.net`, `gcs.prod.monitoring.core.windows.net`, `mrsglobalsteus2prod.blob.core.windows.net`, `wvdportalstorageblob.blob.core.windows.net` |
| AVD (certificate and revocation) | 80 | `oneocsp.microsoft.com`, `www.microsoft.com`, `ctldl.windowsupdate.com`, `*.aikcertaia.microsoft.com`, `azcsprodeusaikpublish.blob.core.windows.net`, `*.microsoftaik.azure.net` |
| Entra hybrid join / device registration | 443 | `enterpriseregistration.windows.net`, `certauth.enterpriseregistration.windows.net`, `device.login.microsoftonline.com`, `login.windows.net` |
| Intune | 443 | `manage.microsoft.com`, `*.manage.microsoft.com`, `*.dm.microsoft.com`, `config.edge.skype.com`, `ecs.office.com`, `*.notify.windows.com`, `*.wns.windows.com`, `go.microsoft.com` |
| Azure Monitor Agent | 443 | `global.handler.control.monitor.azure.com`, `<region>.handler.control.monitor.azure.com`, `<workspace-id>.ods.opinsights.azure.com`, `global.prod.microsoftmetrics.com` |
| Windows activation | TCP 1688 | `azkms.core.windows.net` (Azure KMS) |
| RDP Shortpath (TURN) | UDP 3478 | Microsoft TURN relay range for your region |

Per host pool subnet standard that worked: a dedicated small subnet with its own NSG (inbound only RDP Shortpath UDP 3390 from the VNet, AzureLoadBalancer, then Deny All), a route table sending default and internal ranges to the firewall, and the AVD platform policy listed above placed above the general internet policy, with no web filter and no SSL deep inspection. Watch the firewall log for denied traffic from the new subnet after the first host registers (typical misses: UDP 3478, TCP 1688, and a blocked `enterpriseregistration.windows.net`). Computer objects must be in an OU inside Entra Connect sync scope.

## More SSO, Kerberos and FSLogix notes

Additions to the lessons above; read them together.

### SSO: finding the service principals and checking the result
- Graph scopes: `Application.Read.All` and `Application-RemoteDesktopConfig.ReadWrite.All`; Entra role Application Administrator or Cloud Application Administrator; Microsoft Graph PowerShell SDK 2.9.0 or later.
- Look the service principals up by their well-known first-party app IDs (the same in every tenant):
  ```powershell
  $wclSpId  = (Get-MgServicePrincipal -Filter "AppId eq '270efc09-cd0d-444b-a71f-39af4910ec45'").Id  # Windows Cloud Login
  $msRdSpId = (Get-MgServicePrincipal -Filter "AppId eq 'a4a365df-50f1-4397-bc59-1a1564b8bb9c'").Id  # Microsoft Remote Desktop
  Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $wclSpId   # IsRemoteDesktopProtocolEnabled : True
  ```
  Current Microsoft Learn lists only Windows Cloud Login as required; older guidance enabled both, which is harmless. When the configuration object already exists, `New-...` fails: use `Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $wclSpId -IsRemoteDesktopProtocolEnabled`. The portal path is Entra ID > Devices > Remote connection configuration.
- The consent prompt is hidden with up to 10 target device groups on Windows Cloud Login (`New-MgServicePrincipalRemoteDesktopSecurityConfigurationTargetDeviceGroup`). A dynamic device group is the usual choice; it can take up to 24 hours to fill in large tenants.
- SSO on hybrid-joined hosts WITHOUT the Kerberos server object shows up as "the specific session doesn't exist" or as a normal password prompt (SSO silently skipped), not as a clear error.
- Hosts in a different AD domain than the users need a two-way trust, otherwise connections fall back to older authentication.
- SSO adds Windows Cloud Login as a new cloud app for Conditional Access: review policies that target Azure Virtual Desktop so they also cover it.

### Kerberos for privileged accounts
- The admin failure looks like a Conditional Access problem (sign-in error 70046, "MFA claim has expired") and does not go away with CA disabled, new tokens or revoked sessions. If only members of Protected Users or of privileged AD groups fail, stop debugging CA: it is the Cloud Kerberos Trust exclusion described above. The cloud partial TGT is refused by the writable domain controller for these accounts.

### FSLogix and file transfer
- `icacls` on a German (or other non-English) OS needs the localised group names (for example `VORDEFINIERT\Administratoren`, `ERSTELLER-BESITZER`); well-known SIDs avoid the problem: `*S-1-5-32-544` (Administrators), `*S-1-3-0` (CREATOR OWNER), `*S-1-5-32-545` (Users).
- When the clipboard-only export cannot carry files on a client, fall back to a controlled channel (OneDrive or a dedicated share with auditing) rather than turning drive redirection back on.
- After changing the clipboard or redirection GPOs: `gpupdate /force` on the host, restart the Remote Desktop Services service (`TermService`, which disconnects sessions) or sign the users out, then connect again and test.
- Edge automatic client certificate selection value format (one JSON string per entry): `{"pattern":"https://app.contoso.com","filter":{"ISSUER":{"CN":"Contoso Issuing CA"}}}`.

### Scheduled restart
- "Session host update" in AVD redeploys hosts from a new image or configuration; it is not a recurring restart. Use the Automation runbook described above.
