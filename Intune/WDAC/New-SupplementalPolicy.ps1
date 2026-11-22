#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a per-application App Control for Business (WDAC) supplemental policy from a scan of the app's files,
    signed files, an installer, a folder path and/or an existing probe XML.

.DESCRIPTION
    One policy per application, bound to an existing base policy (BasePolicyID). Rule levels, chosen by what the
    file really is, not by habit:

      * Signed files in a folder (-ScanPath): FilePublisher (issuing CA TBS + leaf CN + original file name +
        minimum file version), falling back to Publisher and then to Hash for files the scan cannot cover.
        MinimumFileVersion is rewritten to -MinimumFileVersion (default 0.0.0.0) so later versions still match;
        the rule stays bound to signer and file name.
      * Signed files that need a signer-wide rule (-PublisherFile): Publisher rule = CA TBS + leaf CN, no file
        name or version limit. Use it when the exe has an empty OriginalFileName (FilePublisher cannot match
        those), for MSI packages (no version field), and for apps that self-update into user-writable folders.
      * Unsigned installer (-InstallerPath): hash rule. A signed installer gets a Publisher rule instead.
      * Unsigned app under an admin-only folder (-FilePathRule 'C:\Program Files\App\*'): path rule. Refused for
        user-writable locations (profile, AppData, Temp, ProgramData), because any user could drop a file there.
      * A ConfigCI probe (-ProbeXml, a New-CIPolicy -Level Hash output): its hash rules are re-keyed with safe
        rule IDs and merged. *.sfx stubs are skipped (never run from the install folder; their hash cannot match
        a rebuilt SFX).

    The sources are merged with Merge-CIPolicy, the result is turned into a supplemental policy for the base,
    every rule option except 6 (Unsigned System Integrity Policy) is removed (they are base-only), kernel-mode
    signer entries are stripped, all rule IDs are checked against the schema pattern, and the XML is compiled to
    a .cip as validation. The .cip is NOT deployed; upload the XML to Intune (Endpoint security > App Control).

    Local file generation only. Never calls CiTool, the ApplicationControl CSP, Intune or Azure.

.PARAMETER BasePolicyId
    PolicyID GUID of the base policy this supplements (the base must carry option 17, Allow Supplemental Policies).

.PARAMETER PolicyName
    Policy name, for example Contoso_Supp_10_WinSCP. Must not contain a double hyphen.

.PARAMETER OutDir
    Output folder (created). Receives <PolicyName>.xml, the validation .cip and an evidence subfolder.

.PARAMETER ScanPath
    Folder with the application's files (installed layout, or an admin extract made with msiexec /a).

.PARAMETER PublisherFile
    One or more signed files whose signer should be allowed as a whole (Publisher rule).

.PARAMETER InstallerPath
    The MSI/EXE installer. Signed: Publisher rule. Unsigned: hash rule.

.PARAMETER FilePathRule
    Path rules for unsigned apps in admin-only folders, for example 'C:\Program Files\7-Zip\*'.

.PARAMETER ProbeXml
    An existing New-CIPolicy hash-level XML to convert (hash rules only).

.PARAMETER RulePrefix
    Prefix for re-keyed probe rule IDs (letters, digits, underscore). Default APP.

.PARAMETER MinimumFileVersion
    Value written into every FilePublisher FileAttrib. Default 0.0.0.0. Pass an empty string to keep the scanned versions.

.PARAMETER PolicyGuid
    PolicyID of this supplemental. Default: a new GUID. Reuse the same GUID when you rebuild a deployed policy.

.PARAMETER Version
    Policy version. Default 10.0.0.0. Raise it for every rebuild of a deployed policy.

.PARAMETER ExcludeFilePattern
    Probe rules whose file name matches one of these wildcards are skipped. Default *.sfx.

.EXAMPLE
    powershell.exe -NoProfile -File .\New-SupplementalPolicy.ps1 -BasePolicyId 00000000-0000-0000-0000-000000000000 `
        -PolicyName Contoso_Supp_10_WinSCP -OutDir C:\Work\winscp -ScanPath C:\Work\winscp\extract

.EXAMPLE
    # Zip-free signer rule for an agent whose exes have an empty OriginalFileName, plus its MSI
    powershell.exe -NoProfile -File .\New-SupplementalPolicy.ps1 -BasePolicyId <guid> -PolicyName Contoso_Supp_11_Agent `
        -OutDir C:\Work\agent -PublisherFile C:\Work\agent\agent.msi

.EXAMPLE
    # Unsigned app: installer hash + admin-only folder path
    powershell.exe -NoProfile -File .\New-SupplementalPolicy.ps1 -BasePolicyId <guid> -PolicyName Contoso_Supp_12_Tool `
        -OutDir C:\Work\tool -InstallerPath C:\Work\tool\tool.msi -FilePathRule 'C:\Program Files\Tool\*'

.NOTES
    Required: Windows PowerShell 5.1 (powershell.exe), ConfigCI module. No Azure or Graph access.
    Traps handled in code: rule IDs must match ID_ALLOW_[A-Z][_A-Z0-9]* (a digit right after ID_ALLOW_ is
    invalid, and ConvertFrom-CIPolicy only names the LAST bad ID, so all IDs are checked here first); the
    ConfigCI cmdlets break in pwsh 7 (implicit remoting); the CA hash algorithm follows the CA's own signature
    algorithm (SHA256 gives 64 hex chars, SHA384 gives 96). A scan of many files can take minutes.
    Check the result with Test-SupplementalPolicy.ps1 and see README.md for the workflow.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BasePolicyId,
    [Parameter(Mandatory)][string]$PolicyName,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$ScanPath,
    [string[]]$PublisherFile,
    [string]$InstallerPath,
    [string[]]$FilePathRule,
    [string]$ProbeXml,
    [string]$RulePrefix = 'APP',
    [string]$MinimumFileVersion = '0.0.0.0',
    [string]$PolicyGuid,
    [string]$Version = '10.0.0.0',
    [string[]]$ExcludeFilePattern = @('*.sfx')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run in Windows PowerShell 5.1 (powershell.exe). ConfigCI under pwsh 7 uses implicit remoting and fails.'
}
if ($PolicyName -match '--') { throw "PolicyName must not contain '--'." }
if (-not ($ScanPath -or $PublisherFile -or $InstallerPath -or $FilePathRule -or $ProbeXml)) {
    throw 'Give at least one source: -ScanPath, -PublisherFile, -InstallerPath, -FilePathRule or -ProbeXml.'
}
$base = '{' + ([guid]$BasePolicyId).ToString().ToUpper() + '}'
$self = if ($PolicyGuid) { '{' + ([guid]$PolicyGuid).ToString().ToUpper() + '}' } else { '{' + [guid]::NewGuid().ToString().ToUpper() + '}' }
$ns = @{ si = 'urn:schemas-microsoft-com:sipolicy' }
$idPattern = '^ID_ALLOW_[A-Z][_A-Z0-9]*$'    # cipolicy.xsd: first char after ID_ALLOW_ must be a letter

New-Item -ItemType Directory -Force $OutDir | Out-Null
$evidence = Join-Path $OutDir 'evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$xml = Join-Path $OutDir "$PolicyName.xml"
$cip = Join-Path $evidence "$PolicyName.validate.cip"
$parts = New-Object System.Collections.Generic.List[string]

function Assert-SafeFilePath([string]$Rule) {
    # Runtime FilePath protection also refuses user-writable locations; do not build a rule that cannot work.
    if ($Rule -match '(?i)\\Users\\|%USERPROFILE%|%LOCALAPPDATA%|%APPDATA%|\\AppData\\|\\Temp\\|%TEMP%|%PROGRAMDATA%|\\ProgramData\\') {
        throw "FilePath rule '$Rule' points to a user-writable location. Use a signer or hash rule instead."
    }
    if ($Rule -notmatch '^[A-Za-z]:\\.+\\') { throw "FilePath rule '$Rule' is too broad or not an absolute path." }
}

# --- 1. Folder scan: FilePublisher, then Publisher, then Hash ------------------------------------
if ($ScanPath) {
    if (-not (Test-Path $ScanPath -PathType Container)) { throw "ScanPath not found: $ScanPath" }
    $scanXml = Join-Path $evidence 'part-scan.xml'
    $scanLog = Join-Path $evidence 'new-cipolicy-output.txt'
    New-CIPolicy -ScanPath $ScanPath -Level FilePublisher -Fallback Publisher, Hash -UserPEs -MultiplePolicyFormat `
        -FilePath $scanXml *>&1 | Out-File -Encoding UTF8 $scanLog
    if (-not (Test-Path $scanXml)) { throw "New-CIPolicy produced no XML, see $scanLog" }
    if ($MinimumFileVersion) {
        [xml]$p = Get-Content -Raw -Encoding UTF8 $scanXml
        foreach ($a in @(Select-Xml -Xml $p -XPath '//si:FileRules/si:FileAttrib' -Namespace $ns | ForEach-Object { $_.Node })) {
            if ($a.MinimumFileVersion) { $a.MinimumFileVersion = $MinimumFileVersion }
        }
        $p.Save($scanXml)
    }
    $parts.Add($scanXml)
}

# --- 2. Signer-wide Publisher rules, installer, path rules ---------------------------------------
$ruleObjects = New-Object System.Collections.Generic.List[object]
foreach ($f in @($PublisherFile)) {
    if (-not $f) { continue }
    if (-not (Test-Path $f -PathType Leaf)) { throw "PublisherFile not found: $f" }
    $sig = Get-AuthenticodeSignature $f
    if ($sig.Status -ne 'Valid') { throw "$f is not validly signed (status $($sig.Status)). Cannot build a Publisher rule." }
    # Level Publisher = issuing CA TBS + leaf CN. The TBS is read back from the generated XML, not computed by hand.
    foreach ($r in @(New-CIPolicyRule -DriverFilePath $f -Level Publisher)) { $ruleObjects.Add($r) }
}
if ($InstallerPath) {
    if (-not (Test-Path $InstallerPath -PathType Leaf)) { throw "InstallerPath not found: $InstallerPath" }
    $sig = Get-AuthenticodeSignature $InstallerPath
    $level = if ($sig.Status -eq 'Valid') { 'Publisher' } elseif ($sig.Status -eq 'NotSigned') { 'Hash' } else { throw "Installer signature status is $($sig.Status). Fix or replace the installer." }
    Write-Verbose "Installer $InstallerPath is $($sig.Status): $level rule."
    foreach ($r in @(New-CIPolicyRule -DriverFilePath $InstallerPath -Level $level)) { $ruleObjects.Add($r) }
}
foreach ($fp in @($FilePathRule)) {
    if (-not $fp) { continue }
    Assert-SafeFilePath $fp
    foreach ($r in @(New-CIPolicyRule -FilePathRule $fp)) { $ruleObjects.Add($r) }
}
if ($ruleObjects.Count -gt 0) {
    $ruleXml = Join-Path $evidence 'part-rules.xml'
    New-CIPolicy -Rules $ruleObjects.ToArray() -FilePath $ruleXml -MultiplePolicyFormat | Out-Null
    if (-not (Test-Path $ruleXml)) { throw 'New-CIPolicy -Rules produced no XML.' }
    $parts.Add($ruleXml)
}

# --- 3. Probe XML: re-key hash rules with safe IDs ----------------------------------------------
if ($ProbeXml) {
    [xml]$probe = Get-Content -Raw -Encoding UTF8 $ProbeXml
    $allows = @(Select-Xml -Xml $probe -XPath '//si:FileRules/si:Allow' -Namespace $ns | ForEach-Object { $_.Node })
    if ($allows.Count -eq 0) { throw "No Allow rules in $ProbeXml" }
    $pre = ($RulePrefix.ToUpper() -replace '[^A-Z0-9]', '_')
    if ($pre -notmatch '^[A-Z]') { $pre = "X$pre" }
    $n = 0; $seen = @{}
    foreach ($a in $allows) {
        $n++
        $file = if ($a.FriendlyName -match '\\([^\\]+?) (Hash .+)$') { $Matches[1] } else { "FILE$n" }
        if ($ExcludeFilePattern | Where-Object { $file -like $_ }) { Write-Verbose "Skipped $file"; $a.ParentNode.RemoveChild($a) | Out-Null; continue }
        $kind = if ($a.FriendlyName -match ' Hash (.+)$') { ($Matches[1] -replace '[^A-Za-z0-9]', '').ToUpper() } else { 'HASH' }
        $newId = ('ID_ALLOW_{0}_{1}_{2}' -f $pre, ($file -replace '[^A-Za-z0-9]', '_').ToUpper(), $kind)
        if ($seen.ContainsKey($newId)) { $newId = "${newId}_$n" }
        $seen[$newId] = $true
        $oldId = $a.ID; $a.ID = $newId
        foreach ($ref in @(Select-Xml -Xml $probe -XPath "//si:FileRuleRef[@RuleID='$oldId']" -Namespace $ns | ForEach-Object { $_.Node })) { $ref.RuleID = $newId }
    }
    if (@(Select-Xml -Xml $probe -XPath '//si:FileRules/si:Allow' -Namespace $ns).Count -eq 0) { throw 'All probe rules were excluded.' }
    $probeOut = Join-Path $evidence 'part-probe.xml'
    $probe.Save($probeOut)
    $parts.Add($probeOut)
}

# --- 4. Merge, turn into a supplemental ----------------------------------------------------------
if ($parts.Count -eq 1) {
    Copy-Item $parts[0] $xml -Force
} else {
    Merge-CIPolicy -PolicyPaths $parts.ToArray() -OutputFilePath $xml | Out-Null
}
if (-not (Test-Path $xml)) { throw 'No policy XML produced.' }

Set-CIPolicyIdInfo -FilePath $xml -PolicyName $PolicyName -SupplementsBasePolicyID $base -ResetPolicyID | Out-Null
Set-CIPolicyVersion -FilePath $xml -Version $Version
if ($PolicyGuid) {
    [xml]$d = Get-Content -Raw -Encoding UTF8 $xml
    $d.SiPolicy.PolicyID = $self
    $d.Save($xml)
}

# Keep only option 6 (Unsigned System Integrity Policy); every other default option is base-only.
for ($i = 0; $i -le 20; $i++) { if ($i -ne 6) { Set-RuleOption -FilePath $xml -Option $i -Delete } }
Set-RuleOption -FilePath $xml -Option 6

# Strip kernel-mode signer entries (scenario 131): an app supplemental has no business allowing drivers.
[xml]$d = Get-Content -Raw -Encoding UTF8 $xml
$kernel = @(Select-Xml -Xml $d -XPath "//si:SigningScenario[@Value='131']/si:ProductSigners/*" -Namespace $ns | ForEach-Object { $_.Node })
foreach ($k in $kernel) { Write-Warning "Removing kernel-mode entry <$($k.Name)> from the policy."; $k.ParentNode.RemoveChild($k) | Out-Null }
$d.Save($xml)

# --- 5. Validate ---------------------------------------------------------------------------------
[xml]$d = Get-Content -Raw -Encoding UTF8 $xml
$allow = @(Select-Xml -Xml $d -XPath '//si:FileRules/si:Allow | //si:FileRules/si:FileAttrib' -Namespace $ns | ForEach-Object { $_.Node })
$signers = @(Select-Xml -Xml $d -XPath '//si:Signers/si:Signer' -Namespace $ns | ForEach-Object { $_.Node })
if ($allow.Count + $signers.Count -eq 0) { throw 'The policy has no rules and no signers. An empty supplemental allows nothing: investigate the inputs.' }
$badIds = @(Select-Xml -Xml $d -XPath '//si:FileRules/si:Allow' -Namespace $ns | ForEach-Object { $_.Node.ID } | Where-Object { $_ -notmatch $idPattern })
if ($badIds.Count -gt 0) { throw "Rule IDs that break the schema pattern $idPattern : $($badIds -join ', ')" }
$dupes = @(Select-Xml -Xml $d -XPath '//@ID' -Namespace $ns | ForEach-Object { $_.Node.Value } | Group-Object | Where-Object Count -gt 1)
if ($dupes.Count -gt 0) { throw "Duplicate IDs: $($dupes.Name -join ', ')" }
if ($d.SiPolicy.PolicyType -ne 'Supplemental Policy') { throw "PolicyType is '$($d.SiPolicy.PolicyType)'" }
if ($d.SiPolicy.BasePolicyID -ne $base) { throw "BasePolicyID is $($d.SiPolicy.BasePolicyID)" }

ConvertFrom-CIPolicy -XmlFilePath $xml -BinaryFilePath $cip | Out-Null
if (-not (Test-Path $cip) -or (Get-Item $cip).Length -eq 0) { throw "Validation binary not produced: $cip" }

[pscustomobject]@{
    Policy        = $PolicyName
    PolicyID      = $d.SiPolicy.PolicyID
    BasePolicyID  = $d.SiPolicy.BasePolicyID
    Version       = $d.SiPolicy.VersionEx
    HashRules     = @(Select-Xml -Xml $d -XPath '//si:FileRules/si:Allow[@Hash]' -Namespace $ns).Count
    PathRules     = @(Select-Xml -Xml $d -XPath '//si:FileRules/si:Allow[@FilePath]' -Namespace $ns).Count
    FileAttribs   = @(Select-Xml -Xml $d -XPath '//si:FileRules/si:FileAttrib' -Namespace $ns).Count
    Signers       = $signers.Count
    Xml           = $xml
    ValidationCip = $cip
}
Write-Warning 'The .cip is for validation only. Upload the XML to Intune; do not copy the .cip into CodeIntegrity\CiPolicies on a production host.'
