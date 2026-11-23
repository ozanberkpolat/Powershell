<#
.SYNOPSIS
    Read-only health evidence for on-premises Exchange web endpoints (OWA, ECP, EWS, MAPI, ActiveSync,
    Autodiscover) using the native curl.exe, plus IIS and real-client traffic evidence.

.DESCRIPTION
    Runs INSIDE the Exchange server (Windows PowerShell 5.1, as administrator or SYSTEM through Run Command).
    Changes nothing.

      1. curl.exe probes of each endpoint on https://localhost and, with -Fqdn, on the published name.
         /owa/healthcheck.htm must answer 200; the others answer 401/302 when alive (they demand auth).
      2. Exchange IIS application pools (all must be Started) and site bindings.
      3. sslFlags on Default Web Site, /owa and /ecp (client certificates required by accident?).
      4. Exchange certificates and their expiry.
      5. Real client traffic: HTTP status distribution of authenticated requests in the newest front-end
         IIS log since -Since (UTC). Production traffic that answers 200 is the strongest evidence.
      6. Tail of the HTTPERR log (connection resets at http.sys level).

    Ends with RESULT=<HEALTHY|ATTENTION>;... and exit code 0/1.

.PARAMETER Fqdn
    Published host name to probe besides localhost, for example mail.contoso.com.
.PARAMETER Since
    UTC start for the IIS log analysis. Default: 60 minutes ago.
.PARAMETER ExpectedCodes
    Hashtable path -> allowed HTTP codes. The defaults are what a healthy server answers unauthenticated.
.PARAMETER IisSiteId
    W3SVC id of the front-end site (Default Web Site). Default 1.

.EXAMPLE
    ./Azure/Compute/Invoke-VmRunCommand.ps1 -VmName vm-exch-01 -ResourceGroup rg-mail -ScriptPath ./Exchange-OnPrem/Test-ExchangeEndpoints.ps1 `
        -Parameter @{ Fqdn = 'mail.contoso.com' }

.EXAMPLE
    .\Test-ExchangeEndpoints.ps1 -Fqdn mail.contoso.com -Since (Get-Date).ToUniversalTime().AddMinutes(-30)

.NOTES
    Role: local administrator (IIS configuration and logs). Through Run Command: Virtual Machine Contributor.
    Requires curl.exe (built into Windows Server 2019 and later, Windows 10 1803+).
    Traps kept from real use:
      - Invoke-WebRequest (.NET HTTP stack) reported OWA as failing after maintenance while OWA was
        healthy: a client-side TLS artifact. Native curl.exe answered 200 on the same URL. Use curl.exe for
        evidence, and corroborate with real client traffic in the IIS log.
      - -k skips certificate validation on purpose: localhost never matches the certificate name. Check the
        certificate separately (section 4) and probe the FQDN for the real name.
      - 401 from /EWS, /mapi, /Microsoft-Server-ActiveSync and /autodiscover means alive and demanding auth;
        /ecp answers 302 (redirect to login). Only healthcheck.htm must be 200.
      - The IIS log time is UTC and fields are space separated: date time s-ip cs-method cs-uri-stem
        cs-uri-query s-port cs-username c-ip ... sc-status. A cs-username of "-" is an unauthenticated
        request (probes, load balancer checks); count authenticated ones as client evidence.
#>
[CmdletBinding()]
param(
    [string]$Fqdn,
    [datetime]$Since = (Get-Date).ToUniversalTime().AddMinutes(-60),
    [hashtable]$ExpectedCodes = @{
        '/owa/healthcheck.htm'           = @('200')
        '/ecp/'                          = @('200', '302', '401')
        '/EWS/Exchange.asmx'             = @('401')
        '/mapi/emsmdb'                   = @('401')
        '/Microsoft-Server-ActiveSync'   = @('401')
        '/autodiscover/autodiscover.xml' = @('401')
    },
    [int]$IisSiteId = 1
)

$ErrorActionPreference = 'Stop'
$problems = @()

"=== 1. curl.exe probes (native TLS, not .NET) ==="
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $curl)) {
    "curl.exe NOT PRESENT"
    $problems += 'no-curl'
} else {
    $hosts = @('localhost') + @($Fqdn | Where-Object { $_ })
    foreach ($h in $hosts) {
        foreach ($path in ($ExpectedCodes.Keys | Sort-Object)) {
            $u = "https://$h$path"
            $code = (& $curl -sS -k -m 25 -o NUL -w '%{http_code}' $u 2>&1 | Out-String).Trim()
            $ok = $ExpectedCodes[$path] -contains $code
            '{0,-6} {1,-4} {2}' -f $(if ($ok) { 'ok' } else { 'BAD' }), $code, $u
            if (-not $ok) { $problems += "$h$path=$code" }
        }
    }
    "--- healthcheck.htm body (localhost) ---"
    (& $curl -sS -k -m 25 'https://localhost/owa/healthcheck.htm' 2>&1 | Out-String).Trim()
}

Import-Module WebAdministration -ErrorAction SilentlyContinue
if (Get-Command Get-WebAppPoolState -ErrorAction SilentlyContinue) {
    "`n=== 2. Exchange application pools ==="
    $pools = @(Get-ChildItem IIS:\AppPools | Where-Object { $_.Name -like 'MSExchange*' })
    $pools | Format-Table Name, State -AutoSize | Out-String -Width 200
    $stopped = @($pools | Where-Object { $_.State -ne 'Started' })
    if ($stopped.Count) { $problems += "appPoolsNotStarted=$($stopped.Name -join ',')" }
    if ($pools.Count -eq 0) { $problems += 'no-exchange-app-pools-found' }

    "=== bindings ==="
    Get-Website | ForEach-Object {
        $s = $_.Name
        $_.bindings.Collection | ForEach-Object { '{0,-28} {1,-6} {2}' -f $s, $_.protocol, $_.bindingInformation }
    }

    "`n=== 3. sslFlags ==="
    foreach ($p in @('Default Web Site', 'Default Web Site/owa', 'Default Web Site/ecp')) {
        $v = (Get-WebConfigurationProperty -Filter 'system.webServer/security/access' -Name sslFlags -PSPath "IIS:\Sites\$p" -ErrorAction SilentlyContinue).Value
        '{0,-28} sslFlags = {1}' -f $p, $v
    }
} else {
    "WebAdministration module not available: IIS sections skipped"
    $problems += 'no-webadministration'
}

"`n=== 4. Exchange certificates ==="
Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue
if (Get-Command Get-ExchangeCertificate -ErrorAction SilentlyContinue) {
    $certs = @(Get-ExchangeCertificate)
    $certs | Format-Table Thumbprint, Services, NotAfter, Subject -AutoSize | Out-String -Width 250
    $iisExpired = @($certs | Where-Object { "$($_.Services)" -match 'IIS' -and $_.NotAfter -lt (Get-Date) })
    if ($iisExpired.Count) { $problems += "iisCertExpired=$($iisExpired.Thumbprint -join ',')" }
} else { "Exchange snap-in not loaded: certificate section skipped" }

"`n=== 5. Real client traffic since $($Since.ToString('yyyy-MM-dd HH:mm')) UTC (W3SVC$IisSiteId) ==="
$log = Get-ChildItem "C:\inetpub\logs\LogFiles\W3SVC$IisSiteId\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) {
    "NO W3SVC$IisSiteId LOG FOUND"
} else {
    "log: $($log.FullName)  lastWrite=$($log.LastWriteTime)"
    $sinceText = $Since.ToString('yyyy-MM-dd HH:mm:ss')
    $rows = @(Get-Content $log.FullName -Tail 20000 | Where-Object { $_ -notmatch '^#' } | ForEach-Object {
        $f = $_ -split ' '
        if ($f.Count -gt 11) { [pscustomobject]@{ TS = "$($f[0]) $($f[1])"; Path = $f[4]; User = $f[7]; Status = $f[11] } }
    } | Where-Object { $_.TS -ge $sinceText -and $_.User -ne '-' -and $_.Path -match '^/(owa|mapi|EWS|ecp|Microsoft-Server-ActiveSync|autodiscover)' })
    "authenticated client requests: $($rows.Count)"
    $rows | Group-Object { ($_.Path -replace '^(/[^/]+).*', '$1') + ' ' + $_.Status } | Sort-Object Count -Descending |
        Select-Object -First 25 | Format-Table Count, Name -AutoSize | Out-String -Width 200
    $err5xx = @($rows | Where-Object { $_.Status -like '5*' })
    if ($rows.Count -and $err5xx.Count -gt [math]::Max(5, $rows.Count * 0.05)) { $problems += "client5xx=$($err5xx.Count)of$($rows.Count)" }
    if (-not $rows.Count) { "WARNING: no authenticated client requests in the window (quiet hour, or clients cannot connect)" }
}

"`n=== 6. HTTPERR, last 20 lines ==="
$he = Get-ChildItem "$env:SystemRoot\System32\LogFiles\HTTPERR\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($he) { "$($he.FullName) lastWrite=$($he.LastWriteTime)"; Get-Content $he.FullName -Tail 20 } else { 'no HTTPERR log' }

if ($problems.Count) {
    "RESULT=ATTENTION;host=$env:COMPUTERNAME;$(($problems -join ';') -replace '[\r\n]', ' ')"
    exit 1
}
"RESULT=HEALTHY;host=$env:COMPUTERNAME"
exit 0
