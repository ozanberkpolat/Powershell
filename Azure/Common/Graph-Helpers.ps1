<#
.SYNOPSIS
    Shared Microsoft Graph helper: Get-GraphAll follows @odata.nextLink.

.DESCRIPTION
    Dot-source after Connect-MgGraph:

        . ./Azure/Common/Graph-Helpers.ps1
        $users = Get-GraphAll -Uri 'https://graph.microsoft.com/v1.0/users?$select=id,displayName&$top=999'

.NOTES
    Requires: Microsoft.Graph.Authentication. Permissions depend on the endpoint called.
    Traps kept:
      - Directory objects with advanced filters ($count, $search, endswith, ne on some properties)
        need the header ConsistencyLevel: eventual, and $count=true on the query. Pass -Eventual.
      - Graph throttles with 429 and a Retry-After header. The helper waits and retries.
      - An empty result emits nothing, not an error. Wrap the call in @( ) and check Count when you expect data.
#>

function Get-GraphAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$Eventual,
        [int]$MaxRetries = 5
    )
    $headers = @{}
    if ($Eventual) { $headers['ConsistencyLevel'] = 'eventual' }
    $all = New-Object System.Collections.ArrayList
    $next = $Uri
    while ($next) {
        $page = $null
        for ($attempt = 1; $attempt -le $MaxRetries + 1; $attempt++) {
            try {
                $page = Invoke-MgGraphRequest -Method GET -Uri $next -Headers $headers -OutputType PSObject -ErrorAction Stop
                break
            } catch {
                $status = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
                if (($status -eq 429 -or $status -ge 500) -and $attempt -le $MaxRetries) {
                    $wait = 10
                    try { $ra = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds; if ($ra) { $wait = [int][Math]::Ceiling($ra) } } catch { }
                    Write-Warning "Graph $status, waiting ${wait}s (attempt $attempt/$MaxRetries)"
                    Start-Sleep -Seconds $wait
                    continue
                }
                throw
            }
        }
        if ($page.PSObject.Properties.Name -contains 'value') { foreach ($i in @($page.value)) { [void]$all.Add($i) } }
        else { [void]$all.Add($page) }
        $next = $page.'@odata.nextLink'
    }
    $all.ToArray()
}
