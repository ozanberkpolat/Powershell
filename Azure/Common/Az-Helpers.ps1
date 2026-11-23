<#
.SYNOPSIS
    Shared Azure helpers: Resource Graph with paging, ARM REST with retry, Log Analytics query.

.DESCRIPTION
    Dot-source this file after Connect-AzAccount:

        . ./Azure/Common/Az-Helpers.ps1
        $vms = Search-Graph -Query "resources | where type =~ 'microsoft.compute/virtualmachines' | project name, id"

    Everything runs off the current Az context (Az.Accounts only). No other module is needed,
    no manual token handling, no BYOS or proxy.

    Functions
      Get-EnabledSubscription   Enabled subscriptions the signed-in user can read.
      Search-Graph              Resource Graph KQL across subscriptions, follows $skipToken.
      Invoke-ArmRequest         One ARM REST call with retry on 429/5xx and Retry-After. Returns parsed JSON.
      Invoke-Arm                ARM REST call that also follows nextLink and returns the .value items.
      Invoke-LaKql              Log Analytics query by workspace customerId (REST, api.loganalytics.io token).

.NOTES
    Requires: Az.Accounts. Role: Reader is enough for every read helper here.
    Known traps kept from real use:
      - Resource Graph pages on $skipToken. A query that is not ordered can still page, but a
        query with `top` or `limit` stops at that limit by design.
      - Results are emitted as plain pipeline output (no leading-comma wrapping). Wrap a call in @( ) when you need an array
        even for 0 or 1 rows: $rows = @(Search-Graph -Query $q). Do not pipe a possibly single-row result straight into
        .Count; assign it with @( ) first.
      - A 204 No Content is a documented empty result for some ARM APIs (for example
        reservation recommendations). ConvertFrom-Json throws on an empty string, so an empty
        body returns $null instead of failing.
      - Several services send more than one retry header (Cost Management sends one per
        throttle window, for example x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after).
        The largest value is the one that gates you, so the helper waits for the maximum.
      - The Log Analytics token audience is https://api.loganalytics.io, NOT ARM. An ARM token
        against the Log Analytics endpoint returns 403 InvalidAuthenticationTokenAudience.
      - The Log Analytics API takes an optional timespan. Always pass one: a short server
        default clips a query whose own `where` reaches further back and returns a confident
        empty result.
#>

$script:ArmHost = 'https://management.azure.com'

function Get-EnabledSubscription {
    <# Enabled subscriptions readable by the current identity. Throws when there are none. #>
    [CmdletBinding()] param()
    $subs = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' })
    if (-not $subs.Count) { throw 'No enabled subscription is readable. Run Connect-AzAccount (and activate PIM if needed).' }
    $subs
}

function Get-RetryAfterSeconds {
    <# Largest value of any header whose name contains "retry-after". $null when none. #>
    param($Response)
    $vals = @()
    foreach ($h in $Response.Headers) {
        if ("$($h.Key)" -notmatch '(?i)retry-after') { continue }
        foreach ($v in @($h.Value)) { if ("$v" -match '^\d+$') { $vals += [int]$v } }
    }
    if ($vals.Count) { ($vals | Measure-Object -Maximum).Maximum } else { $null }
}

function Invoke-ArmRequest {
    <#
    .SYNOPSIS
        One ARM REST call. Retries 429 and 5xx honouring Retry-After. Returns parsed JSON or $null.
    .PARAMETER Path
        Relative ARM path including any query string, e.g. /subscriptions/<id>/resourceGroups?api-version=2022-12-01
        A full https://management.azure.com/... URL (nextLink) is also accepted.
    .PARAMETER Body
        Hashtable/object (converted with ConvertTo-Json -Depth 20) or a ready JSON string.
    .PARAMETER MinWaitSeconds
        Floor for a retry wait. A Retry-After of 0 is a wasted attempt, so use a floor for throttled APIs.
    .PARAMETER MaxWaitSeconds
        Ceiling for one wait.
    .PARAMETER IgnoreNotFound
        Return $null on 404 instead of throwing.
    .PARAMETER ReadOnly
        The call is a read even though it is not a GET (for example a Resource Graph POST): run it under -WhatIf too.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [int]$MaxRetries = 5,
        [int]$MinWaitSeconds = 5,
        [int]$MaxWaitSeconds = 180,
        [switch]$IgnoreNotFound,
        [switch]$ReadOnly
    )
    $rel = $Path -replace '^https://management\.azure\.com', ''
    $payload = if ($null -eq $Body) { $null } elseif ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    for ($attempt = 1; $attempt -le $MaxRetries + 1; $attempt++) {
        $p = @{ Method = $Method; Path = $rel; ErrorAction = 'Stop' }
        # Invoke-AzRestMethod supports -WhatIf: under a script's -WhatIf it would skip reads too and return
        # nothing, so a dry run plans from an empty list. Reads always run; writes stay gated by the caller.
        if ($Method -eq 'GET' -or $ReadOnly) { $p.WhatIf = $false }
        if ($payload) { $p.Payload = $payload }
        $resp = Invoke-AzRestMethod @p
        $code = [int]$resp.StatusCode
        if (($code -eq 429 -or $code -ge 500) -and $attempt -le $MaxRetries) {
            $ra = Get-RetryAfterSeconds $resp
            $wait = if ($null -ne $ra) { $ra } else { [Math]::Min([Math]::Pow(2, $attempt) * 2, $MaxWaitSeconds) }
            $wait = [Math]::Min([Math]::Max($wait, $MinWaitSeconds), $MaxWaitSeconds)
            Write-Warning "ARM $code on $Method $rel, waiting ${wait}s (attempt $attempt/$MaxRetries)"
            Start-Sleep -Seconds $wait
            continue
        }
        if ($code -eq 404 -and $IgnoreNotFound) { return $null }
        if ($code -ge 400) { throw "ARM $code on $Method ${rel}: $($resp.Content)" }
        if (-not $resp.Content) { return $null }   # 202/204 or documented empty result
        return ($resp.Content | ConvertFrom-Json)
    }
    throw "ARM request still throttled after $MaxRetries retries: $Method $rel"
}

function Invoke-Arm {
    <#
    .SYNOPSIS
        ARM REST call that follows nextLink and returns the .value items (or the single object).
    .EXAMPLE
        Invoke-Arm -Path "/subscriptions/$sub/providers/Microsoft.Compute/virtualMachines" -ApiVersion 2024-07-01
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [string]$ApiVersion,
        $Body,
        [int]$MaxRetries = 5,
        [int]$MinWaitSeconds = 5,
        [switch]$IgnoreNotFound
    )
    $uri = $Path
    if ($ApiVersion) { $uri = $Path + $(if ($Path.Contains('?')) { '&' } else { '?' }) + "api-version=$ApiVersion" }
    $all = New-Object System.Collections.ArrayList
    $guard = 0
    while ($uri) {
        $c = Invoke-ArmRequest -Method $Method -Path $uri -Body $Body -MaxRetries $MaxRetries -MinWaitSeconds $MinWaitSeconds -IgnoreNotFound:$IgnoreNotFound
        if ($null -eq $c) { break }
        if ($c.PSObject.Properties.Name -contains 'value') { foreach ($i in @($c.value)) { [void]$all.Add($i) } } else { [void]$all.Add($c) }
        $uri = $c.nextLink
        if (++$guard -gt 500) { throw "Paging did not end after $guard pages: $Path" }
    }
    $all.ToArray()
}

function Search-Graph {
    <#
    .SYNOPSIS
        Resource Graph query across subscriptions (or a management group), following $skipToken.
    .DESCRIPTION
        Default scope is every enabled subscription the user can read, sent explicitly (a query
        sent with no scope only sees the current context). Uses REST, so Az.ResourceGraph is not needed.
        Returns objects (resultFormat objectArray). Returns an empty array for no rows; callers
        that expect data must check Count and fail loudly.
    .PARAMETER Query
        KQL for Resource Graph. Resource Graph KQL is a subset: no countif, no leftanti, strict alias rules.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$Subscription,
        [string]$ManagementGroup,
        [int]$PageSize = 1000
    )
    $scope = @{}
    if ($ManagementGroup) { $scope.managementGroups = @($ManagementGroup) }
    else {
        if (-not $Subscription) { $Subscription = (Get-EnabledSubscription).Id }
        $scope.subscriptions = @($Subscription)
    }
    $all = New-Object System.Collections.ArrayList
    $token = $null
    do {
        $opts = @{ '$top' = $PageSize; resultFormat = 'objectArray' }
        if ($token) { $opts['$skipToken'] = $token }
        $body = @{ query = $Query; options = $opts } + $scope
        $r = Invoke-ArmRequest -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Body $body -ReadOnly
        foreach ($row in @($r.data)) { [void]$all.Add($row) }
        $token = $r.'$skipToken'
    } while ($token)
    $all.ToArray()
}

function Invoke-LaKql {
    <#
    .SYNOPSIS
        Run a KQL query against a Log Analytics workspace through the REST API.
    .PARAMETER WorkspaceId
        The workspace customerId (a GUID), NOT the ARM resource ID.
        Find it with: (Get-AzOperationalInsightsWorkspace -ResourceGroupName rg -Name law).CustomerId
    .PARAMETER Timespan
        ISO 8601 duration or interval. Always set; default P30D.
    .OUTPUTS
        Array of PSCustomObject, one per row, property names = column names. Throws on an API error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Kql,
        [string]$Timespan = 'P30D'
    )
    $t = Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io' -ErrorAction Stop
    $tok = if ($t.Token -is [System.Security.SecureString]) { [System.Net.NetworkCredential]::new('', $t.Token).Password } else { $t.Token }
    $uri = "https://api.loganalytics.azure.com/v1/workspaces/$WorkspaceId/query"
    $headers = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
    $body = @{ query = $Kql; timespan = $Timespan } | ConvertTo-Json -Depth 5
    try {
        $r = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -ErrorAction Stop
    } catch {
        # The useful part is in the response body, not the exception message.
        $detail = ''
        try { $detail = $_.ErrorDetails.Message } catch { $detail = '' }
        throw "Log Analytics query failed: $_ $detail"
    }
    if (-not $r.tables -or -not $r.tables.Count) { throw 'Log Analytics returned no table.' }
    $tbl = $r.tables[0]
    $cols = @($tbl.columns.name)
    $out = foreach ($row in $tbl.rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
    $out
}
