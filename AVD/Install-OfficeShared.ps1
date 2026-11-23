<#
.SYNOPSIS
    Check prerequisites for, or install, Microsoft 365 Apps with shared computer activation on an AVD session
    host or RDS server, using the Office Deployment Tool.

.DESCRIPTION
    Runs INSIDE the VM (Windows PowerShell 5.1, as administrator or SYSTEM through Run Command).

    -Mode Check (default, read-only)
        WinHTTP proxy, DNS and TCP 443 to the Office CDN and sign-in endpoints, the TLS certificate issuer
        of the CDN (a corporate issuer means TLS inspection), setup.exe presence and signature, existing
        Office installs (MSI and Click-to-Run), signed-in sessions, free disk space.
    -Mode Install
        Writes configuration.xml (from the parameters, or uses -ConfigPath), stops when the CDN is not
        reachable (exit 4), downloads setup.exe when missing, refuses to run it unless the Authenticode
        signature is Valid and the signer is Microsoft Corporation (exit 3, file deleted), runs
        setup.exe /configure, then verifies ClickToRun\Configuration: SharedComputerLicensing = 1 and the
        product present. The tail of the newest ODT log is printed.

    Ends with RESULT=<code>;... and an exit code (0 ok, 1 failed, 2 no configuration, 3 bad signature,
    4 CDN unreachable, 5 download failed).

.PARAMETER Mode
    Check or Install.
.PARAMETER WorkDir
    ODT folder. Default C:\ODT.
.PARAMETER ConfigPath
    Use this configuration.xml instead of generating one (for example AVD/office-shared-computer.xml copied over).
.PARAMETER Language
    Languages for the generated configuration. Default en-us, MatchOS.
.PARAMETER ExcludeApp
    Apps left out. Default Groove, Lync, OneDrive, Teams, Bing.
.PARAMETER Channel
    Update channel. Default MonthlyEnterprise.
.PARAMETER EnableUpdates
    'true' for a long-lived host that is not reimaged. Default 'false' (pooled hosts: update the image).
    A string so Run Command can pass it.
.PARAMETER ForceAppShutdown
    'true' closes open Office apps during setup (image builds only). Default 'false'.
.PARAMETER SetupTimeoutMinutes
    Bounded wait for setup.exe. Default 60.

.EXAMPLE
    ./Azure/Compute/Invoke-VmRunCommand.ps1 -VmName vm-avd-0 -ResourceGroup rg-avd -ScriptPath ./AVD/Install-OfficeShared.ps1

.EXAMPLE
    ./Azure/Compute/Invoke-VmRunCommand.ps1 -VmName vm-rds-01 -ResourceGroup rg-rds -ScriptPath ./AVD/Install-OfficeShared.ps1 `
        -Parameter @{ Mode = 'Install'; EnableUpdates = 'true' } -Method Managed -TimeoutSeconds 5400

.NOTES
    Role: local administrator. Through Run Command: Virtual Machine Contributor (PIM). Installing software
    is a change: drain the host (no user sessions) first.
    Traps kept from real use:
      - Windows multi-session supports only Microsoft 365 Apps for enterprise / for business (Premium);
        Office LTSC volume editions are not supported there. Existing MSI Office must go (RemoveMSI).
      - Shared computer activation needs a Microsoft 365 Apps licence per user; it does not activate with a
        KMS or MAK key.
      - Outbound TLS inspection breaks the CDN download under SYSTEM even when TCP 443 works. Check mode
        prints the certificate issuer of the CDN: a corporate CA there means inspection; exclude the Office
        CDN from inspection or install from a local source (Push-InstallerViaRunCommand.ps1 for setup.exe
        plus a pre-downloaded source path).
      - setup.exe is fetched from officecdn.microsoft.com/pr/wsus/setup.exe when missing. That URL is
        widely used but not a documented download; the signature check is what makes it safe. The
        documented download is the Office Deployment Tool package from the Microsoft Download Center.
      - The setup exit code alone is not success: verify ClickToRun\Configuration afterwards.
      - Run Command output is capped near 4 KB; the full ODT log stays under <WorkDir>\Logs.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Install')][string]$Mode = 'Check',
    [string]$WorkDir = 'C:\ODT',
    [string]$ConfigPath,
    [string[]]$Language = @('en-us', 'MatchOS'),
    [string[]]$ExcludeApp = @('Groove', 'Lync', 'OneDrive', 'Teams', 'Bing'),
    [ValidateSet('MonthlyEnterprise', 'Current', 'SemiAnnual', 'SemiAnnualPreview', 'CurrentPreview')][string]$Channel = 'MonthlyEnterprise',
    [ValidateSet('true', 'false')][string]$EnableUpdates = 'false',
    [ValidateSet('true', 'false')][string]$ForceAppShutdown = 'false',
    [int]$SetupTimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
$setup = Join-Path $WorkDir 'setup.exe'
$logDir = Join-Path $WorkDir 'Logs'
$cdn = 'officecdn.microsoft.com'
$c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

function Result([string]$code, [string]$detail, [int]$exitCode) {
    Write-Output ("RESULT=$code;host=$env:COMPUTERNAME;mode=$Mode;" + ($detail -replace '[\r\n]', ' '))
    exit $exitCode
}
function Test-Signature([string]$path) {
    # Returns ONE object; printing inside a function that is used in an if() would turn the result into an
    # array, and a non-empty array is always true.
    $sig = Get-AuthenticodeSignature -FilePath $path
    $subj = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
    [pscustomobject]@{
        Ok   = ($sig.Status -eq 'Valid' -and $subj -like '*O=Microsoft Corporation*')
        Info = ("setup.exe version {0}, signature {1}, signer {2}" -f (Get-Item $path).VersionInfo.FileVersion, $sig.Status, $subj)
    }
}
function Invoke-Native([scriptblock]$Command) {
    # Windows PowerShell 5.1 turns a native stderr line into a terminating error under 'Stop'.
    $ErrorActionPreference = 'Continue'
    (& $Command 2>&1 | ForEach-Object { "$_" }) -join "`n"
}
function Get-Office {
    $u = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -match 'Microsoft Office|Microsoft 365' })
    $u | Select-Object DisplayName, DisplayVersion, @{ n = 'Msi'; e = { $_.PSChildName -match '^\{' } } | Format-Table -AutoSize | Out-String -Width 200
}

try {
    "=== proxy ==="
    (Invoke-Native { netsh.exe winhttp show proxy }).Trim()

    "=== DNS and TCP 443 ==="
    $cdnOk = $false
    foreach ($h in @($cdn, 'officeclient.microsoft.com', 'login.microsoftonline.com')) {
        try { $ips = @(Resolve-DnsName $h -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 2 -ExpandProperty IPAddress) -join ', ' } catch { $ips = "DNS error: $($_.Exception.Message)" }
        $t = Test-NetConnection $h -Port 443 -WarningAction SilentlyContinue
        "{0,-30} {1,-40} tcp443={2}" -f $h, $ips, $t.TcpTestSucceeded
        if ($h -eq $cdn) { $cdnOk = [bool]$t.TcpTestSucceeded }
    }
    if ($cdnOk) {
        "=== TLS issuer of the CDN (a corporate CA here means TLS inspection) ==="
        try {
            $tcp = New-Object Net.Sockets.TcpClient($cdn, 443)
            $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
            $ssl.AuthenticateAsClient($cdn)
            $cert = [Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
            "issuer: $($cert.Issuer)"
            $ssl.Dispose(); $tcp.Close()
        } catch { "TLS handshake failed: $($_.Exception.Message)" }
    }

    if ($Mode -eq 'Check') {
        "=== setup.exe ==="
        if (Test-Path $setup) { (Test-Signature $setup).Info } else { "not present in $WorkDir (Install downloads it)" }
        "=== installed Office ==="
        Get-Office
        if (Test-Path $c2rKey) { Get-ItemProperty $c2rKey | Select-Object VersionToReport, ProductReleaseIds, SharedComputerLicensing, UpdateChannel, CDNBaseUrl | Format-List | Out-String }
        "=== sessions ==="
        (Invoke-Native { quser.exe }).Trim()
        "=== free space ==="
        Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{ n = 'FreeGB'; e = { [math]::Round($_.Free / 1GB, 1) } } | Format-Table -AutoSize | Out-String
        Result $(if ($cdnOk) { 'CHECKED' } else { 'CDN-UNREACHABLE' }) "cdn443=$cdnOk" $(if ($cdnOk) { 0 } else { 4 })
    }

    # ---------- install ----------
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $xmlPath = Join-Path $WorkDir 'configuration.xml'
    if ($ConfigPath) {
        if (-not (Test-Path $ConfigPath)) { Result 'NO-CONFIG' "path=$ConfigPath" 2 }
        [void][xml](Get-Content -Raw $ConfigPath)   # fail early on a broken file
        $xmlPath = $ConfigPath
    } else {
        $langs = ($Language | ForEach-Object { "      <Language ID=`"$_`" />" }) -join "`r`n"
        $excl = ($ExcludeApp | ForEach-Object { "      <ExcludeApp ID=`"$_`" />" }) -join "`r`n"
        $xml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$Channel">
    <Product ID="O365ProPlusRetail">
$langs
$excl
    </Product>
  </Add>
  <RemoveMSI />
  <Updates Enabled="$($EnableUpdates.ToUpper())" Channel="$Channel" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="$logDir" />
  <Property Name="FORCEAPPSHUTDOWN" Value="$($ForceAppShutdown.ToUpper())" />
  <Property Name="SharedComputerLicensing" Value="1" />
</Configuration>
"@
        [void][xml]$xml
        Set-Content -Path $xmlPath -Value $xml -Encoding UTF8
    }
    "=== configuration ($xmlPath) ==="
    Get-Content $xmlPath

    if (-not $cdnOk) { Result 'CDN-UNREACHABLE' 'install not started' 4 }
    if (-not (Test-Path $setup)) {
        "=== downloading setup.exe ==="
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri "https://$cdn/pr/wsus/setup.exe" -OutFile $setup -UseBasicParsing }
        catch { Result 'DOWNLOAD-FAILED' "error=$($_.Exception.Message)" 5 }
    }
    $sigCheck = Test-Signature $setup
    $sigCheck.Info
    if (-not $sigCheck.Ok) {
        Remove-Item $setup -Force
        Result 'BAD-SIGNATURE' 'setup.exe deleted, install not started' 3
    }

    "=== setup.exe /configure ==="
    $p = Start-Process -FilePath $setup -ArgumentList "/configure `"$xmlPath`"" -PassThru
    if (-not $p.WaitForExit($SetupTimeoutMinutes * 60000)) { Result 'TIMEOUT' "setup still running after $SetupTimeoutMinutes min (pid $($p.Id)); not killed" 1 }
    "setup exit code $($p.ExitCode)"

    $log = Get-ChildItem $logDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($log) { "=== $($log.Name) (tail) ==="; Get-Content $log.FullName -Tail 15 }

    $c2r = Get-ItemProperty $c2rKey -ErrorAction SilentlyContinue
    if (-not $c2r) { Result 'FAILED' "exit=$($p.ExitCode);no ClickToRun configuration" 1 }
    $c2r | Select-Object VersionToReport, ProductReleaseIds, SharedComputerLicensing, UpdateChannel | Format-List | Out-String
    $ok = ("$($c2r.SharedComputerLicensing)" -eq '1') -and ("$($c2r.ProductReleaseIds)" -match 'O365ProPlusRetail')
    if (-not $ok) { Result 'FAILED' "exit=$($p.ExitCode);scl=$($c2r.SharedComputerLicensing);products=$($c2r.ProductReleaseIds)" 1 }
    Result 'INSTALLED' "exit=$($p.ExitCode);version=$($c2r.VersionToReport)" 0
}
catch { Result 'FAILED' "error=$($_.Exception.Message)" 1 }
