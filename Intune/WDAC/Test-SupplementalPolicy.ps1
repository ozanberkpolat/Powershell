#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only check of a built App Control supplemental policy against the signed files it was built from.

.DESCRIPTION
    ConfigCI reports that a policy is well-formed, not that it matches the files. This script proves it:
      * Recomputes the TBS hash of every certificate embedded in the signed files of -FilesPath and matches each
        policy Signer's CertRoot value to one of them. SHA1/256/384/512 follow the certificate's own signature
        algorithm (the same rule ConfigCI uses).
      * Checks each Signer's CertPublisher against the leaf certificate CN of the files whose chain contains
        that CertRoot.
      * Lists, per file, the signature status, OriginalFileName, the FileAttrib that matches it, the signers that
        reference that FileAttrib and whether they are allowed in the user-mode scenario (12).
      * Optionally traces one file (-TraceFile) down the whole chain: file, FileAttrib, FileAttribRef, Signer,
        signing scenario. Use it for the DLL that audit logs showed as blocked.
    Files with no matching rule are listed; unsigned files without a hash rule are reported as problems.
    Throws at the end if any check failed, so it can gate a pipeline. Never deploys or refreshes a policy.

.PARAMETER PolicyXml
    Path of the supplemental (or base) policy XML.

.PARAMETER FilesPath
    Folder with the files the policy was built from (installed layout or admin extract).

.PARAMETER TraceFile
    Optional file name or relative path inside FilesPath to trace in detail.

.EXAMPLE
    powershell.exe -NoProfile -File .\Test-SupplementalPolicy.ps1 -PolicyXml .\Contoso_Supp_10_App.xml -FilesPath C:\Work\app\extract

.EXAMPLE
    powershell.exe -NoProfile -File .\Test-SupplementalPolicy.ps1 -PolicyXml .\policy.xml -FilesPath C:\Work\app\extract -TraceFile bin\helper.dll

.NOTES
    Required: Windows PowerShell 5.1 or pwsh 7 on Windows (no ConfigCI needed; uses System.Security). No Azure access.
    A signer rule built at Publisher level matches by CA TBS plus leaf CN, so an app that has its own file-name
    rules (FileAttrib) can show "no rule" for files that the signer rule covers anyway; read the Signer section first.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PolicyXml,
    [Parameter(Mandatory)][string]$FilesPath,
    [string]$TraceFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

$problems = New-Object System.Collections.Generic.List[string]

function Get-DerLength([byte[]]$b, [int]$i) {
    # returns @(contentOffset, contentLength) for the TLV at $i
    $l = $b[$i + 1]
    if ($l -lt 0x80) { return @(($i + 2), [int]$l) }
    $n = $l -band 0x7F; $len = 0
    for ($k = 0; $k -lt $n; $k++) { $len = ($len -shl 8) -bor $b[$i + 2 + $k] }
    return @(($i + 2 + $n), $len)
}

function Get-TbsHash([Security.Cryptography.X509Certificates.X509Certificate2]$c) {
    $der = $c.RawData
    if ($der[0] -ne 0x30) { throw 'Certificate is not a DER SEQUENCE' }
    $outer = Get-DerLength $der 0
    $tStart = $outer[0]
    $inner = Get-DerLength $der $tStart
    $tLen = ($inner[0] - $tStart) + $inner[1]
    $tbs = New-Object byte[] $tLen
    [Array]::Copy($der, $tStart, $tbs, 0, $tLen)
    $alg = switch -Wildcard ($c.SignatureAlgorithm.FriendlyName) {
        'sha1*'   { [Security.Cryptography.SHA1]::Create(); break }
        'sha256*' { [Security.Cryptography.SHA256]::Create(); break }
        'sha384*' { [Security.Cryptography.SHA384]::Create(); break }
        'sha512*' { [Security.Cryptography.SHA512]::Create(); break }
        default   { throw "Unhandled signature algorithm $($c.SignatureAlgorithm.FriendlyName)" }
    }
    -join ($alg.ComputeHash($tbs) | ForEach-Object { $_.ToString('X2') })
}

function Get-EmbeddedCerts([string]$path) {
    # PE files: read the PKCS#7 blob from the certificate table (no network needed).
    # Anything else (MSI, scripts): build the chain from the signer certificate.
    $b = [IO.File]::ReadAllBytes($path)
    $isPe = $b.Length -gt 0x40 -and $b[0] -eq 0x4D -and $b[1] -eq 0x5A
    if ($isPe) {
        $pe = [BitConverter]::ToInt32($b, 0x3C)
        $magic = [BitConverter]::ToUInt16($b, $pe + 24)
        $dd = if ($magic -eq 0x20b) { $pe + 24 + 112 } else { $pe + 24 + 96 }
        $off = [BitConverter]::ToUInt32($b, $dd + 32)
        if ($off -eq 0) { return @() }
        $len = [BitConverter]::ToUInt32($b, $off)        # WIN_CERTIFICATE.dwLength
        $pkcs = New-Object byte[] ($len - 8)
        [Array]::Copy($b, $off + 8, $pkcs, 0, $len - 8)
        $cms = New-Object Security.Cryptography.Pkcs.SignedCms
        $cms.Decode($pkcs)
        return @($cms.Certificates)
    }
    $sig = Get-AuthenticodeSignature $path
    if (-not $sig.SignerCertificate) { return @() }
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    [void]$chain.Build($sig.SignerCertificate)
    return @($chain.ChainElements | ForEach-Object { $_.Certificate })
}

if (-not (Test-Path $PolicyXml)) { throw "PolicyXml not found: $PolicyXml" }
$FilesPath = (Resolve-Path $FilesPath).Path
[xml]$p = Get-Content -Raw -Encoding UTF8 $PolicyXml
$ns = New-Object Xml.XmlNamespaceManager $p.NameTable
$ns.AddNamespace('si', 'urn:schemas-microsoft-com:sipolicy')

"== Policy identity"
"PolicyType   : $($p.SiPolicy.PolicyType)"
"PolicyID     : $($p.SiPolicy.PolicyID)"
"BasePolicyID : $($p.SiPolicy.BasePolicyID)"
"VersionEx    : $($p.SiPolicy.VersionEx)"
"Name         : $($p.SelectSingleNode("//si:Setting[@ValueName='Name']//si:String", $ns).InnerText)"
"Rule options : $((@($p.SiPolicy.Rules.Rule) | ForEach-Object { $_.Option }) -join '; ')"
$hashRules = @($p.SelectNodes('//si:FileRules/si:Allow[@Hash]', $ns))
"Hash rules   : $($hashRules.Count)"
""

$files = @(Get-ChildItem $FilesPath -Recurse -File)
if ($files.Count -eq 0) { throw "No files under $FilesPath" }

# Index of every certificate embedded in a validly signed file, keyed by TBS hash.
$certIndex = @{}
foreach ($f in $files) {
    $s = Get-AuthenticodeSignature $f.FullName
    if ($s.Status -ne 'Valid') { continue }
    foreach ($c in (Get-EmbeddedCerts $f.FullName)) {
        $h = Get-TbsHash $c
        if (-not $certIndex.ContainsKey($h)) {
            $certIndex[$h] = [pscustomobject]@{ Subject = $c.Subject; Issuer = $c.Issuer; Files = New-Object Collections.Generic.List[string] }
        }
        $rel = $f.FullName.Substring($FilesPath.Length).TrimStart('\')
        if (-not $certIndex[$h].Files.Contains($rel)) { $certIndex[$h].Files.Add($rel) }
    }
}

"== Signers: CertRoot (TBS) recomputed from the files' embedded certificates"
$signerNodes = @($p.SelectNodes('//si:Signers/si:Signer', $ns))
if ($signerNodes.Count -eq 0 -and $hashRules.Count -eq 0) { $problems.Add('Policy has neither signers nor hash rules.') }
foreach ($sg in $signerNodes) {
    $tbs = $sg.SelectSingleNode('si:CertRoot', $ns).GetAttribute('Value')
    $hit = $certIndex[$tbs]
    $attribIds = @($sg.SelectNodes('si:FileAttribRef', $ns) | ForEach-Object { $_.RuleID })
    $names = @($attribIds | ForEach-Object { $p.SelectSingleNode("//si:FileAttrib[@ID='$_']", $ns).FileName })
    "Signer $($sg.ID) '$($sg.Name)'"
    "  CertRoot TBS : $tbs"
    if ($hit) {
        "  MATCH        : $($hit.Subject)"
        "                 issued by $($hit.Issuer)"
        "                 embedded in $($hit.Files -join ', ')"
        $leafCns = @($hit.Files | ForEach-Object {
            (Get-AuthenticodeSignature (Join-Path $FilesPath $_)).SignerCertificate.GetNameInfo('SimpleName', $false)
        } | Sort-Object -Unique)
        $pubNode = $sg.SelectSingleNode('si:CertPublisher', $ns)
        if ($pubNode) {
            $pubOk = $leafCns -contains $pubNode.GetAttribute('Value')
            "  CertPublisher: $($pubNode.GetAttribute('Value'))  | leaf CN(s): $($leafCns -join ', ')  | $(if ($pubOk) {'MATCH'} else {'MISMATCH'})"
            if (-not $pubOk) { $problems.Add("Signer $($sg.ID): CertPublisher '$($pubNode.GetAttribute('Value'))' is not a leaf CN of the matching files.") }
        }
    } else {
        "  NO MATCH in any embedded certificate"
        $problems.Add("Signer $($sg.ID): CertRoot $tbs matches no certificate in $FilesPath (wrong files, wrong hash algorithm, or a stale policy).")
    }
    "  FileAttribRef: $($names -join ', ')"
    ""
}

"== Per file: signature, OriginalFileName, matching FileAttrib, signers, scenario"
$umci = @($p.SelectNodes("//si:SigningScenario[@Value='12']//si:AllowedSigner", $ns) | ForEach-Object { $_.SignerId })
foreach ($f in $files) {
    $rel = $f.FullName.Substring($FilesPath.Length).TrimStart('\')
    $st = (Get-AuthenticodeSignature $f.FullName).Status
    $ofn = $f.VersionInfo.OriginalFilename
    $fa = @($p.SelectNodes('//si:FileRules/si:FileAttrib', $ns) | Where-Object { $_.FileName -eq $ofn })
    if ($fa.Count -eq 0) {
        $note = 'no FileAttrib rule'
        if ($st -eq 'NotSigned') {
            # Unsigned: only a hash or path rule can cover it. Authenticode hash needs ConfigCI; report for manual check.
            $note = 'unsigned, needs a hash or path rule (verify with Get-CIPolicyInfo or the audit log)'
        }
        "{0,-34} {1,-10} OriginalFileName={2,-18} {3}" -f $rel, $st, $ofn, $note
        continue
    }
    $sids = @($fa | ForEach-Object { $id = $_.ID; $p.SelectNodes("//si:Signer[si:FileAttribRef/@RuleID='$id']", $ns) | ForEach-Object { $_.ID } })
    $inUmci = @($sids | Where-Object { $umci -contains $_ }).Count -gt 0
    "{0,-34} {1,-10} OriginalFileName={2,-18} FileAttrib={3} Signers={4} UMCI(12)={5}" -f $rel, $st, $ofn, (($fa | ForEach-Object { $_.ID }) -join ','), ($sids -join ','), $inUmci
    if (-not $inUmci) { $problems.Add("$rel has a FileAttrib but no signer allowing it in the user-mode scenario (12).") }
}
""

if ($TraceFile) {
    "== Trace: $TraceFile"
    $match = @($files | Where-Object { $_.FullName.EndsWith($TraceFile, [StringComparison]::OrdinalIgnoreCase) })
    if ($match.Count -ne 1) { $problems.Add("TraceFile '$TraceFile' matched $($match.Count) files."); } else {
        $f = $match[0]
        $b = [IO.File]::ReadAllBytes($f.FullName)
        $machine = if ($b.Length -gt 0x40 -and $b[0] -eq 0x4D) { '0x' + ([BitConverter]::ToUInt16($b, [BitConverter]::ToInt32($b, 0x3C) + 4)).ToString('X4') } else { 'n/a (not PE)' }
        $sig = Get-AuthenticodeSignature $f.FullName
        "File            : $($f.Name) ($($f.Length) bytes, machine $machine, FileVersion $($f.VersionInfo.FileVersion))"
        "OriginalFileName: $($f.VersionInfo.OriginalFilename)"
        "Signature       : $($sig.Status), leaf $($sig.SignerCertificate.Subject)"
        $fa = $p.SelectSingleNode("//si:FileAttrib[@FileName='$($f.VersionInfo.OriginalFilename)']", $ns)
        if (-not $fa) { "FileAttrib      : none" } else {
            "FileAttrib      : $($fa.OuterXml)"
            foreach ($s in @($p.SelectNodes("//si:Signer[si:FileAttribRef/@RuleID='$($fa.ID)']", $ns))) {
                "FileAttribRef in: $($s.ID) '$($s.Name)' CertPublisher=$($s.SelectSingleNode('si:CertPublisher', $ns).GetAttribute('Value')) AllowedSigner in scenario 12: $($umci -contains $s.ID)"
            }
        }
    }
}

""
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Warning $_ }
    throw "$($problems.Count) check(s) failed. See the warnings above."
}
'All checks passed.'
