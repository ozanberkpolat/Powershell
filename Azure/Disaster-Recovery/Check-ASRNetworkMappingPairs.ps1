#Requires -Modules Az.Accounts, Az.RecoveryServices

<#
.SYNOPSIS
    Checks that every ASR network mapping has its counterpart in the opposite
    direction. A mapping from VNet-A -> VNet-B with no VNet-B -> VNet-A entry
    means failback will have no default network mapping.

    Uses the ASR REST API directly to avoid Set-AzRecoveryServicesVaultContext
    module version issues.

.PARAMETER SubscriptionId
    Optional. Defaults to current Az context.

.PARAMETER VaultName
    Optional. Restrict to a single vault by name.

.EXAMPLE
    .\Check-ASRNetworkMappingPairs.ps1

.EXAMPLE
    .\Check-ASRNetworkMappingPairs.ps1 -VaultName "rsv-isbankag-dr-prod-gn"
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$VaultName
)

$ErrorActionPreference = 'Stop'
$ApiVersion = "2023-06-01"

function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host ("-" * 70) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)    { Write-Host "  [OK]      $Text" -ForegroundColor Green  }
function Write-Miss([string]$Text)  { Write-Host "  [MISSING] $Text" -ForegroundColor Red    }
function Write-Warn([string]$Text)  { Write-Host "  [WARN]    $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text)  { Write-Host "  [INFO]    $Text" -ForegroundColor Gray   }

function Get-AllPages([string]$Uri) {
    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $response = Invoke-AzRestMethod -Uri $next -Method GET
        if ($response.StatusCode -notin 200, 201) {
            throw "API call failed ($($response.StatusCode)): $($response.Content)"
        }
        $page = $response.Content | ConvertFrom-Json
        if ($page.value) { foreach ($item in $page.value) { $results.Add($item) } }
        $next = if ($page.nextLink) { $page.nextLink } else { $null }
    }
    return $results
}

# ---------- Context ----------------------------------------------------------

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}
$ctx   = Get-AzContext
$subId = $ctx.Subscription.Id
$base  = "https://management.azure.com"
Write-Info "Subscription : $($ctx.Subscription.Name) ($subId)"
Write-Info "Signed in as : $($ctx.Account.Id)"

# ---------- VNet name lookup (for readable output) ---------------------------

Write-Header "Loading VNet inventory"
$allVnets = @(Get-AllPages -Uri "$base/subscriptions/$subId/providers/Microsoft.Network/virtualNetworks?api-version=2023-06-01")
$vnetById = @{}
foreach ($v in $allVnets) { $vnetById[$v.id.ToLower()] = $v }
Write-Info "VNets found: $($allVnets.Count)"

# ---------- Vaults -----------------------------------------------------------

Write-Header "Loading Recovery Services Vaults"
$vaults = @(Get-AllPages -Uri "$base/subscriptions/$subId/providers/Microsoft.RecoveryServices/vaults?api-version=2023-06-01")
if ($VaultName) {
    $vaults = @($vaults | Where-Object { $_.name -eq $VaultName })
}
if ($vaults.Count -eq 0) { Write-Warn "No vaults found."; exit 0 }
Write-Info "Vaults to inspect: $($vaults.Count)"
foreach ($v in $vaults) {
    $rg = ($v.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
    Write-Info "  - $($v.name)  [$rg]  ($($v.location))"
}

# ---------- Per-vault pair check ---------------------------------------------

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vault in $vaults) {

    $vaultRg = ($vault.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
    Write-Header "Vault: $($vault.name)  [$vaultRg]"

    $mappings = $null
    try {
        $mappings = @(Get-AllPages -Uri "$base$($vault.id)/replicationNetworkMappings?api-version=$ApiVersion")
    } catch {
        Write-Warn "Could not load network mappings: $_"
        continue
    }

    if ($null -eq $mappings -or $mappings.Count -eq 0) {
        Write-Info "No network mappings in this vault."
        continue
    }

    Write-Info "Mappings found: $($mappings.Count)"

    # Build a set of all (srcId, tgtId) pairs that exist
    $existingPairs = @{}
    foreach ($m in $mappings) {
        $src = if ($m.properties.primaryNetworkId)  { $m.properties.primaryNetworkId.ToLower()  } else { "" }
        $tgt = if ($m.properties.recoveryNetworkId) { $m.properties.recoveryNetworkId.ToLower() } else { "" }
        if ($src -and $tgt) {
            $existingPairs["$src||$tgt"] = $m.name
        }
    }

    # For each mapping check that its reverse exists
    foreach ($m in $mappings) {
        $srcId = if ($m.properties.primaryNetworkId)  { $m.properties.primaryNetworkId.ToLower()  } else { "" }
        $tgtId = if ($m.properties.recoveryNetworkId) { $m.properties.recoveryNetworkId.ToLower() } else { "" }

        if (-not $srcId -or -not $tgtId) {
            Write-Warn "Mapping '$($m.name)' is missing source or target ID -- skipping."
            continue
        }

        $reverseKey     = "$tgtId||$srcId"
        $hasReverse     = $existingPairs.ContainsKey($reverseKey)
        $reverseName    = if ($hasReverse) { $existingPairs[$reverseKey] } else { "" }

        $srcName = if ($vnetById.ContainsKey($srcId)) { $vnetById[$srcId].name } else { $srcId }
        $tgtName = if ($vnetById.ContainsKey($tgtId)) { $vnetById[$tgtId].name } else { $tgtId }

        $srcRegion = if ($vnetById.ContainsKey($srcId)) { $vnetById[$srcId].location } else { "unknown" }
        $tgtRegion = if ($vnetById.ContainsKey($tgtId)) { $vnetById[$tgtId].location } else { "unknown" }

        $status = if ($hasReverse) { "OK" } else { "MISSING_REVERSE" }

        $row = [PSCustomObject]@{
            Vault          = $vault.name
            MappingName    = $m.name
            SourceVNet     = $srcName
            SourceRegion   = $srcRegion
            TargetVNet     = $tgtName
            TargetRegion   = $tgtRegion
            ReverseName    = $reverseName
            Status         = $status
        }
        $report.Add($row)

        if ($hasReverse) {
            Write-Ok   "$srcName ($srcRegion)  ->  $tgtName ($tgtRegion)  [reverse: $reverseName]"
        } else {
            Write-Miss "$srcName ($srcRegion)  ->  $tgtName ($tgtRegion)"
            Write-Miss "    reverse mapping MISSING: $tgtName ($tgtRegion)  ->  $srcName ($srcRegion)"
        }
    }
}

# ---------- Summary ----------------------------------------------------------

Write-Header "Summary"

$ok      = @($report | Where-Object { $_.Status -eq "OK"              })
$missing = @($report | Where-Object { $_.Status -eq "MISSING_REVERSE" })

Write-Host ""
Write-Host "  Total mappings checked         : $($report.Count)"
Write-Host "  Paired (reverse exists)        : $($ok.Count)"      -ForegroundColor Green
Write-Host "  Missing reverse                : $($missing.Count)" -ForegroundColor $(if ($missing.Count -gt 0) { 'Red' } else { 'Green' })

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Mappings with no reverse -- failback will have no default network:" -ForegroundColor Red
    $missing | Format-Table Vault, MappingName, SourceVNet, SourceRegion, TargetVNet, TargetRegion -AutoSize
}

# ---------- Export -----------------------------------------------------------

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$exportPath = Join-Path $PSScriptRoot "ASR-NetworkMappingPairs-$timestamp.csv"
$report | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "  Full report exported to: $exportPath" -ForegroundColor Cyan
