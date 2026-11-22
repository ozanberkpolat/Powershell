# App Control for Business (WDAC) tooling for AVD and Intune

Scripts that build App Control for Business policies locally, with ConfigCI, so they can be reviewed and then
uploaded to Intune by hand. Nothing here talks to Intune or Azure, and nothing deploys or activates a policy.

| Script | Purpose |
|---|---|
| `Build-AvdBasePolicy.ps1` | Base policy for AVD session hosts: AllowMicrosoft template + Managed Installer, audit mode, fixed policy GUID, version guard, rule option check |
| `New-SupplementalPolicy.ps1` | Per-application supplemental from a folder scan, signed files, an installer, a path and/or a probe XML |
| `Test-SupplementalPolicy.ps1` | Proves a built policy matches the files: recomputes CA TBS hashes, checks CertPublisher and FileAttrib chains |

All three target **Windows PowerShell 5.1** (`powershell.exe -NoProfile -File ...`), not pwsh 7.

## ConfigCI traps checklist

1. **ConfigCI only works in Windows PowerShell 5.1.** In pwsh 7 the module loads through implicit remoting and
   `New-CIPolicy -Rules` fails with `Deserialized.Microsoft.SecureBoot.UserConfig.Rule`. Run every script with
   `powershell.exe -NoProfile -File script.ps1`; the scripts here refuse to run in pwsh 7.
2. **Rule IDs: `ID_ALLOW_` must be followed by a letter.** The schema pattern (`C:\Windows\schemas\CodeIntegrity\cipolicy.xsd`)
   is `ID_ALLOW_[A-Z][_A-Z0-9]*`. `ID_ALLOW_7Z_...` is invalid. `ConvertFrom-CIPolicy` names only the LAST bad ID,
   so fix them all in one pass (the supplemental script checks every ID itself).
3. **Policy GUID is the identity.** Never change `PolicyID` of a deployed base, or Intune deploys a second base
   policy. Bump `VersionEx` for every change: Intune/CSP applies an update only with a higher version.
   `Set-CIPolicyIdInfo -PolicyId` only sets the PolicyInfo string; set `PolicyID`/`BasePolicyID` in the XML.
4. **Never assign two base policies to one device.** They intersect: a file must be allowed by both. Exclude the AVD
   device group from any laptop base policy before assigning the AVD base.
5. **Get a signer's TBS from ConfigCI, not by hand:** `New-CIPolicyRule -DriverFilePath <signed file> -Level Publisher`
   and read `CertRoot` from the XML. The hash algorithm follows the CA's own signature algorithm: SHA256 gives 64
   hex characters, SHA384 gives 96. `Test-SupplementalPolicy.ps1` recomputes it from the files.
6. **Extract an MSI without installing it:** `msiexec /a package.msi /qn TARGETDIR=C:\Work\extract`. The MSI copy
   that the administrative install leaves behind is stripped; hash the original, not that copy.
   For Inno Setup installers use a tool that unpacks without running them (for example innoextract or innounp).
7. **FilePublisher needs a file name.** Exes with an empty `OriginalFileName` cannot match a FilePublisher rule, and an
   MSI has no version field. Use a Publisher rule (CA TBS + CN) for those.
8. **MinimumFileVersion**: the scan writes the exact version of the scanned file. Set it to `0.0.0.0` (the default
   of `New-SupplementalPolicy.ps1`) so later versions still match; the rule stays bound to signer and file name.
9. **FilePath rules** are only safe on admin-writable folders (`C:\Program Files\App\*`). Runtime FilePath protection
   refuses user-writable paths anyway. Apps that self-update into the user profile need a signer rule.
10. **Self-updaters that do not go through Intune** (Remote Help, Webex, Teams) get no Managed Installer tag. They
    need a signer rule, and the signer may differ from the one on the installer (for example a WiX or .NET
    Foundation signer on a helper DLL).
11. **Unsigned releases happen.** Check `Get-AuthenticodeSignature` on every installer version you package; a vendor
    can publish an unsigned build, and a Publisher rule will not cover it.
12. **A scan of ~10 files can take over two minutes** (`New-CIPolicy -ScanPath`). Run it in the background or accept the wait.
13. **XML header comments cannot contain `--`.** Policy names are checked for it.
14. **Validate to a `.cip` with `ConvertFrom-CIPolicy` before handing a policy over.** The `.cip` is only a check;
    Intune takes the XML.
15. **Supplemental policies keep only option 6** (Unsigned System Integrity Policy). All other rule options belong to the base.
    The base must carry option 17 (Allow Supplemental Policies).
16. **Script enforcement.** With option 11 (Disabled:Script Enforcement) scripts stay in FullLanguage, but a DLL or
    EXE that a script compiles (`Add-Type`) is still blocked.
17. **Boot Audit On Failure (option 10):** a boot-start driver the policy blocks drops the whole policy to audit for that boot. Watch event 3099.

## Workflow

1. **Base once.** `powershell.exe -NoProfile -File .\Build-AvdBasePolicy.ps1 -PolicyName Contoso_AVD_Base`. Record the
   printed PolicyID. Upload the XML in Intune: Endpoint security > App Control for Business > Create policy > Enter
   XML data. Assign to a single pilot host first, then the device group.
2. **Managed installer.** Enable it for the AVD device group on the same Intune page. It is not retroactive: apps
   installed before it was switched on carry no tag and show up in the audit log. If a host has an AppLocker policy
   with an empty rule collection, clear it first, or that collection becomes enforced.
3. **Audit for at least two weeks.** Include an image update, an agent update, a Patch Tuesday and one Intune app
   deployment. Audit events: `Applications and Services Logs > Microsoft > Windows > CodeIntegrity > Operational`
   (3076 audit block, 3077 enforced block, 3089 signature detail, 3099 policy loaded). Defender advanced hunting:
   ```kql
   DeviceEvents
   | where Timestamp > ago(7d)
   | where ActionType in ("AppControlCodeIntegrityPolicyAudited", "AppControlCodeIntegrityPolicyBlocked")
   | summarize Hits = count(), Hosts = dcount(DeviceName) by FileName, FolderPath, InitiatingProcessFileName
   | order by Hits desc
   ```
4. **One supplemental per application** for everything the audit shows that is not Microsoft-signed or tagged by
   the managed installer. Pick the rule level by what the app is:

   | App | Source switch | Rule |
   |---|---|---|
   | Signed, stable file names | `-ScanPath <extract>` | FilePublisher, MinimumFileVersion 0.0.0.0, Publisher fallback |
   | Signed, empty OriginalFileName, MSI, or self-updating into user folders | `-PublisherFile <signed file>` | Publisher: CA TBS + CN |
   | Unsigned, installs under Program Files | `-InstallerPath <msi>` `-FilePathRule 'C:\Program Files\App\*'` | Installer hash + folder path |
   | Unsigned, already probed | `-ProbeXml <hash policy>` | Hash rules with safe IDs |

   ```powershell
   powershell.exe -NoProfile -File .\New-SupplementalPolicy.ps1 -BasePolicyId <base guid> `
       -PolicyName Contoso_Supp_10_App -OutDir C:\Work\app -ScanPath C:\Work\app\extract
   powershell.exe -NoProfile -File .\Test-SupplementalPolicy.ps1 `
       -PolicyXml C:\Work\app\Contoso_Supp_10_App.xml -FilesPath C:\Work\app\extract
   ```
   Keep the policy name numbering unique across teams that share a tenant. Name the Intune profile the same as the policy.
   Assign a supplemental to the same groups as its base (a subset works technically; assign to a pilot group first).
5. **Enforce.** Rebuild the base with `-Enforce -Version <higher>`, update the same Intune profile (same PolicyID, no reboot).
6. **Removal.** Replace the policy with an allow-all one first, then delete the profile; a deleted policy stays active until reboot.

## What the AllowMicrosoft base is and is not

It is a permissive start, not a hardening baseline: Microsoft-signed LOLBins (msbuild, mshta, wmic, regsvr32) and any
Store-signed app are allowed. Deliberately not set by default: ISG (14, 15), Store enforcement (12), WHQL requirement (2)
and the Microsoft recommended user-mode block rules (add them as a separate base later, never merged into this one).
Option 20 (Revoked Expired As Unsigned) blocks old, expired and timestamp-less redistributables.
