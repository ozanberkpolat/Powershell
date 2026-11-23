<#
.SYNOPSIS
    Send an e-mail through Azure Communication Services (ACS) Email with the REST API and an HMAC-signed request.

.DESCRIPTION
    No modules. Builds the request, signs it with the ACS access key (HMAC-SHA256) and POSTs it to
    <endpoint>/emails:send. Each recipient gets a SEPARATE message (no shared To line, nobody sees the other
    addresses), so one bad address does not stop the rest.

    The access key never has a default. Supply it as:
      -ConnectionString (SecureString)   "endpoint=https://<name>.<geo>.communication.azure.com/;accesskey=<key>"
      or the environment variable ACS_CONNECTION_STRING (read when -ConnectionString is not given).
    Keep the real value in Key Vault or a protected variable; never in this file.

    Output: one object per recipient (Recipient, Status, OperationId, Error). The script exits 1 when any
    recipient failed.

.PARAMETER ConnectionString
    ACS connection string as SecureString. Omit to use $env:ACS_CONNECTION_STRING.
.PARAMETER From
    Verified sender address of the connected e-mail domain, for example DoNotReply@contoso.com.
.PARAMETER To
    One or more recipient addresses. Each gets its own message.
.PARAMETER Subject
    Message subject.
.PARAMETER HtmlBody
    HTML body. Use -PlainTextBody as well (or instead) for clients that do not render HTML.
.PARAMETER PlainTextBody
    Plain-text body.
.PARAMETER ApiVersion
    Email REST API version. Default 2023-03-31 (the GA version this was written against).

.EXAMPLE
    $cs = Read-Host -AsSecureString 'ACS connection string'
    ./Send-AcsEmail.ps1 -ConnectionString $cs -From DoNotReply@contoso.com -To user1@contoso.com,user2@contoso.com `
        -Subject 'Test' -HtmlBody '<p>Hello</p>'

.EXAMPLE
    # From Key Vault, no prompt
    $cs = (Get-AzKeyVaultSecret -VaultName kv-mail -Name acs-connection).SecretValue
    ./Send-AcsEmail.ps1 -ConnectionString $cs -From DoNotReply@contoso.com -To ops@contoso.com -Subject 'Report' -PlainTextBody 'See attachment link.'

.NOTES
    Requires: Windows PowerShell 5.1 or PowerShell 7. No modules. Role: none in Azure; the access key IS the
    permission, so treat it like a password and rotate it if it leaks (ACS resource > Keys > Regenerate).
    Traps kept from real use:
      - The signature covers the exact body bytes: x-ms-content-sha256 is the SHA-256 of the UTF-8 body, and
        the string to sign is "POST\n<path+query>\n<x-ms-date>;<host>;<content hash>". Recompute it for every
        message, and send the same UTF-8 BYTES you hashed. Passing a string body lets Windows PowerShell 5.1
        re-encode it, so a subject with non-ASCII characters fails with 401 while ASCII works.
      - x-ms-date must be RFC 1123 in UTC and formatted with the invariant culture; a localized day or month
        name breaks the signature.
      - The host in the signed string includes the port only when it is not the default port.
      - 202 Accepted means ACS queued the message, not that it was delivered. Delivery status is in the
        operation (Operation-Location header / OperationId) or in the ACS e-mail logs.
      - The sender must be a verified address of a domain connected to the ACS resource, or the call fails
        with a 400/403 that names the sender.
#>
[CmdletBinding()]
param(
    [securestring]$ConnectionString,
    [Parameter(Mandatory)][string]$From,
    [Parameter(Mandatory)][string[]]$To,
    [Parameter(Mandatory)][string]$Subject,
    [string]$HtmlBody,
    [string]$PlainTextBody,
    [string]$ApiVersion = '2023-03-31'
)

$ErrorActionPreference = 'Stop'
if (-not $HtmlBody -and -not $PlainTextBody) { throw 'Pass -HtmlBody and/or -PlainTextBody.' }

$cs = if ($ConnectionString) { [System.Net.NetworkCredential]::new('', $ConnectionString).Password } else { $env:ACS_CONNECTION_STRING }
if (-not $cs) { throw 'No connection string. Pass -ConnectionString (SecureString) or set $env:ACS_CONNECTION_STRING.' }
$endpoint  = ([regex]::Match($cs, '(?i)endpoint=([^;]+)').Groups[1].Value).TrimEnd('/')
$accessKey = [regex]::Match($cs, '(?i)accesskey=([^;]+)').Groups[1].Value
$cs = $null
if (-not $endpoint -or -not $accessKey) { throw 'Connection string must contain endpoint=...;accesskey=...' }
$keyBytes = [Convert]::FromBase64String($accessKey)
$accessKey = $null

$uri = [Uri]"$endpoint/emails:send?api-version=$ApiVersion"
$hostHeader = if ($uri.IsDefaultPort) { $uri.Host } else { "$($uri.Host):$($uri.Port)" }

function Send-OneEmail([string]$Recipient) {
    $content = @{ subject = $Subject }
    if ($HtmlBody) { $content.html = $HtmlBody }
    if ($PlainTextBody) { $content.plainText = $PlainTextBody }
    $json = @{
        senderAddress = $From
        content       = $content
        recipients    = @{ to = @(@{ address = $Recipient }) }
    } | ConvertTo-Json -Depth 10 -Compress
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($json)

    $date = [DateTime]::UtcNow.ToString('r', [Globalization.CultureInfo]::InvariantCulture)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $contentHash = [Convert]::ToBase64String($sha.ComputeHash($bodyBytes)) } finally { $sha.Dispose() }
    $stringToSign = "POST`n$($uri.PathAndQuery)`n$date;$hostHeader;$contentHash"
    $hmac = [Security.Cryptography.HMACSHA256]::new($keyBytes)
    try { $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign))) } finally { $hmac.Dispose() }

    $headers = @{
        'x-ms-date'           = $date
        'x-ms-content-sha256' = $contentHash
        'Authorization'       = "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=$signature"
    }
    # Send the hashed bytes, not the string (see NOTES).
    $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing
    $opId = $null
    try { $opId = ($r.Content | ConvertFrom-Json).id } catch { $opId = $null }
    [pscustomobject]@{ Recipient = $Recipient; Status = [int]$r.StatusCode; OperationId = $opId; Error = $null }
}

$results = foreach ($recipient in $To) {
    try {
        $res = Send-OneEmail -Recipient $recipient
        Write-Host "Accepted for delivery (HTTP $($res.Status)) to $recipient, operation $($res.OperationId)" -ForegroundColor Green
        $res
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail += " $($_.ErrorDetails.Message)" }
        Write-Error "Send failed for ${recipient}: $detail" -ErrorAction Continue
        [pscustomobject]@{ Recipient = $recipient; Status = 'Failed'; OperationId = $null; Error = $detail }
    }
}
$results
$failed = @($results | Where-Object { $_.Status -eq 'Failed' })
if ($failed.Count) { Write-Error "$($failed.Count) of $(@($results).Count) message(s) failed." -ErrorAction Continue; exit 1 }
