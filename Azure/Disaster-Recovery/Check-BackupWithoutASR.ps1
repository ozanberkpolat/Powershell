<#
.SYNOPSIS
Lists Azure VMs that are protected by Azure Backup (in dedicated Backup RSVs)
but NOT protected by Azure Site Recovery (in dedicated ASR RSVs).

.DESCRIPTION
- Reads backup-protected Azure VMs from Backup RSV(s)
- Reads ASR replicated VMs from ASR RSV(s)
- Compares by VM ARM Resource ID (case-insensitive)
- Outputs VMs that have Backup = Yes and ASR Replication = No

.PARAMETER BackupVaultIds
Array of Recovery Services Vault ARM IDs used for Azure Backup.

.PARAMETER AsrVaultIds
Array of Recovery Services Vault ARM IDs used for ASR replication.

.PARAMETER ExportCsvPath
Optional CSV export path.

.EXAMPLE
.\Get-BackupOnlyNoReplicaVMs.ps1 `
  -BackupVaultIds @("/subscriptions/.../resourceGroups/rg-backup/providers/Microsoft.RecoveryServices/vaults/rsv-backup-prod") `
  -AsrVaultIds    @("/subscriptions/.../resourceGroups/rg-asr/providers/Microsoft.RecoveryServices/vaults/rsv-asr-prod") `
  -ExportCsvPath "C:\Temp\backup-no-replica.csv"

.NOTES
Requires:
- Az.Accounts
- Az.RecoveryServices

Run Connect-AzAccount before executing.
#>

param(
    [Parameter(Mandatory = $true)]
    [string[]]$BackupVaultIds,

    [Parameter(Mandatory = $true)]
    [string[]]$AsrVaultIds,

    [string]$ExportCsvPath
)

# -----------------------------
# Helpers
# -----------------------------
function Normalize-ArmPath {
    param([string]$Path)

    if (-not $Path) { return $null }

    $p = $Path.Trim()

    # Remove accidental quotes
    $p = $p.Trim('"').Trim("'")

    # If user pasted portal URL accidentally, fail fast with helpful message
    if ($p -match '^https?://') {
        throw "Looks like you pasted a Portal URL. Please provide the Resource ID (ARM ID), not the browser URL."
    }

    # Ensure leading slash if missing
    if ($p -and -not $p.StartsWith('/')) {
        $p = "/$p"
    }

    # Remove trailing slash
    $p = $p.TrimEnd('/')

    return $p
}

function Parse-ArmId {
    param([Parameter(Mandatory = $true)][string]$ArmId)

    $ArmId = Normalize-ArmPath -Path $ArmId

    # Expected RSV ARM ID:
    # /subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.RecoveryServices/vaults/<vaultName>
    if ($ArmId -match '(?i)^/subscriptions/([^/]+)/resourcegroups/([^/]+)/providers/([^/]+)/([^/]+)/([^/]+)$') {
        return [pscustomobject]@{
            SubscriptionId  = $Matches[1]
            ResourceGroup   = $Matches[2]
            Provider        = $Matches[3]   # Microsoft.RecoveryServices
            ResourceType    = $Matches[4]   # vaults
            Name            = $Matches[5]   # vault name
            NormalizedId    = $ArmId
        }
    }

    throw "Invalid ARM ID format: $ArmId"
}

function Get-NormalizedArmVmId {
    param(
        [Parameter(Mandatory = $false)]
        [object]$InputObject
    )

    if (-not $InputObject) { return $null }

    $candidates = @()

    if ($InputObject -is [string]) {
        $candidates += $InputObject
    }

    foreach ($p in @(
        'SourceResourceId',
        'VirtualMachineId',
        'VmId',
        'FabricObjectId',
        'ProtectableItemId',
        'Id'
    )) {
        try {
            $v = $InputObject.$p
            if ($v) { $candidates += [string]$v }
        } catch {}
    }

    try {
        $psd = $InputObject.ProviderSpecificDetails
        if ($psd) {
            foreach ($p in @(
                'SourceResourceId',
                'FabricObjectId',
                'VmId',
                'VirtualMachineId',
                'ProtectableItemId'
            )) {
                try {
                    $v = $psd.$p
                    if ($v) { $candidates += [string]$v }
                } catch {}
            }
        }
    } catch {}

    foreach ($c in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if ($c -match '(?i)(/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.compute/virtualmachines/[^/\s]+)') {
            return $Matches[1].ToLowerInvariant()
        }
    }

    return $null
}

function Parse-BackupContainerOrItemNameToVmInfo {
    param([string]$NameOrContainerName)

    if (-not $NameOrContainerName) { return $null }

    # Typical formats:
    # IaasVMContainer;iaasvmcontainerv2;RGNAME;VMNAME
    # VM;iaasvmcontainerv2;RGNAME;VMNAME
    $parts = $NameOrContainerName -split ';'
    if ($parts.Count -ge 4) {
        return [pscustomobject]@{
            ResourceGroupName = $parts[2]
            VMName            = $parts[3]
        }
    }

    return $null
}

function Get-RecoveryVaultById {
    param(
        [Parameter(Mandatory = $true)][string]$VaultId
    )

    $p = Parse-ArmId -ArmId $VaultId

    if ($p.Provider -notmatch '(?i)^Microsoft\.RecoveryServices$' -or $p.ResourceType -notmatch '(?i)^vaults$') {
        throw "ARM ID is not a Recovery Services Vault ID: $VaultId"
    }

    Select-AzSubscription -SubscriptionId $p.SubscriptionId -ErrorAction Stop | Out-Null

    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $p.ResourceGroup -Name $p.Name -ErrorAction Stop
    return [pscustomobject]@{
        Vault = $vault
        Parsed = $p
    }
}

# -----------------------------
# Pre-flight checks
# -----------------------------
if (-not (Get-AzContext)) {
    throw "No Azure session found. Run Connect-AzAccount first."
}

# Normalize and de-duplicate input
$BackupVaultIds = $BackupVaultIds | ForEach-Object { Normalize-ArmPath $_ } | Where-Object { $_ } | Select-Object -Unique
$AsrVaultIds    = $AsrVaultIds    | ForEach-Object { Normalize-ArmPath $_ } | Where-Object { $_ } | Select-Object -Unique

# Main data structures
$backupVmMap = @{}  # key: VM ARM ID (lower) -> metadata
$asrVmIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

Write-Host "Collecting Backup-protected VMs from Backup RSV(s)..." -ForegroundColor Cyan

# -----------------------------
# 1) BACKUP vaults only
# -----------------------------
foreach ($backupVaultId in $BackupVaultIds) {
    try {
        $vaultObj = Get-RecoveryVaultById -VaultId $backupVaultId
        $vault = $vaultObj.Vault
        $subId = $vaultObj.Parsed.SubscriptionId

        $ctx = Get-AzContext
        $subName = $ctx.Subscription.Name

        Write-Host "  [Backup RSV] $($vault.Name) | RG=$($vault.ResourceGroupName) | SUB=$subName" -ForegroundColor Yellow

        $containers = Get-AzRecoveryServicesBackupContainer `
            -ContainerType AzureVM `
            -Status Registered `
            -VaultId $vault.ID `
            -ErrorAction SilentlyContinue

        foreach ($container in ($containers | Where-Object { $_ })) {
            $items = Get-AzRecoveryServicesBackupItem `
                -Container $container `
                -WorkloadType AzureVM `
                -VaultId $vault.ID `
                -ErrorAction SilentlyContinue

            foreach ($item in ($items | Where-Object { $_ })) {
                $vmArmId = Get-NormalizedArmVmId -InputObject $item
                $parsed = $null

                if (-not $vmArmId) {
                    $parsed = Parse-BackupContainerOrItemNameToVmInfo -NameOrContainerName $item.ContainerName
                    if (-not $parsed) {
                        $parsed = Parse-BackupContainerOrItemNameToVmInfo -NameOrContainerName $item.Name
                    }

                    if ($parsed -and $parsed.ResourceGroupName -and $parsed.VMName) {
                        $vmArmId = ("/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}" -f `
                            $subId, $parsed.ResourceGroupName, $parsed.VMName).ToLowerInvariant()
                    }
                }

                if (-not $vmArmId) {
                    Write-Warning "Could not resolve VM ARM ID for backup item '$($item.Name)' in vault '$($vault.Name)'"
                    continue
                }

                $rgName = $null
                $vmName = $null
                if ($parsed) {
                    $rgName = $parsed.ResourceGroupName
                    $vmName = $parsed.VMName
                }
                elseif ($vmArmId -match '(?i)/resourcegroups/([^/]+)/providers/microsoft\.compute/virtualmachines/([^/]+)$') {
                    $rgName = $Matches[1]
                    $vmName = $Matches[2]
                }

                $obj = [pscustomobject]@{
                    SubscriptionId         = $subId
                    SubscriptionName       = $subName
                    ResourceGroupName      = $rgName
                    VMName                 = $vmName
                    VmResourceId           = $vmArmId
                    BackupVaultName        = $vault.Name
                    BackupVaultResourceGrp = $vault.ResourceGroupName
                    BackupItemName         = $item.Name
                    BackupProtectionStatus = $item.ProtectionStatus
                    LastBackupStatus       = $item.LastBackupStatus
                    LastBackupTime         = $item.LastBackupTime
                }

                # If duplicate VM appears across vaults/items, keep latest backup time if possible
                if (-not $backupVmMap.ContainsKey($vmArmId)) {
                    $backupVmMap[$vmArmId] = $obj
                } else {
                    $existing = $backupVmMap[$vmArmId]
                    try {
                        if ($obj.LastBackupTime -and $existing.LastBackupTime) {
                            if ([datetime]$obj.LastBackupTime -gt [datetime]$existing.LastBackupTime) {
                                $backupVmMap[$vmArmId] = $obj
                            }
                        }
                    } catch {}
                }
            }
        }
    }
    catch {
        Write-Warning "Backup RSV processing failed for '$backupVaultId' : $($_.Exception.Message)"
    }
}

Write-Host "Collecting ASR-replicated VMs from ASR RSV(s)..." -ForegroundColor Cyan

# -----------------------------
# 2) ASR vaults only
# -----------------------------
foreach ($asrVaultId in $AsrVaultIds) {
    try {
        $vaultObj = Get-RecoveryVaultById -VaultId $asrVaultId
        $vault = $vaultObj.Vault

        $ctx = Get-AzContext
        $subName = $ctx.Subscription.Name

        Write-Host "  [ASR RSV]    $($vault.Name) | RG=$($vault.ResourceGroupName) | SUB=$subName" -ForegroundColor Magenta

        Set-AzRecoveryServicesAsrVaultContext -Vault $vault -ErrorAction Stop | Out-Null

        $fabrics = Get-AzRecoveryServicesAsrFabric -ErrorAction SilentlyContinue
        foreach ($fabric in ($fabrics | Where-Object { $_ })) {
            $containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction SilentlyContinue
            foreach ($pc in ($containers | Where-Object { $_ })) {
                $rpis = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $pc -ErrorAction SilentlyContinue
                foreach ($rpi in ($rpis | Where-Object { $_ })) {
                    $vmArmId = Get-NormalizedArmVmId -InputObject $rpi
                    if ($vmArmId) {
                        [void]$asrVmIds.Add($vmArmId)
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "ASR RSV processing failed for '$asrVaultId' : $($_.Exception.Message)"
    }
}

# -----------------------------
# 3) Compare
# -----------------------------
$result = foreach ($entry in $backupVmMap.GetEnumerator()) {
    $vmId = $entry.Key
    $b    = $entry.Value

    if (-not $asrVmIds.Contains($vmId)) {
        [pscustomobject]@{
            SubscriptionName        = $b.SubscriptionName
            SubscriptionId          = $b.SubscriptionId
            ResourceGroupName       = $b.ResourceGroupName
            VMName                  = $b.VMName
            VmResourceId            = $b.VmResourceId
            BackupVaultName         = $b.BackupVaultName
            BackupVaultResourceGrp  = $b.BackupVaultResourceGrp
            BackupProtectionStatus  = $b.BackupProtectionStatus
            LastBackupStatus        = $b.LastBackupStatus
            LastBackupTime          = $b.LastBackupTime
            ASRReplicationProtected = $false
        }
    }
}

$result = $result | Sort-Object SubscriptionName, ResourceGroupName, VMName

Write-Host ""
Write-Host "Done. Found $($result.Count) VM(s) with Backup but NO ASR replication." -ForegroundColor Green
$result | Format-Table -AutoSize

if ($ExportCsvPath) {
    $parent = Split-Path -Parent $ExportCsvPath
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $result | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV exported to: $ExportCsvPath" -ForegroundColor Cyan
}