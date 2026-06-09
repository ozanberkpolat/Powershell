#Requires -Modules Az.Accounts, Az.RecoveryServices, Az.Network

<#
.SYNOPSIS
    For every ASR-replicated VM, verifies that its configured recovery network
    matches what the vault's network mapping says it should be.

    Uses the ASR REST API directly to avoid Set-AzRecoveryServicesVaultContext
    module version issues.

.PARAMETER SubscriptionId
    Optional. Defaults to current Az context.

.PARAMETER VaultName
    Optional. Restrict to a single vault by name.

.EXAMPLE
    .\Check-ASRVMFailoverNetworks.ps1

.EXAMPLE
    .\Check-ASRVMFailoverNetworks.ps1 -VaultName "rsv-isbankag-dr-prod-gn"
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
function Write-Ok([string]$Text)    { Write-Host "  [OK]       $Text" -ForegroundColor Green   }
function Write-Bad([string]$Text)   { Write-Host "  [MISMATCH] $Text" -ForegroundColor Red     }
function Write-Warn([string]$Text)  { Write-Host "  [WARN]     $Text" -ForegroundColor Yellow  }
function Write-Info([string]$Text)  { Write-Host "  [INFO]     $Text" -ForegroundColor Gray    }
function Write-NoNet([string]$Text) { Write-Host "  [NO-NET]   $Text" -ForegroundColor Magenta }

function Invoke-AzAsrApi([string]$Uri) {
    $response = Invoke-AzRestMethod -Uri $Uri -Method GET
    if ($response.StatusCode -notin 200, 201) {
        throw "API call failed ($($response.StatusCode)): $($response.Content)"
    }
    return ($response.Content | ConvertFrom-Json)
}

function Get-AllPages([string]$Uri) {
    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-AzAsrApi -Uri $next
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

# ---------- VNet inventory ---------------------------------------------------

Write-Header "Loading VNet inventory"
$vnetsRaw = Get-AllPages -Uri "$base/subscriptions/$subId/providers/Microsoft.Network/virtualNetworks?api-version=2023-06-01"
$allVnets = @($vnetsRaw)
$vnetById = @{}
foreach ($v in $allVnets) { $vnetById[$v.id.ToLower()] = $v }
Write-Info "VNets found: $($allVnets.Count)"

# ---------- Vaults -----------------------------------------------------------

Write-Header "Loading Recovery Services Vaults"
$vaultsRaw = Get-AllPages -Uri "$base/subscriptions/$subId/providers/Microsoft.RecoveryServices/vaults?api-version=2023-06-01"
$vaults = @($vaultsRaw)
if ($VaultName) {
    $vaults = @($vaults | Where-Object { $_.name -eq $VaultName })
}
if ($vaults.Count -eq 0) { Write-Warn "No vaults found."; exit 0 }
Write-Info "Vaults to inspect: $($vaults.Count)"
foreach ($v in $vaults) {
    $rgName = ($v.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
    Write-Info "  - $($v.name)  [$rgName]  ($($v.location))"
}

# ---------- Report -----------------------------------------------------------

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($vault in $vaults) {

    Write-Header "Vault: $($vault.name)"
    $vaultId = $vault.id

    # ---- Load network mappings for this vault (all fabrics) -----------------

    $mappingLookup = @{}   # sourceNetId -> targetNetId  (both lowercase)

    try {
        $mappingsUrl = "$base$vaultId/replicationNetworkMappings?api-version=$ApiVersion"
        $allMappings = Get-AllPages -Uri $mappingsUrl
        Write-Info "Network mappings found: $($allMappings.Count)"

        foreach ($m in $allMappings) {
            $srcId = $m.properties.primaryNetworkId
            $tgtId = $m.properties.recoveryNetworkId
            if ($srcId -and $tgtId) {
                $mappingLookup[$srcId.ToLower()] = $tgtId.ToLower()
            }
        }
    } catch {
        Write-Warn "Could not load network mappings: $_"
    }

    # ---- Load replicated items ----------------------------------------------

    $itemsUrl = "$base$vaultId/replicationProtectedItems?api-version=$ApiVersion"
    $items    = $null
    try {
        $items = Get-AllPages -Uri $itemsUrl
        Write-Info "Replicated VMs found: $($items.Count)"
    } catch {
        Write-Warn "Could not load replicated items: $_"
        continue
    }

    if ($null -eq $items -or $items.Count -eq 0) {
        Write-Info "No replicated items in this vault."
        continue
    }

    foreach ($item in $items) {
        $p    = $item.properties
        $name = $p.friendlyName
        if (-not $name) { $name = $item.name }

        # Source VNet: where the VM is running right now
        $srcNetId = ""
        if ($p.providerSpecificDetails -and $p.providerSpecificDetails.vmNics) {
            $primaryNic = $p.providerSpecificDetails.vmNics |
                          Where-Object { $_.isPrimaryNic -eq $true } |
                          Select-Object -First 1
            if (-not $primaryNic -and $p.providerSpecificDetails.vmNics.Count -gt 0) {
                $primaryNic = $p.providerSpecificDetails.vmNics[0]
            }
            if ($primaryNic -and $primaryNic.sourceNicArmId) {
                # sourceNicArmId is the NIC ID; derive the VNet from the subnet ID on the NIC
                # but ASR also exposes vmNetworkName directly
            }
            if ($primaryNic -and $primaryNic.vmNetworkName) {
                $srcNetId = $primaryNic.vmNetworkName.ToLower()
            }
        }

        # Fallback source VNet from protected item level
        if (-not $srcNetId -and $p.providerSpecificDetails -and $p.providerSpecificDetails.selectedSourceNetworkId) {
            $srcNetId = $p.providerSpecificDetails.selectedSourceNetworkId.ToLower()
        }

        # Recovery VNet configured on the VM (per-VM override, beats mapping)
        $configuredRecoveryNetId     = ""
        $configuredRecoverySubnet    = ""
        if ($p.providerSpecificDetails -and $p.providerSpecificDetails.vmNics) {
            $primaryNic = $p.providerSpecificDetails.vmNics |
                          Where-Object { $_.isPrimaryNic -eq $true } |
                          Select-Object -First 1
            if (-not $primaryNic -and $p.providerSpecificDetails.vmNics.Count -gt 0) {
                $primaryNic = $p.providerSpecificDetails.vmNics[0]
            }
            if ($primaryNic -and $primaryNic.recoveryVMNetworkId) {
                $configuredRecoveryNetId  = $primaryNic.recoveryVMNetworkId.ToLower()
            }
            if ($primaryNic -and $primaryNic.recoveryVMSubnetName) {
                $configuredRecoverySubnet = $primaryNic.recoveryVMSubnetName
            }
        }
        if (-not $configuredRecoveryNetId -and $p.providerSpecificDetails -and
            $p.providerSpecificDetails.recoveryAzureNetworkId) {
            $configuredRecoveryNetId = $p.providerSpecificDetails.recoveryAzureNetworkId.ToLower()
        }

        # Expected recovery VNet from mapping rules
        $expectedRecoveryNetId = ""
        if ($srcNetId -and $mappingLookup.ContainsKey($srcNetId)) {
            $expectedRecoveryNetId = $mappingLookup[$srcNetId]
        }

        # Resolve to friendly names (REST objects use .name, not .Name)
        $srcName = if ($srcNetId -and $vnetById.ContainsKey($srcNetId)) {
            $vnetById[$srcNetId].name
        } elseif ($srcNetId) { $srcNetId } else { "(not resolved)" }

        $cfgName = if ($configuredRecoveryNetId -and $vnetById.ContainsKey($configuredRecoveryNetId)) {
            $vnetById[$configuredRecoveryNetId].name
        } elseif ($configuredRecoveryNetId) { $configuredRecoveryNetId } else { "(not set)" }

        $expName = if ($expectedRecoveryNetId -and $vnetById.ContainsKey($expectedRecoveryNetId)) {
            $vnetById[$expectedRecoveryNetId].name
        } elseif ($expectedRecoveryNetId) { $expectedRecoveryNetId } else { "(no mapping)" }

        $replicationState = if ($p.replicationState) { $p.replicationState } else { "Unknown" }
        $primaryRegion    = if ($p.primaryFabricFriendlyName) { $p.primaryFabricFriendlyName } else { "" }
        $recoveryRegion   = if ($p.recoveryFabricFriendlyName) { $p.recoveryFabricFriendlyName } else { "" }

        $status = if (-not $configuredRecoveryNetId) {
            "NO_RECOVERY_NET"
        } elseif (-not $expectedRecoveryNetId) {
            "NO_MAPPING_FOR_SOURCE"
        } elseif ($configuredRecoveryNetId -eq $expectedRecoveryNetId) {
            "OK"
        } else {
            "MISMATCH"
        }

        $row = [PSCustomObject]@{
            Vault                    = $vault.Name
            VM                       = $name
            ReplicationState         = $replicationState
            PrimaryRegion            = $primaryRegion
            RecoveryRegion           = $recoveryRegion
            SourceVNet               = $srcName
            ConfiguredRecoveryVNet   = $cfgName
            ConfiguredRecoverySubnet = $configuredRecoverySubnet
            ExpectedRecoveryVNet     = $expName
            Status                   = $status
        }
        $report.Add($row)

        $vmLine = "$name  |  src: $srcName  |  state: $replicationState"
        switch ($status) {
            "OK"                   { Write-Ok    "$vmLine  ->  $cfgName  (matches mapping)" }
            "MISMATCH"             {
                Write-Bad "$vmLine"
                Write-Bad "    configured recovery : $cfgName  (subnet: $configuredRecoverySubnet)"
                Write-Bad "    expected by mapping : $expName"
            }
            "NO_RECOVERY_NET"      { Write-NoNet "$vmLine  -- no recovery network configured" }
            "NO_MAPPING_FOR_SOURCE"{ Write-Warn  "$vmLine  ->  $cfgName  (source VNet not in any mapping)" }
        }
    }
}

# ---------- Summary ----------------------------------------------------------

Write-Header "Summary"

$ok        = @($report | Where-Object { $_.Status -eq "OK"                    })
$mismatch  = @($report | Where-Object { $_.Status -eq "MISMATCH"              })
$noNet     = @($report | Where-Object { $_.Status -eq "NO_RECOVERY_NET"       })
$noMapping = @($report | Where-Object { $_.Status -eq "NO_MAPPING_FOR_SOURCE" })

Write-Host ""
Write-Host "  Total VMs checked             : $($report.Count)"
Write-Host "  OK (recovery VNet correct)    : $($ok.Count)"       -ForegroundColor $(if ($ok.Count       -gt 0) { 'Green'   } else { 'Gray'   })
Write-Host "  MISMATCH (wrong recovery VNet): $($mismatch.Count)" -ForegroundColor $(if ($mismatch.Count  -gt 0) { 'Red'     } else { 'Green'  })
Write-Host "  No recovery VNet set          : $($noNet.Count)"    -ForegroundColor $(if ($noNet.Count     -gt 0) { 'Magenta' } else { 'Green'  })
Write-Host "  Source VNet has no mapping    : $($noMapping.Count)"-ForegroundColor $(if ($noMapping.Count -gt 0) { 'Yellow'  } else { 'Green'  })

if ($mismatch.Count -gt 0) {
    Write-Host ""
    Write-Host "  VMs that will failover to the WRONG network:" -ForegroundColor Red
    $mismatch | Format-Table VM, SourceVNet, ConfiguredRecoveryVNet, ExpectedRecoveryVNet -AutoSize
}

if ($noNet.Count -gt 0) {
    Write-Host ""
    Write-Host "  VMs with no recovery network configured:" -ForegroundColor Magenta
    $noNet | Format-Table VM, SourceVNet, ReplicationState -AutoSize
}

# ---------- Export -----------------------------------------------------------

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$exportPath = Join-Path $PSScriptRoot "ASR-VMFailoverNetworks-$timestamp.csv"
$report | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "  Full report exported to: $exportPath" -ForegroundColor Cyan
