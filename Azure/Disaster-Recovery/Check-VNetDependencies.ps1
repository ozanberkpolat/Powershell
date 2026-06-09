#Requires -Modules Az.RecoveryServices, Az.Network

<#
.SYNOPSIS
    Checks whether specified VNets have any ASR, peering, or resource dependencies
    before they are safe to delete.

.PARAMETER VNetNames
    Comma-separated list of VNet names to check.

.PARAMETER SubscriptionId
    Optional. Defaults to current Az context.

.EXAMPLE
    .\Check-VNetDependencies.ps1 `
        -VNetNames "vnet-isbankag-subsystem-prod-gw-asr,vnet-isbankag-dmz-nonprod-gw-asr"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VNetNames,

    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host ("-" * 70) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("-" * 70) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "  [SAFE]    $Text" -ForegroundColor Green  }
function Write-Block([string]$Text){ Write-Host "  [BLOCKED] $Text" -ForegroundColor Red    }
function Write-Warn([string]$Text) { Write-Host "  [WARN]    $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text) { Write-Host "  [INFO]    $Text" -ForegroundColor Gray   }

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$targetNames = $VNetNames -split ',' | ForEach-Object { $_.Trim() }

Write-Header "Loading VNets"
$allVnets = @(Get-AzVirtualNetwork)
Write-Info "Total VNets in subscription: $($allVnets.Count)"

$targets = @($allVnets | Where-Object { $_.Name -in $targetNames })

if ($targets.Count -eq 0) {
    Write-Warn "None of the specified VNet names were found in this subscription."
    exit 0
}

$notFound = $targetNames | Where-Object { $_ -notin $targets.Name }
foreach ($n in $notFound) {
    Write-Warn "VNet not found (may already be deleted): $n"
}

# ---------- Per-VNet checks --------------------------------------------------

$safeToDelete   = [System.Collections.Generic.List[string]]::new()
$blockedVnets   = [System.Collections.Generic.List[string]]::new()

foreach ($vnet in $targets) {

    Write-Header "Checking: $($vnet.Name)  [$($vnet.ResourceGroupName)]  ($($vnet.Location))"
    $blocked = $false

    # 1. VNet peerings
    $peerings = @($vnet.VirtualNetworkPeerings)
    if ($peerings.Count -gt 0) {
        $blocked = $true
        foreach ($p in $peerings) {
            Write-Block "Active peering: $($p.Name)  (state: $($p.PeeringState))"
        }
    } else {
        Write-Ok "No VNet peerings."
    }

    # 2. Connected resources (NICs on subnets)
    $connectedResources = @()
    foreach ($subnet in $vnet.Subnets) {
        $ipConfigs = @($subnet.IpConfigurations)
        if ($ipConfigs.Count -gt 0) {
            $connectedResources += $ipConfigs
            $blocked = $true
            foreach ($ip in $ipConfigs) {
                Write-Block "Subnet '$($subnet.Name)' has connected resource: $($ip.Id)"
            }
        }
    }
    if ($connectedResources.Count -eq 0) {
        Write-Ok "No connected resources (NICs/endpoints) on any subnet."
    }

    # 3. Private endpoints
    $privateEndpoints = @($vnet.Subnets | Where-Object { $_.PrivateEndpoints.Count -gt 0 })
    if ($privateEndpoints.Count -gt 0) {
        $blocked = $true
        foreach ($s in $privateEndpoints) {
            foreach ($pe in $s.PrivateEndpoints) {
                Write-Block "Private endpoint on subnet '$($s.Name)': $($pe.Id)"
            }
        }
    } else {
        Write-Ok "No private endpoints."
    }

    # 4. ASR network mappings (check all vaults)
    Write-Info "Checking ASR network mappings across all Recovery Services Vaults..."
    $vnetIdLower = $vnet.Id.ToLower()
    $asrHit = $false

    $vaults = @(Get-AzRecoveryServicesVault)
    foreach ($vault in $vaults) {
        Set-AzRecoveryServicesVaultContext -Vault $vault | Out-Null

        $fabrics = $null
        try { $fabrics = @(Get-AzRecoveryServicesAsrFabric) } catch { continue }
        if ($null -eq $fabrics -or $fabrics.Count -eq 0) { continue }

        foreach ($fabric in $fabrics) {
            $networks = $null
            try { $networks = @(Get-AzRecoveryServicesAsrNetwork -Fabric $fabric) } catch { continue }
            if ($null -eq $networks -or $networks.Count -eq 0) { continue }

            foreach ($network in $networks) {
                $mappings = $null
                try { $mappings = @(Get-AzRecoveryServicesAsrNetworkMapping -Network $network) } catch { continue }
                if ($null -eq $mappings -or $mappings.Count -eq 0) { continue }

                foreach ($mapping in $mappings) {
                    $srcId = if ($mapping.PrimaryNetworkId)  { $mapping.PrimaryNetworkId.ToLower()  } else { "" }
                    $tgtId = if ($mapping.RecoveryNetworkId) { $mapping.RecoveryNetworkId.ToLower() } else { "" }

                    if ($srcId -eq $vnetIdLower -or $tgtId -eq $vnetIdLower) {
                        $asrHit = $true
                        $blocked = $true
                        Write-Block "ASR network mapping in vault '$($vault.Name)': mapping '$($mapping.Name)'  (src: $($mapping.PrimaryNetworkId -split '/' | Select-Object -Last 1)  ->  tgt: $($mapping.RecoveryNetworkId -split '/' | Select-Object -Last 1))"
                    }
                }
            }
        }
    }

    # 5. ASR replicated items using this VNet as recovery network
    Write-Info "Checking ASR replicated items (VMs) for recovery network references..."
    $vaults2 = @(Get-AzRecoveryServicesVault)
    foreach ($vault in $vaults2) {
        Set-AzRecoveryServicesVaultContext -Vault $vault | Out-Null

        $fabrics = $null
        try { $fabrics = @(Get-AzRecoveryServicesAsrFabric) } catch { continue }
        if ($null -eq $fabrics -or $fabrics.Count -eq 0) { continue }

        foreach ($fabric in $fabrics) {
            $containers = $null
            try { $containers = @(Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric) } catch { continue }
            if ($null -eq $containers -or $containers.Count -eq 0) { continue }

            foreach ($container in $containers) {
                $items = $null
                try { $items = @(Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container) } catch { continue }
                if ($null -eq $items -or $items.Count -eq 0) { continue }

                foreach ($item in $items) {
                    $providerDetails = $item.ProviderSpecificDetails
                    $recoveryNetId = ""
                    if ($providerDetails -and $providerDetails.SelectedRecoveryAzureNetworkId) {
                        $recoveryNetId = $providerDetails.SelectedRecoveryAzureNetworkId.ToLower()
                    }

                    if ($recoveryNetId -eq $vnetIdLower) {
                        $asrHit = $true
                        $blocked = $true
                        Write-Block "ASR replicated VM '$($item.FriendlyName)' in vault '$($vault.Name)' uses this VNet as its recovery network."
                    }
                }
            }
        }
    }

    if (-not $asrHit) {
        Write-Ok "No ASR network mappings or replicated items reference this VNet."
    }

    if ($blocked) {
        $blockedVnets.Add($vnet.Name)
    } else {
        $safeToDelete.Add($vnet.Name)
    }
}

# ---------- Final verdict ----------------------------------------------------

Write-Header "Verdict"

if ($safeToDelete.Count -gt 0) {
    Write-Host ""
    Write-Host "  Safe to delete:" -ForegroundColor Green
    foreach ($n in $safeToDelete) { Write-Host "    - $n" -ForegroundColor Green }
}

if ($blockedVnets.Count -gt 0) {
    Write-Host ""
    Write-Host "  BLOCKED -- resolve dependencies before deleting:" -ForegroundColor Red
    foreach ($n in $blockedVnets) { Write-Host "    - $n" -ForegroundColor Red }
}

if ($blockedVnets.Count -eq 0) {
    Write-Host ""
    Write-Host "  All specified VNets are clear of dependencies and safe to delete." -ForegroundColor Green
}
