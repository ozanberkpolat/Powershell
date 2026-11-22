#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Exports Entra ID devices through Microsoft Graph to a CSV with the same columns as the portal's Devices > Export.

.DESCRIPTION
    Replaces the manual "Export" click in the Entra admin center, for example for a client OS support-status report.
    Reads /v1.0/devices page by page ($top=999, @odata.nextLink) and writes a comma-separated, UTF-8 with BOM CSV (opens
    correctly in Excel). Column order matches the portal export so earlier working files line up:

      id, deviceId, isManaged, profileType, systemLabels, model, displayName, accountEnabled, operatingSystem,
      operatingSystemVersion, trustType, mdmAppId, isCompliant, registrationDateTime, approximateLastSignInDateTime

    `systemLabels` is written as a JSON array string ("[]" when empty), as the portal does.

    Optional filters and additions, from the stale-device report variant:
      -OperatingSystem   keep only devices whose operatingSystem matches the wildcard (for example Windows*)
      -StaleDays         add a DaysSinceSignIn column and keep only devices with no sign-in for at least that many days
                         (devices that never signed in count as stale)

    A device list of zero rows is an error: it means missing permission or a wrong tenant, not an empty directory.
    Prints a count by operating system.

.PARAMETER OutFile
    CSV path. Default .\entra-devices-<yyyyMMdd>.csv.

.PARAMETER TenantId
    Optional tenant to sign in to.

.PARAMETER OperatingSystem
    Wildcard filter on operatingSystem.

.PARAMETER StaleDays
    Keep only devices not signed in for this many days.

.EXAMPLE
    .\Export-EntraDevices.ps1 -OutFile C:\Reports\devices.csv

.EXAMPLE
    .\Export-EntraDevices.ps1 -OperatingSystem 'Windows*' -StaleDays 90

.NOTES
    Read-only. Module: Microsoft.Graph.Authentication. Delegated scope: Device.Read.All (an ordinary member can read device
    objects; admin consent may be needed for the scope in a locked-down tenant). Reuses an existing Connect-MgGraph
    session when it already holds the scope.
    Traps: ConsistencyLevel eventual is required with $count. Calling Graph through `az rest` on Windows breaks the OData
    query, because the cmd shim treats the & between parameters as a command separator and the request never reaches
    Graph; this script uses Invoke-MgGraphRequest. approximateLastSignInDateTime is approximate (updates at most about
    every 24 hours) and is empty for devices that never signed in.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path (Get-Location) ("entra-devices-{0}.csv" -f (Get-Date -Format 'yyyyMMdd'))),
    [string]$TenantId,
    [string]$OperatingSystem,
    [ValidateRange(1, 3650)][int]$StaleDays
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Same order as the portal export.
$columns = 'id', 'deviceId', 'isManaged', 'profileType', 'systemLabels', 'model', 'displayName', 'accountEnabled',
    'operatingSystem', 'operatingSystemVersion', 'trustType', 'mdmAppId', 'isCompliant',
    'registrationDateTime', 'approximateLastSignInDateTime'

$ctx = Get-MgContext
if (-not $ctx -or @($ctx.Scopes) -notcontains 'Device.Read.All') {
    $cp = @{ Scopes = 'Device.Read.All'; NoWelcome = $true }
    if ($TenantId) { $cp['TenantId'] = $TenantId }
    Connect-MgGraph @cp
}

$uri = 'https://graph.microsoft.com/v1.0/devices?$select=' + ($columns -join ',') + '&$top=999&$count=true'
$devices = New-Object System.Collections.Generic.List[object]
$pages = 0
while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -Headers @{ ConsistencyLevel = 'eventual' }
    $pages++
    foreach ($d in @($page.value)) { $devices.Add($d) }
    $uri = if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
}
if ($devices.Count -eq 0) { throw 'Graph returned zero devices. That is a fault (missing permission or wrong tenant), not an answer.' }
Write-Host "Fetched $($devices.Count) devices in $pages page(s)."

function Get-Prop($Obj, [string]$Name) { if ($Obj.PSObject.Properties.Name -contains $Name) { $Obj.$Name } else { $null } }
function ConvertTo-IsoUtc($v) {
    if ($null -eq $v -or $v -eq '') { return '' }
    if ($v -is [datetime]) { return $v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    [string]$v
}

$now = (Get-Date).ToUniversalTime()
$rows = foreach ($d in $devices) {
    $os = Get-Prop $d 'operatingSystem'
    if ($OperatingSystem -and ([string]$os -notlike $OperatingSystem)) { continue }
    $last = Get-Prop $d 'approximateLastSignInDateTime'
    $days = $null
    if ($last) { $days = [int][Math]::Floor(($now - ([datetime]$last).ToUniversalTime()).TotalDays) }
    if ($StaleDays -and $null -ne $days -and $days -lt $StaleDays) { continue }
    $row = [ordered]@{}
    foreach ($c in $columns) {
        $v = Get-Prop $d $c
        if ($c -eq 'systemLabels') { $v = if ($v) { ConvertTo-Json -InputObject @($v) -Compress } else { '[]' } }
        elseif ($c -in 'registrationDateTime', 'approximateLastSignInDateTime') { $v = ConvertTo-IsoUtc $v }
        $row[$c] = $v
    }
    if ($StaleDays) { $row['DaysSinceSignIn'] = if ($null -ne $days) { $days } else { 'never' } }
    [pscustomobject]$row
}
$rows = @($rows)
if ($rows.Count -eq 0) { throw "All $($devices.Count) devices were filtered out by -OperatingSystem / -StaleDays. Check the filters." }

# UTF-8 WITH BOM, in Windows PowerShell 5.1 and pwsh 7 alike.
$csv = $rows | ConvertTo-Csv -NoTypeInformation
[System.IO.File]::WriteAllLines($OutFile, $csv, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "Exported $($rows.Count) of $($devices.Count) devices on $(Get-Date -Format 'yyyy-MM-dd') -> $OutFile"
$rows | Group-Object { if ($_.operatingSystem) { $_.operatingSystem } else { '(blank)' } } | Sort-Object Count -Descending |
    ForEach-Object { Write-Host ('  {0,-22} {1,5}' -f $_.Name, $_.Count) }
