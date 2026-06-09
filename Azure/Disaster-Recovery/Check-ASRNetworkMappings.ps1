#Requires -Modules Az.Accounts, Az.RecoveryServices, Az.Network

<#
.SYNOPSIS
    Audits Azure Site Recovery network mappings across Recovery Services Vaults
    and cross-references them against actual VNets in the subscription.

    Uses the ASR REST API directly to avoid Set-AzRecoveryServicesVaultContext
    module version issues.

.PARAMETER SubscriptionId
    Optional. Defaults to current Az context subscription.

.PARAMETER DrRegion
    Azure region where your DR vaults reside (e.g. "germanynorth").

.PARAMETER SourceRegion
    Primary/source Azure region (e.g. "germanywestcentral").

.PARAMETER ResourceGroupFilter
    Optional. Comma-separated RG names to limit vault search.

.EXAMPLE
    .\Check-ASRNetworkMappings.ps1 -DrRegion "germanynorth" -SourceRegion "germanywestcentral"
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$DrRegion,
    [string]$SourceRegion,
    [string]$ResourceGroupFilter
)

$ErrorActionPreference = 'Stop'
$ApiVersion = "2023-06-01"

function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host ("-" * 70) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "  [OK]      $Text" -ForegroundColor Green  }
function Write-Warn([string]$Text) { Write-Host "  [WARN]    $Text" -ForegroundColor Yellow }
function Write-Miss([string]$Text) { Write-Host "  [MISSING] $Text" -ForegroundColor Red    }
function Write-Info([string]$Text) { Write-Host "  [INFO]    $Text" -ForegroundColor Gray   }

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

# ---------- VNet inventory ---------------------------------------------------

Write-Header "Loading all VNets in subscription"
$allVnets = @(Get-AllPages -Uri "$base/subscriptions/$subId/providers/Microsoft.Network/virtualNetworks?api-version=2023-06-01")
Write-Info "Total VNets found: $($allVnets.Count)"

$drVnets = @(
    if ($DrRegion) {
        $allVnets | Where-Object { $_.location -eq $DrRegion.ToLower() }
    } else { $allVnets }
)
$sourceVnets = @(
    if ($SourceRegion) {
        $allVnets | Where-Object { $_.location -eq $SourceRegion.ToLower() }
    } else { $allVnets }
)

if ($DrRegion)     { Write-Info "DR VNets     ($DrRegion)     : $($drVnets.Count)"     }
if ($SourceRegion) { Write-Info "Source VNets ($SourceRegion) : $($sourceVnets.Count)" }

$vnetById = @{}
foreach ($v in $allVnets) { $vnetById[$v.id.ToLower()] = $v }

# ---------- Vaults -----------------------------------------------------------

Write-Header "Discovering Recovery Services Vaults"

$rgList = @(
    if ($ResourceGroupFilter) {
        $ResourceGroupFilter -split ',' | ForEach-Object { $_.Trim() }
    }
)

$vaults = @(Get-AllPages -Uri "$base/subscriptions/$subId/providers/Microsoft.RecoveryServices/vaults?api-version=2023-06-01")

if ($DrRegion) {
    $vaults = @($vaults | Where-Object { $_.location -eq $DrRegion.ToLower() })
}
if ($rgList.Count -gt 0) {
    $vaults = @($vaults | Where-Object {
        $rgFromId = ($_.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
        $rgFromId -in $rgList
    })
}
if ($vaults.Count -eq 0) {
    Write-Warn "No Recovery Services Vaults found matching the specified filters."
    exit 0
}

Write-Info "Vaults to inspect: $($vaults.Count)"
foreach ($v in $vaults) {
    $rgName = ($v.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
    Write-Info "  - $($v.name)  [$rgName]  ($($v.location))"
}

# ---------- Per-vault audit --------------------------------------------------

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vault in $vaults) {

    $vaultRg = ($vault.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
    Write-Header "Vault: $($vault.name)  [$vaultRg]"
    $vaultId = $vault.id

    $allMappings = $null
    try {
        $url         = "$base$vaultId/replicationNetworkMappings?api-version=$ApiVersion"
        $allMappings = Get-AllPages -Uri $url
        Write-Info "Network mappings found: $($allMappings.Count)"
    } catch {
        Write-Warn "Could not load network mappings: $_"
        continue
    }

    if ($null -eq $allMappings -or $allMappings.Count -eq 0) {
        Write-Info "No network mappings configured in this vault."
        continue
    }

    foreach ($mapping in $allMappings) {
        $p     = $mapping.properties
        $srcId = if ($p.primaryNetworkId)  { $p.primaryNetworkId.ToLower()  } else { "" }
        $tgtId = if ($p.recoveryNetworkId) { $p.recoveryNetworkId.ToLower() } else { "" }

        $srcVnet = if ($srcId -and $vnetById.ContainsKey($srcId)) { $vnetById[$srcId] } else { $null }
        $tgtVnet = if ($tgtId -and $vnetById.ContainsKey($tgtId)) { $vnetById[$tgtId] } else { $null }

        $srcName = if ($srcVnet) { $srcVnet.name } elseif ($srcId) { "(ID only) $srcId" } else { "N/A" }
        $tgtName = if ($tgtVnet) { $tgtVnet.name } elseif ($tgtId) { "(ID only) $tgtId" } else { "N/A" }

        $srcExists = $null -ne $srcVnet
        $tgtExists = $null -ne $tgtVnet

        $status = if     ($srcExists -and $tgtExists)            { "OK"             }
                  elseif (-not $srcExists -and -not $tgtExists)  { "BOTH_MISSING"   }
                  elseif (-not $srcExists)                       { "SOURCE_MISSING" }
                  else                                           { "TARGET_MISSING" }

        $row = [PSCustomObject]@{
            Vault          = $vault.name
            VaultRG        = $vaultRg
            MappingName    = $mapping.name
            MappingState   = $p.state
            SourceVNet     = $srcName
            SourceLocation = if ($srcVnet) { $srcVnet.location } else { "unknown" }
            TargetVNet     = $tgtName
            TargetLocation = if ($tgtVnet) { $tgtVnet.location } else { "unknown" }
            Status         = $status
        }
        $report.Add($row)

        switch ($status) {
            "OK"             { Write-Ok   "[$($mapping.name)]  $srcName  ->  $tgtName  (state: $($p.state))" }
            "TARGET_MISSING" { Write-Miss "[$($mapping.name)]  $srcName  ->  TARGET NOT FOUND: $tgtId"       }
            "SOURCE_MISSING" { Write-Miss "[$($mapping.name)]  SOURCE NOT FOUND: $srcId  ->  $tgtName"       }
            "BOTH_MISSING"   { Write-Miss "[$($mapping.name)]  BOTH ENDS NOT FOUND -- src: $srcId  tgt: $tgtId" }
        }
    }
}

# ---------- Summary ----------------------------------------------------------

Write-Header "Summary"

$ok     = @($report | Where-Object { $_.Status -eq "OK" })
$broken = @($report | Where-Object { $_.Status -ne "OK" })

Write-Host ""
Write-Host "  Total mappings inspected  : $($report.Count)"
Write-Host "  Healthy (both VNets exist): $($ok.Count)"     -ForegroundColor Green
if ($broken.Count -gt 0) {
    Write-Host "  Problematic               : $($broken.Count)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Problematic mappings:" -ForegroundColor Yellow
    $broken | Format-Table Vault, MappingName, Status, SourceVNet, TargetVNet -AutoSize
} else {
    Write-Host "  Problematic               : 0" -ForegroundColor Green
}

# ---------- Unmapped DR VNets ------------------------------------------------

if ($DrRegion) {
    Write-Header "DR VNets with no incoming mapping (potential gaps)"

    $mappedTargetNames = @($report | Select-Object -ExpandProperty TargetVNet -Unique)
    $unmappedDr = @($drVnets | Where-Object { $_.name -notin $mappedTargetNames })

    if ($unmappedDr.Count -gt 0) {
        Write-Warn "The following DR VNets have no network mapping targeting them:"
        $unmappedDr | ForEach-Object {
            $rg      = ($_.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
            $prefix  = $_.properties.addressSpace.addressPrefixes -join ', '
            Write-Host "    $($_.name)  [$rg]  ($($_.location))  $prefix" -ForegroundColor Yellow
        }
    } else {
        Write-Ok "All DR VNets in '$DrRegion' appear in at least one network mapping."
    }
}

# ---------- Unmapped Source VNets --------------------------------------------

if ($SourceRegion) {
    Write-Header "Source VNets with no outgoing mapping (potential gaps)"

    $mappedSourceNames = @($report | Select-Object -ExpandProperty SourceVNet -Unique)
    $unmappedSrc = @($sourceVnets | Where-Object { $_.name -notin $mappedSourceNames })

    if ($unmappedSrc.Count -gt 0) {
        Write-Warn "The following source VNets have no network mapping originating from them:"
        $unmappedSrc | ForEach-Object {
            $rg      = ($_.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
            $prefix  = $_.properties.addressSpace.addressPrefixes -join ', '
            Write-Host "    $($_.name)  [$rg]  ($($_.location))  $prefix" -ForegroundColor Yellow
        }
    } else {
        Write-Ok "All source VNets in '$SourceRegion' appear in at least one network mapping."
    }
}

# ---------- Export -----------------------------------------------------------

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$exportPath = Join-Path $PSScriptRoot "ASR-NetworkMapping-Report-$timestamp.csv"
$report | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "  Full report exported to: $exportPath" -ForegroundColor Cyan
