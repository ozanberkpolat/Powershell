<#
.SYNOPSIS
    Validates Azure Site Recovery (ASR) network configurations across multiple
    subscriptions and Recovery Services Vaults.

.DESCRIPTION
    Iterates over one or more subscriptions, discovers all Recovery Services Vaults,
    automatically skips backup-only vaults (those with no ASR fabrics), and for each
    DR vault validates that every replicated VM's configured failover network matches
    the vault-level ASR Network Mapping.

    A2A (Azure-to-Azure) replication only.

.PARAMETER SubscriptionIds
    One or more subscription IDs to scan. If omitted, all subscriptions accessible
    in the current Az context are scanned.

.PARAMETER ExportCsv
    Optional path to export the combined results as CSV.

.EXAMPLE
    # Scan all accessible subscriptions
    .\Validate-ASRNetworkConfig.ps1

.EXAMPLE
    # Scan specific subscriptions
    .\Validate-ASRNetworkConfig.ps1 -SubscriptionIds "sub-id-1","sub-id-2","sub-id-3"

.EXAMPLE
    # With CSV export
    .\Validate-ASRNetworkConfig.ps1 -SubscriptionIds "sub-id-1","sub-id-2","sub-id-3" -ExportCsv "C:\asr-report.csv"
#>

[CmdletBinding()]
param(
    [string[]]$SubscriptionIds,

    [string]$ExportCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers
function Write-Header([string]$msg) {
    Write-Host "`n=== $msg ===" -ForegroundColor Cyan
}

function Write-SubHeader([string]$msg) {
    Write-Host "  -- $msg --" -ForegroundColor DarkCyan
}

function Write-Status([string]$status, [string]$msg) {
    $color = switch ($status) {
        'OK'             { 'Green'  }
        'MISMATCH'       { 'Red'    }
        'NOT_CONFIGURED' { 'Yellow' }
        'WARNING'        { 'Yellow' }
        default          { 'White'  }
    }
    Write-Host "    [$status] $msg" -ForegroundColor $color
}

function Get-ArmResourceName([string]$armId) {
    if ([string]::IsNullOrWhiteSpace($armId)) { return '(none)' }
    return $armId.Split('/')[-1]
}
#endregion

#region Prerequisites
Write-Header "Prerequisites"

foreach ($mod in @('Az.Accounts', 'Az.RecoveryServices', 'Az.Resources')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "$mod module not found. Run: Install-Module $mod -Scope CurrentUser"
    }
    Import-Module $mod -ErrorAction Stop
}
Write-Host "  Required modules loaded."
#endregion

#region Resolve subscriptions
Write-Header "Resolving Subscriptions"

if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $subscriptions = $SubscriptionIds | ForEach-Object {
        Get-AzSubscription -SubscriptionId $_ -ErrorAction Stop
    }
} else {
    $subscriptions = Get-AzSubscription -ErrorAction Stop
    Write-Host "  No subscriptions specified -- scanning all $($subscriptions.Count) accessible subscriptions."
}

$subscriptions | ForEach-Object { Write-Host "  - $($_.Name) ($($_.Id))" }
#endregion

#region Main scan
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($sub in $subscriptions) {

    Write-Header "Subscription: $($sub.Name) ($($sub.Id))"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Discover all RSVs in this subscription
    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    if (-not $vaults -or $vaults.Count -eq 0) {
        Write-Host "  No Recovery Services Vaults found -- skipping." -ForegroundColor DarkGray
        continue
    }

    Write-Host "  Found $($vaults.Count) vault(s): $(($vaults | Select-Object -ExpandProperty Name) -join ', ')"

    foreach ($vault in $vaults) {

        Write-SubHeader "Vault: $($vault.Name) [$($vault.ResourceGroupName)]"
        Set-AzRecoveryServicesVaultContext -Vault $vault

        # Check if this is a DR vault (has ASR fabrics) or a backup-only vault
        $fabrics = Get-AzRecoveryServicesAsrFabric -ErrorAction SilentlyContinue
        if (-not $fabrics -or $fabrics.Count -eq 0) {
            Write-Host "    No ASR fabrics found -- backup-only vault, skipping." -ForegroundColor DarkGray
            continue
        }

        Write-Host "    DR vault confirmed. Fabrics: $($fabrics.Count). Scanning network mappings..."

        #region Build network mapping lookup for this vault
        $networkMappingLookup = @{}

        foreach ($fabric in $fabrics) {
            $networks = Get-AzRecoveryServicesAsrNetwork -Fabric $fabric -ErrorAction SilentlyContinue
            if (-not $networks) { continue }

            foreach ($network in $networks) {
                $mappings = Get-AzRecoveryServicesAsrNetworkMapping -Network $network -ErrorAction SilentlyContinue
                if (-not $mappings) { continue }

                foreach ($mapping in $mappings) {
                    $srcId = $mapping.PrimaryNetworkId.ToLower()
                    $networkMappingLookup[$srcId] = $mapping.RecoveryNetworkId

                    $srcName = Get-ArmResourceName $mapping.PrimaryNetworkId
                    $tgtName = Get-ArmResourceName $mapping.RecoveryNetworkId
                    Write-Host "    Network mapping: $srcName  -->  $tgtName" -ForegroundColor DarkGray
                }
            }
        }

        if ($networkMappingLookup.Count -eq 0) {
            Write-Host "    WARNING: No network mappings found in this vault -- NIC configs cannot be cross-validated." -ForegroundColor Yellow
        }
        #endregion

        #region Inspect protected items
        foreach ($fabric in $fabrics) {
            $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction SilentlyContinue
            if (-not $containers) { continue }

            foreach ($container in $containers) {
                $protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem `
                    -ProtectionContainer $container -ErrorAction SilentlyContinue
                if (-not $protectedItems) { continue }

                foreach ($item in $protectedItems) {

                    $details = $item.ProviderSpecificDetails
                    if ($details.GetType().Name -notmatch 'A2A') {
                        Write-Verbose "    Skipping non-A2A item: $($item.FriendlyName)"
                        continue
                    }

                    $vmName           = $item.FriendlyName
                    $replicationHealth = $item.ReplicationHealth
                    $recoveryRGId     = if ($details.RecoveryAzureResourceGroupId) { $details.RecoveryAzureResourceGroupId } else { '' }
                    $recoveryRG       = Get-ArmResourceName $recoveryRGId

                    Write-Host "    VM: $vmName  |  Health: $replicationHealth" -ForegroundColor White

                    $nics = $details.VMNics
                    if (-not $nics -or $nics.Count -eq 0) {
                        $row = [PSCustomObject]@{
                            Subscription        = $sub.Name
                            SubscriptionId      = $sub.Id
                            VaultName           = $vault.Name
                            VMName              = $vmName
                            ReplicationHealth   = $replicationHealth
                            RecoveryRG          = $recoveryRG
                            NicIndex            = 'N/A'
                            SourceNetwork       = '(no NICs)'
                            SourceSubnet        = '(no NICs)'
                            ConfiguredDRNetwork = '(no NICs)'
                            ConfiguredDRSubnet  = '(no NICs)'
                            ExpectedDRNetwork   = '(no NICs)'
                            Status              = 'NOT_CONFIGURED'
                            Detail              = 'No NIC configuration found on protected item.'
                        }
                        $allResults.Add($row)
                        Write-Status 'NOT_CONFIGURED' "No NIC configuration found."
                        continue
                    }

                    $nicIndex = 0
                    foreach ($nic in $nics) {

                        $srcNetworkId   = $nic.VMNetworkName
                        $srcSubnet      = $nic.VMSubnetName
                        $cfgDRNetworkId = $nic.RecoveryVMNetworkId
                        $cfgDRSubnet    = $nic.RecoverySubnetName

                        $srcNetName = Get-ArmResourceName $srcNetworkId
                        $cfgDRName  = Get-ArmResourceName $cfgDRNetworkId

                        $expectedDRNetworkId   = $null
                        $expectedDRNetworkName = '(no mapping defined)'

                        if ($srcNetworkId) {
                            $lookupKey = $srcNetworkId.ToLower()
                            if ($networkMappingLookup.ContainsKey($lookupKey)) {
                                $expectedDRNetworkId   = $networkMappingLookup[$lookupKey]
                                $expectedDRNetworkName = Get-ArmResourceName $expectedDRNetworkId
                            }
                        }

                        # Determine status
                        if ([string]::IsNullOrWhiteSpace($cfgDRNetworkId)) {
                            $status = 'NOT_CONFIGURED'
                            $detail = 'No failover target network configured on this NIC.'
                        }
                        elseif ($null -eq $expectedDRNetworkId) {
                            $status = 'WARNING'
                            $detail = "Source network '$srcNetName' has no vault-level ASR network mapping -- cannot cross-validate."
                        }
                        elseif ($cfgDRNetworkId.ToLower() -ne $expectedDRNetworkId.ToLower()) {
                            $status = 'MISMATCH'
                            $detail = "NIC configured for '$cfgDRName' but mapping expects '$expectedDRNetworkName'."
                        }
                        else {
                            $status = 'OK'
                            $detail = 'NIC target network matches ASR network mapping.'
                        }

                        Write-Status $status "NIC[$nicIndex] $srcNetName/$srcSubnet  -->  cfg:$cfgDRName/$cfgDRSubnet  expected:$expectedDRNetworkName"

                        $row = [PSCustomObject]@{
                            Subscription        = $sub.Name
                            SubscriptionId      = $sub.Id
                            VaultName           = $vault.Name
                            VMName              = $vmName
                            ReplicationHealth   = $replicationHealth
                            RecoveryRG          = $recoveryRG
                            NicIndex            = $nicIndex
                            SourceNetwork       = $srcNetName
                            SourceSubnet        = $srcSubnet
                            ConfiguredDRNetwork = $cfgDRName
                            ConfiguredDRSubnet  = $cfgDRSubnet
                            ExpectedDRNetwork   = $expectedDRNetworkName
                            Status              = $status
                            Detail              = $detail
                        }
                        $allResults.Add($row)
                        $nicIndex++
                    }
                }
            }
        }
        #endregion
    }
}
#endregion

#region Summary
Write-Header "Summary Across All Subscriptions"

if ($allResults.Count -eq 0) {
    Write-Host "  No A2A replicated VMs found across scanned subscriptions." -ForegroundColor Yellow
    return
}

$total         = $allResults.Count
$ok            = ($allResults | Where-Object Status -eq 'OK').Count
$mismatches    = ($allResults | Where-Object Status -eq 'MISMATCH').Count
$notConfigured = ($allResults | Where-Object Status -eq 'NOT_CONFIGURED').Count
$warnings      = ($allResults | Where-Object Status -eq 'WARNING').Count

$colorOk  = if ($ok            -gt 0) { 'Green'  } else { 'White'  }
$colorMis = if ($mismatches    -gt 0) { 'Red'    } else { 'Green'  }
$colorNot = if ($notConfigured -gt 0) { 'Yellow' } else { 'Green'  }
$colorWrn = if ($warnings      -gt 0) { 'Yellow' } else { 'Green'  }

Write-Host "  Total NIC entries : $total"
Write-Host "  OK                : $ok"            -ForegroundColor $colorOk
Write-Host "  MISMATCH          : $mismatches"    -ForegroundColor $colorMis
Write-Host "  NOT_CONFIGURED    : $notConfigured" -ForegroundColor $colorNot
Write-Host "  WARNING           : $warnings"      -ForegroundColor $colorWrn

# Per-subscription breakdown
Write-Host "`n  Breakdown by subscription:" -ForegroundColor Cyan
$allResults | Group-Object Subscription | ForEach-Object {
    $grp = $_.Group
    Write-Host ("  [{0}]  OK:{1}  MISMATCH:{2}  NOT_CONFIGURED:{3}  WARNING:{4}" -f
        $_.Name,
        ($grp | Where-Object Status -eq 'OK').Count,
        ($grp | Where-Object Status -eq 'MISMATCH').Count,
        ($grp | Where-Object Status -eq 'NOT_CONFIGURED').Count,
        ($grp | Where-Object Status -eq 'WARNING').Count
    )
}

if ($mismatches -gt 0 -or $notConfigured -gt 0) {
    Write-Host "`nVMs requiring immediate attention:" -ForegroundColor Red
    $allResults |
        Where-Object { $_.Status -in 'MISMATCH','NOT_CONFIGURED' } |
        Select-Object Subscription, VaultName, VMName, NicIndex,
                      SourceNetwork, ConfiguredDRNetwork, ExpectedDRNetwork,
                      Status, Detail |
        Format-Table -AutoSize
}
#endregion

#region CSV Export
if ($ExportCsv) {
    $allResults | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Results exported to: $ExportCsv" -ForegroundColor Cyan
}
#endregion

return $allResults
