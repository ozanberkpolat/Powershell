#Requires -Version 5.1
<#
.SYNOPSIS
    Zabbix JSON-RPC helper library: connect with a Bearer API token, call methods, fail loudly on empty results.

.DESCRIPTION
    Dot-source this file from a script or session; it defines functions and runs nothing by itself:

        . .\Invoke-ZabbixApi.ps1
        Connect-ZabbixApi -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token
        Invoke-ZabbixApi -Method host.get -Params @{ output = @('hostid','host'); limit = 5 }

    Functions
      Connect-ZabbixApi        Reads URL and token, bypasses the system proxy, tests TCP reachability, checks the
                               token with one authenticated call, stores the session for the other functions.
      Invoke-ZabbixApi         POST one JSON-RPC call with `Authorization: Bearer <token>`. Returns an ARRAY.
                               A `*.get` call that returns no rows throws unless -AllowEmpty.
      Test-ZabbixReachable     Plain TCP connect, to tell a network problem from a token problem.
      Resolve-ZabbixHostGroup  Group name to groupid; on a miss the error lists the names that exist.
      Save-ZabbixEvidence      Writes an object as timestamped JSON into an evidence folder.

    Lessons kept from production use
      * An empty result is a finding, not an answer: a wrong group name, a missing permission or a renamed item all
        look like "no rows". Every .get throws on zero rows unless the caller says an empty set is expected.
      * Results are returned with a leading comma so a one-row result stays an array. Without it PowerShell unrolls
        the single object and `.Count` reads the property count instead of the row count.
      * `host.get` etc. return numbers as strings; compare as strings or cast.
      * Because of that leading comma, ASSIGN the result (`$rows = Invoke-ZabbixApi ...`) or wrap the call in its own
        parentheses (`@((Invoke-ZabbixApi ...))`). `@(Invoke-ZabbixApi ...)` nests the array: `.Count` is then 1 for zero
        rows and for fifty, and piping it hands the whole row set to the next command as one object.
      * A system proxy cannot reach a private address that exists only on a VPN, and the failure looks exactly like
        "VPN down". The session therefore goes direct (process-wide DefaultWebProxy = $null) unless -UseSystemProxy.
      * A connection that dropped mid-run is reported with the method and request number, so a long collection can
        be re-run knowing how far it got.
      * `apiinfo.version` must be called WITHOUT credentials; sending the Bearer header makes Zabbix reject it.

.NOTES
    Zabbix 6.4 or newer for Bearer tokens (API token created under Users > API tokens, role with read access to the
    objects you query; the write scripts need write access and are marked as such). The token is kept as a
    SecureString in the session. Token file: one line with the token, or `ZABBIX_TOKEN=<token>`; lines starting with
    # are ignored. Protect the file (NTFS permissions); never commit it.
    Windows PowerShell 5.1 and pwsh 7 both work.
#>

Set-StrictMode -Version Latest

$script:ZbxSession = $null
$script:ZbxReqId = 0

function Test-ZabbixReachable {
    <# .SYNOPSIS Plain TCP connect to the Zabbix web front end, 5 second timeout. #>
    param([Parameter(Mandatory)][string]$UriString)
    $u = [uri]$UriString
    $port = if ($u.Port -gt 0) { $u.Port } else { 80 }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($u.Host, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { return $false }
        $client.EndConnect($ar)
        return $client.Connected
    } catch { return $false } finally { $client.Close() }
}

function ConvertTo-PlainText([securestring]$Secure) {
    (New-Object System.Management.Automation.PSCredential 'x', $Secure).GetNetworkCredential().Password
}

function Connect-ZabbixApi {
    <#
    .SYNOPSIS  Opens the session used by Invoke-ZabbixApi.
    .PARAMETER Url        Zabbix front end base URL or the full .../api_jsonrpc.php URL. Default: env ZABBIX_URL.
    .PARAMETER TokenFile  Path of a file holding the API token. Default: env ZABBIX_TOKEN_FILE.
    .PARAMETER Token      API token as SecureString (alternative to -TokenFile).
    .PARAMETER UseSystemProxy  Do not bypass the system proxy.
    .PARAMETER SkipReachabilityTest  Skip the TCP pre-check (for URLs behind a gateway that drops bare TCP probes).
    #>
    [CmdletBinding()]
    param(
        [string]$Url,
        [string]$TokenFile,
        [securestring]$Token,
        [switch]$UseSystemProxy,
        [switch]$SkipReachabilityTest
    )
    if (-not $Url) { $Url = $env:ZABBIX_URL }
    if (-not $Url) { throw 'No Zabbix URL. Pass -Url or set ZABBIX_URL.' }
    if (-not $Token) {
        if (-not $TokenFile) { $TokenFile = $env:ZABBIX_TOKEN_FILE }
        if (-not $TokenFile) { throw 'No token. Pass -TokenFile (or -Token as SecureString) or set ZABBIX_TOKEN_FILE.' }
        if (-not (Test-Path $TokenFile -PathType Leaf)) { throw "Token file not found: $TokenFile" }
        $line = @(Get-Content $TokenFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })[0]
        if (-not $line) { throw "Token file $TokenFile is empty." }
        $line = ($line -replace '^ZABBIX_TOKEN\s*=\s*', '').Trim('"', "'")
        if ($line.Length -lt 20) { throw "Token file $TokenFile does not look like an API token (too short)." }
        $Token = ConvertTo-SecureString $line -AsPlainText -Force
        Remove-Variable line -WhatIf:$false
    }
    $rpc = $Url.TrimEnd('/')
    if ($rpc -notmatch 'api_jsonrpc\.php$') { $rpc += '/api_jsonrpc.php' }
    $base = $rpc -replace '/api_jsonrpc\.php$', ''

    if (-not $UseSystemProxy) {
        # Process-wide on purpose: Invoke-RestMethod uses it. An internal address is never reachable through a corporate proxy.
        try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch { Write-Warning "Could not clear the default proxy: $($_.Exception.Message)" }
    }
    if (-not $SkipReachabilityTest -and -not (Test-ZabbixReachable $base)) {
        $u = [uri]$base
        $port = if ($u.Port -gt 0) { $u.Port } else { 80 }
        # Write-Host first, then a one-line throw: PowerShell wraps a multi-line throw message into its error gutter.
        Write-Host "  Cannot reach Zabbix at $($u.Host):$port. Nothing was fetched." -ForegroundColor Red
        Write-Host '  This is a network problem, not a Zabbix or token problem. In order of likelihood:'
        Write-Host '   1. The VPN is not connected (the address may only exist on the customer network).'
        Write-Host "   2. The VPN is up but does not route this subnet: Test-NetConnection $($u.Host) -Port $port"
        Write-Host '   3. A proxy is intercepting it: re-run with -UseSystemProxy if yours is mandatory.'
        throw "Cannot reach Zabbix at $($u.Host):$port - see the checks above."
    }
    $script:ZbxSession = [pscustomobject]@{ Rpc = $rpc; Base = $base; Token = $Token }
    $script:ZbxReqId = 0

    # Prove the token before any real work: apiinfo.version is anonymous, so use one cheap authenticated read.
    $ver = Invoke-ZabbixApi -Method 'apiinfo.version' -Params @{} -NoAuth
    try { [void](Invoke-ZabbixApi -Method 'hostgroup.get' -Params @{ output = @('groupid'); limit = 1 }) }
    catch { $script:ZbxSession = $null; throw "Zabbix $($ver[0]) answered but the token was rejected or has no read access: $($_.Exception.Message)" }
    Write-Host "Zabbix $($ver[0]) at $base, token accepted."
}

function Invoke-ZabbixApi {
    <#
    .SYNOPSIS  One JSON-RPC call. Returns an array of rows (or the scalar result wrapped in an array).
    .PARAMETER Method      For example host.get.
    .PARAMETER Params      Hashtable of parameters, or an array of objects for create/update methods (item.create takes an array).
    .PARAMETER AllowEmpty  A *.get returning zero rows is normally an error; pass this when empty is a valid answer.
    .PARAMETER NoAuth      Do not send the Bearer header (apiinfo.version).
    .PARAMETER TimeoutSec  Request timeout, default 300 (trend.get on a big fleet is slow).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [object]$Params = @{},
        [switch]$AllowEmpty,
        [switch]$NoAuth,
        [int]$TimeoutSec = 300
    )
    if (-not $script:ZbxSession) { throw 'Not connected. Run Connect-ZabbixApi first.' }
    $script:ZbxReqId++
    $body = @{ jsonrpc = '2.0'; method = $Method; params = $Params; id = $script:ZbxReqId } | ConvertTo-Json -Depth 20 -Compress
    $headers = @{}
    if (-not $NoAuth) { $headers['Authorization'] = 'Bearer ' + (ConvertTo-PlainText $script:ZbxSession.Token) }
    try {
        $r = Invoke-RestMethod -Uri $script:ZbxSession.Rpc -Method Post -TimeoutSec $TimeoutSec `
            -ContentType 'application/json-rpc' -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
    } catch {
        # The connection was fine at startup, so this is usually a drop mid-run. Say which call and how far it got.
        throw ("Request '$Method' (#$script:ZbxReqId) to $($script:ZbxSession.Base) failed: $($_.Exception.Message) " +
               '- if the VPN dropped, reconnect and re-run.')
    }
    if ($r.PSObject.Properties.Name -contains 'error' -and $r.error) {
        throw "Zabbix $Method failed: $($r.error.message) $($r.error.data)"
    }
    $result = $r.result
    if ($Method -like '*.get' -and -not $AllowEmpty -and ($null -eq $result -or @($result).Count -eq 0)) {
        throw "EMPTY RESULT: $Method returned no rows for params $(if ($Params -is [hashtable]) { $Params.Keys -join ', ' } else { '(array)' }). An empty read is a fault until proven otherwise (wrong name, missing permission, renamed item)."
    }
    # Leading comma: a single-row result must stay an array. A null result becomes an empty array, not @($null).
    if ($null -eq $result) { return , @() }
    return , @($result)
}

function Resolve-ZabbixHostGroup {
    <# .SYNOPSIS Group name to groupid. Throws with the list of existing names when it is not found. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $groups = Invoke-ZabbixApi -Method hostgroup.get -Params @{ output = @('groupid', 'name'); sortfield = 'name' }
    $hit = @($groups | Where-Object { $_.name -eq $Name })
    if ($hit.Count -ne 1) {
        throw "Host group '$Name' not found (matches: $($hit.Count)). Available: $((($groups | ForEach-Object { $_.name }) | Sort-Object) -join ', ')"
    }
    $hit[0].groupid
}

function Save-ZabbixEvidence {
    <# .SYNOPSIS Writes an object as JSON to <Dir>\<yyyyMMdd-HHmmss>-<Name>.json and returns the path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Object, [string]$Dir = (Join-Path (Get-Location) 'evidence'))
    # -WhatIf:$false: evidence is a local read-only record and must be written in a -WhatIf run too.
    New-Item -ItemType Directory -Force $Dir -WhatIf:$false | Out-Null
    $path = Join-Path $Dir ('{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Name)
    $Object | ConvertTo-Json -Depth 20 | Out-File -FilePath $path -Encoding utf8 -WhatIf:$false
    $path
}
