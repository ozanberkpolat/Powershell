<#
.SYNOPSIS
    Connect-ExchangeOnline on a client that enforces App Control (WDAC) by signing the temporary module.

.DESCRIPTION
    Connect-ExchangeOnline (ExchangeOnlineManagement v3) generates a temporary module named tmpEXO_<random>
    in %TEMP% and imports it. On a machine with an App Control for Business (WDAC) policy that enforces
    script rules, an unsigned script module is loaded in Constrained Language Mode (CLM). The import then
    fails or the cmdlets break, and the Code Integrity log shows event 8029 for the tmpEXO file.

    Connect-ExchangeOnline has a -SigningCertificate parameter: the module signs the generated tmpEXO files
    with that certificate, so a policy that trusts the certificate lets them run in Full Language mode.
    This module picks a valid code-signing certificate from Cert:\CurrentUser\My (by thumbprint or by
    subject), warns before it expires and passes it on.

    Functions
      Get-ExoSigningCertificate   Pick the newest valid code-signing certificate with a private key.
      Connect-ExoSigned           Connect-ExchangeOnline -SigningCertificate <that certificate> [other params].

.EXAMPLE
    Import-Module ./M365/Connect-ExoSigned.psm1
    Connect-ExoSigned -CertificateSubject 'CN=Contoso IT Script Signing' -UserPrincipalName admin@contoso.com

.EXAMPLE
    Connect-ExoSigned -CertificateThumbprint 0123456789ABCDEF0123456789ABCDEF01234567

.EXAMPLE
    # Same certificate selection for anything else you sign (Set-AuthenticodeSignature)
    $cert = Get-ExoSigningCertificate -CertificateSubject 'CN=Contoso IT Script Signing'

.NOTES
    Requires: ExchangeOnlineManagement v3 with the -SigningCertificate parameter (checked at run time).
    Role: whatever Exchange role your session needs; this module adds no permission.
    Traps kept from real use:
      - Without -SigningCertificate the tmpEXO_* module in %TEMP% is unsigned, App Control runs it in CLM and
        Code Integrity logs event 8029. The connect looks fine until the first cmdlet fails.
      - The certificate must be in the CURRENT USER store with its private key (HasPrivateKey). A cert that
        is only in LocalMachine, or was imported without the key, cannot sign.
      - The App Control policy must trust the signer (a signer rule for the certificate or its issuing CA),
        otherwise a signed tmpEXO module is still treated as untrusted.
      - This .psm1 is itself a script module: on an App Control machine it must be signed with a trusted
        certificate too, or it loads in CLM. Sign it once after every edit:
        Set-AuthenticodeSignature -FilePath .\Connect-ExoSigned.psm1 -Certificate $cert -TimestampServer <your TSA>
      - Selection: only code-signing certificates, matching subject exactly (or thumbprint), private key
        present, NotBefore <= now < NotAfter, newest NotAfter first. A renewed certificate therefore wins
        over the old one while both are installed.
      - A warning is printed when the chosen certificate expires within -ExpiryWarningDays (default 30).
        Renew it before then: once it expires the next connect falls back to CLM failures.
#>

Set-StrictMode -Version Latest

function Get-ExoSigningCertificate {
    [CmdletBinding(DefaultParameterSetName = 'BySubject')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BySubject')][string]$CertificateSubject,
        [Parameter(Mandatory, ParameterSetName = 'ByThumbprint')][string]$CertificateThumbprint,
        [int]$ExpiryWarningDays = 30
    )
    $now = Get-Date
    $all = @(Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert)
    $match = if ($PSCmdlet.ParameterSetName -eq 'ByThumbprint') {
        $tp = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
        @($all | Where-Object { $_.Thumbprint -eq $tp })
    } else {
        @($all | Where-Object { $_.Subject -eq $CertificateSubject })
    }
    $valid = @($match | Where-Object { $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -gt $now } |
        Sort-Object -Property NotAfter -Descending)

    if ($valid.Count -eq 0) {
        $what = if ($PSCmdlet.ParameterSetName -eq 'ByThumbprint') { "thumbprint $CertificateThumbprint" } else { "subject '$CertificateSubject'" }
        $hint = if ($match.Count) { " $($match.Count) certificate(s) matched but none is currently valid with a private key." } else { '' }
        throw "No valid code-signing certificate with $what and a private key in Cert:\CurrentUser\My for user $env:USERNAME.$hint"
    }
    $cert = $valid[0]
    if ($cert.NotAfter -lt $now.AddDays($ExpiryWarningDays)) {
        Write-Warning "Signing certificate $($cert.Thumbprint) expires on $($cert.NotAfter.ToString('yyyy-MM-dd')). Renew it before then."
    }
    $cert
}

function Connect-ExoSigned {
    <#
    .SYNOPSIS
        Connect-ExchangeOnline with -SigningCertificate. Extra parameters are passed through (-ExoParameter).
    .PARAMETER CertificateSubject
        Exact subject of the code-signing certificate, for example 'CN=Contoso IT Script Signing'.
    .PARAMETER CertificateThumbprint
        Thumbprint instead of subject.
    .PARAMETER UserPrincipalName
        Passed to Connect-ExchangeOnline.
    .PARAMETER ExoParameter
        Hashtable of any other Connect-ExchangeOnline parameters, for example @{ ShowBanner = $false }.
    #>
    [CmdletBinding(DefaultParameterSetName = 'BySubject')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'BySubject')][string]$CertificateSubject,
        [Parameter(Mandatory, ParameterSetName = 'ByThumbprint')][string]$CertificateThumbprint,
        [string]$UserPrincipalName,
        [hashtable]$ExoParameter = @{},
        [int]$ExpiryWarningDays = 30
    )
    $cmd = Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'Connect-ExchangeOnline not found. Install-Module ExchangeOnlineManagement -Scope CurrentUser' }
    if (-not $cmd.Parameters.ContainsKey('SigningCertificate')) {
        throw "ExchangeOnlineManagement $($cmd.Version) has no -SigningCertificate parameter. Update the module (v3 or later)."
    }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Warning "This session runs in $($ExecutionContext.SessionState.LanguageMode). Sign this module and your profile, or the connect will fail before the signed tmpEXO module is used."
    }

    $sel = @{ ExpiryWarningDays = $ExpiryWarningDays }
    if ($PSCmdlet.ParameterSetName -eq 'ByThumbprint') { $sel.CertificateThumbprint = $CertificateThumbprint } else { $sel.CertificateSubject = $CertificateSubject }
    $cert = Get-ExoSigningCertificate @sel
    Write-Verbose "Signing certificate $($cert.Thumbprint), valid until $($cert.NotAfter.ToString('yyyy-MM-dd'))"

    $params = @{} + $ExoParameter
    $params.SigningCertificate = $cert
    if ($UserPrincipalName) { $params.UserPrincipalName = $UserPrincipalName }
    Connect-ExchangeOnline @params
}

Export-ModuleMember -Function Connect-ExoSigned, Get-ExoSigningCertificate
