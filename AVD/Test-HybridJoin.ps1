#Requires -Version 7.0
<#
.SYNOPSIS
    Diagnose Microsoft Entra hybrid join on a Windows host (read-only), locally or through Run Command.

.DESCRIPTION
    Runs a read-only probe that answers "why is this machine not hybrid joined (or has no PRT)?":

      - domain membership (Win32_ComputerSystem) and the computer object in AD,
      - dsregcmd /status: DomainJoined, AzureAdJoined, DeviceAuthStatus, AzureAdPrt, TenantName, MdmUrl, Diagnostic Data (error phase and code),
      - the service connection point (SCP) for device registration in AD,
      - the Device Registration Admin event log (recent errors and warnings),
      - machine-wide proxy settings (winhttp), clock skew against the Entra endpoint,
      - reachability of the device registration and sign-in endpoints on 443, and whether TLS is intercepted
        (certificate issuer is not a Microsoft one: a web filter or SSL inspection is rewriting the connection).

    Each check prints CHECK|name|OK/WARN/FAIL|detail and a verdict list is shown at the end. Exit code 1 if any FAIL.

    Two modes:
      Local   (default): run on the host itself.
      Remote  (-VmName ...): sends the same probe with Run Command via Invoke-VmRunCommand.ps1 and parses the output.

.PARAMETER VmName
    Azure VM name to probe remotely (with -ResourceGroup, optionally -Subscription). Omit to run locally.
.PARAMETER ResourceGroup
    Resource group of the VM.
.PARAMETER Subscription
    Subscription of the VM.

.EXAMPLE
    ./Test-HybridJoin.ps1

.EXAMPLE
    ./Test-HybridJoin.ps1 -VmName vm-avd-01 -ResourceGroup rg-avd

.NOTES
    Remote mode needs Virtual Machine Contributor on the VM and an Az context (Az.Accounts). Local mode needs no module.
    Findings that came up in practice:
      - Hybrid join "Pending" with error 0x801c03f2 or empty Diagnostic Data often means the machine cannot reach
        enterpriseregistration.windows.net: a firewall web filter in a category such as "Information Technology" blocks it,
        or SSL inspection replaces the certificate. Exempt the device registration, Entra sign-in and Intune endpoints from
        web filtering and SSL inspection. The probe flags a non-Microsoft certificate issuer.
      - The computer object must sit in an OU that is in Entra Connect sync scope, and device registration must be enabled
        on the Connect server (SCP present). No SCP means the host never starts registration.
      - A VM built as a workgroup machine and domain-joined later registers with the Entra hybrid join task only after a
        reboot plus the scheduled task "\Microsoft\Windows\Workplace Join\Automatic-Device-Join" (run it with Start-ScheduledTask).
      - Machines whose computer object is in a protected/denied sync scope never complete the join: check Connect filtering.
#>
[CmdletBinding()]
param(
    [string]$VmName,
    [string]$ResourceGroup,
    [string]$Subscription
)

$ErrorActionPreference = 'Stop'

$probe = @'
$ErrorActionPreference = 'Continue'
function C($name, $state, $detail) { "CHECK|$name|$state|$detail" }

# --- domain membership
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain) { C 'DomainMembership' 'OK' "domain $($cs.Domain)" } else { C 'DomainMembership' 'FAIL' "workgroup $($cs.Domain): hybrid join needs an AD-joined machine" }

# --- dsregcmd
$ds = & dsregcmd /status 2>&1 | Out-String
function V($key) { if ($ds -match "(?m)^\s*$key\s*:\s*(.+?)\s*$") { $Matches[1] } else { '' } }
$dj = V 'DomainJoined'; $aj = V 'AzureAdJoined'; $das = V 'DeviceAuthStatus'; $prt = V 'AzureAdPrt'
C 'DomainJoined (dsregcmd)' $(if ($dj -eq 'YES') { 'OK' } else { 'FAIL' }) $dj
C 'AzureAdJoined' $(if ($aj -eq 'YES') { 'OK' } else { 'FAIL' }) "$aj (tenant: $(V 'TenantName'))"
C 'DeviceAuthStatus' $(if ($das -match 'SUCCESS') { 'OK' } elseif ($das) { 'WARN' } else { 'WARN' }) $das
C 'AzureAdPrt' $(if ($prt -eq 'YES') { 'OK' } else { 'WARN' }) "$prt (a PRT exists only for a signed-in user session)"
foreach ($k in 'Pre-check result', 'Registration Type', 'Error Phase', 'Client ErrorCode', 'Server ErrorCode', 'Server Message', 'Https Status', 'Request Id') {
    $v = V $k; if ($v) { C "dsreg: $k" 'INFO' $v }
}
$mdm = V 'MdmUrl'; if ($mdm) { C 'MdmUrl' 'INFO' $mdm }

# --- AD computer object and SCP
try {
    $me = ([adsisearcher]"(&(objectCategory=computer)(name=$env:COMPUTERNAME))").FindOne()
    if ($me) { C 'ADComputerObject' 'OK' $me.Path } else { C 'ADComputerObject' 'FAIL' 'not found in AD (or AD not reachable)' }
    $root = [adsi]'LDAP://RootDSE'
    $cfg = $root.configurationNamingContext
    # 62a0ff2e-97b9-4513-943f-0d221bd30080 is the fixed object name of the Entra Connect device registration SCP (well-known, not tenant specific).
    $scp = [adsi]"LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$cfg"
    if ($scp.keywords -and $scp.keywords.Count) { C 'SCP' 'OK' ($scp.keywords -join '; ') } else { C 'SCP' 'FAIL' 'no device registration service connection point in the forest' }
} catch { C 'ADLookup' 'WARN' "AD query failed: $($_.Exception.Message)" }

# --- device registration log
try {
    $ev = Get-WinEvent -LogName 'Microsoft-Windows-User Device Registration/Admin' -MaxEvents 30 -ErrorAction Stop | Where-Object { $_.Level -le 3 } | Select-Object -First 5
    if ($ev) { foreach ($e in $ev) { C 'DeviceRegistrationLog' 'WARN' ("{0:yyyy-MM-dd HH:mm} id {1}: {2}" -f $e.TimeCreated, $e.Id, (($e.Message -replace '\s+', ' ').Substring(0, [Math]::Min(180, ($e.Message -replace '\s+', ' ').Length)))) } }
    else { C 'DeviceRegistrationLog' 'OK' 'no recent errors or warnings' }
} catch { C 'DeviceRegistrationLog' 'WARN' "cannot read log: $($_.Exception.Message)" }

# --- proxy
$px = (& netsh winhttp show proxy 2>&1 | Out-String) -replace '\s+', ' '
C 'WinHttpProxy' $(if ($px -match 'Direct access') { 'OK' } else { 'WARN' }) $px.Trim()

# --- endpoints and TLS interception
$targets = 'enterpriseregistration.windows.net', 'device.login.microsoftonline.com', 'login.microsoftonline.com'
foreach ($h in $targets) {
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($h, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(8000)) { $tcp.Close(); C "443 $h" 'FAIL' 'connect timeout'; continue }
        $tcp.EndConnect($iar)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($h)
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $issuer = $cert.Issuer
        if ($issuer -match 'Microsoft|DigiCert|Baltimore') { C "443 $h" 'OK' "issuer $issuer" }
        else { C "443 $h" 'FAIL' "certificate issuer is not Microsoft ($issuer): SSL inspection or a web filter is intercepting this endpoint" }
        $ssl.Dispose(); $tcp.Close()
    } catch { C "443 $h" 'FAIL' "$($_.Exception.Message)" }
}

# --- clock
try {
    $r = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/discovery/instance?api-version=1.1&authorization_endpoint=https://login.microsoftonline.com/common/oauth2/authorize' -UseBasicParsing -TimeoutSec 15
    $srv = [datetime]::Parse($r.Headers['Date'], [cultureinfo]::InvariantCulture).ToUniversalTime()
    $skew = [Math]::Abs(((Get-Date).ToUniversalTime() - $srv).TotalMinutes)
    C 'ClockSkew' $(if ($skew -lt 5) { 'OK' } else { 'FAIL' }) ("{0:N1} minutes against Entra" -f $skew)
} catch { C 'ClockSkew' 'WARN' "could not read server time: $($_.Exception.Message)" }
'@

if ($VmName) {
    if (-not $ResourceGroup) { throw '-ResourceGroup is required with -VmName.' }
    $args = @{ VmName = $VmName; ResourceGroup = $ResourceGroup; Script = $probe; OsType = 'Windows'; PassThru = $true; EvidenceFolder = './hybrid-join-evidence' }
    if ($Subscription) { $args.Subscription = $Subscription }
    $r = & (Join-Path $PSScriptRoot '../Azure/Compute/Invoke-VmRunCommand.ps1') @args
    $stdout = Get-Content -Raw (Join-Path @($r)[0].Evidence 'stdout.txt')
    if (@($r)[0].State -ne 'Succeeded') { throw "Run Command did not succeed: $(@($r)[0].Error)" }
    $lines = $stdout -split "`r?`n"
} else {
    if (-not $IsWindows) { throw 'Local mode runs on Windows only. Use -VmName for a remote probe.' }
    $lines = & ([scriptblock]::Create($probe)) | ForEach-Object { "$_" }
}

$checks = foreach ($l in $lines) { if ($l -match '^CHECK\|([^|]*)\|([^|]*)\|(.*)$') { [pscustomobject]@{ Check = $Matches[1]; State = $Matches[2]; Detail = $Matches[3] } } }
if (-not $checks) { throw 'The probe returned no CHECK lines. Output was truncated or the probe failed.' }
$checks | Format-Table Check, State, Detail -AutoSize -Wrap | Out-String -Width 4096 | Write-Host
$fail = @($checks | Where-Object State -eq 'FAIL')
Write-Host ("{0} OK, {1} WARN, {2} FAIL" -f @($checks | Where-Object State -eq 'OK').Count, @($checks | Where-Object State -eq 'WARN').Count, $fail.Count)
if ($fail.Count) { Write-Host 'Likely causes, in order: endpoint blocked or TLS intercepted, no SCP / not in sync scope, clock skew, not domain joined.' -ForegroundColor Yellow; exit 1 }
