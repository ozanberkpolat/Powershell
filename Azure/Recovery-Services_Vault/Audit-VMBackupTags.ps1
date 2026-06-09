#Requires -Modules Az.Accounts, Az.Compute, Az.RecoveryServices

<#
.SYNOPSIS
    Audits Azure VM BackupEnabled tags against actual Azure Backup protection status
    across all accessible subscriptions.

.DESCRIPTION
    For each VM in each subscription, the script:
      1. Reads the BackupEnabled tag (Yes / No / Missing)
      2. Scans all Recovery Services Vaults in the subscription for an active backup item
      3. Compares tag vs reality and reports mismatches

.OUTPUTS
    Console table + optional CSV export

.NOTES
    Required RBAC: Reader on all subscriptions + Backup Reader on all RSVs
    Modules:       Az.Accounts, Az.Compute, Az.RecoveryServices
#>

[CmdletBinding()]
param(
    [string]$CsvOutputPath = "",          # Leave empty to skip CSV export
    [switch]$MismatchesOnly               # If set, only output mismatched VMs
)

# ─── Helpers ────────────────────────────────────────────────────────────────

function Get-ProtectedVMsInSubscription {
    <#
    Returns two hashtables:
      $byId   : keyed by ARM resource ID (lowercase)         -> ProtectionStatus
      $byRgVm : keyed by "resourcegroup/vmname" (lowercase)  -> ProtectionStatus

    Using two keys because VirtualMachineId is frequently null in the Az module;
    the name+RG key is derived from ContainerName which is always populated.
    ContainerName format: "iaasvmcontainerv2;{resourceGroup};{vmName}"
    #>
    $byId   = @{}
    $byRgVm = @{}

    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    if (-not $vaults) { return $byId, $byRgVm }

    foreach ($vault in $vaults) {
        Set-AzRecoveryServicesVaultContext -Vault $vault

        $backupItems = Get-AzRecoveryServicesBackupItem `
            -BackupManagementType AzureVM `
            -WorkloadType AzureVM `
            -ErrorAction SilentlyContinue

        foreach ($item in $backupItems) {

            $status = $item.ProtectionStatus

            # Key 1: full ARM resource ID (when available)
            if ($item.VirtualMachineId) {
                $byId[$item.VirtualMachineId.ToLower()] = $status
            }

            # Key 2: resourcegroup/vmname parsed from ContainerName
            # ContainerName: "iaasvmcontainerv2;{rg};{vmName}"  or  "iaasvmcontainer;{rg};{vmName}"
            if ($item.ContainerName) {
                $parts = $item.ContainerName -split ';'
                if ($parts.Count -ge 3) {
                    $rgvmKey = ("$($parts[1])/$($parts[2])").ToLower()
                    $byRgVm[$rgvmKey] = $status
                }
            }

            # Key 3: fallback using FriendlyName alone (least specific, last resort)
            if ($item.FriendlyName) {
                # Only set if not already present (avoid overwriting a more specific key)
                $nameKey = $item.FriendlyName.ToLower()
                if (-not $byRgVm.ContainsKey($nameKey)) {
                    $byRgVm[$nameKey] = $status
                }
            }
        }
    }

    return $byId, $byRgVm
}

# ─── Main ────────────────────────────────────────────────────────────────────

# Ensure we are logged in
$context = Get-AzContext
if (-not $context) {
    Write-Error "No Azure context found. Run Connect-AzAccount first."
    exit 1
}

$results   = [System.Collections.Generic.List[PSCustomObject]]::new()
$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }

Write-Host "`nFound $($subscriptions.Count) enabled subscription(s). Starting audit...`n" -ForegroundColor Cyan

foreach ($sub in $subscriptions) {

    Write-Host "[$($sub.Name)]  $($sub.Id)" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue | Out-Null

    # Build protected-VM maps for this subscription (one RSV pass per sub)
    Write-Host "  -> Scanning Recovery Services Vaults..." -NoNewline
    $byId, $byRgVm = Get-ProtectedVMsInSubscription
    Write-Host " found $($byId.Count) item(s) by ID, $($byRgVm.Count) by RG/Name."

    # Get all VMs
    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    Write-Host "  -> Found $($vms.Count) VM(s)."

    foreach ($vm in $vms) {

        # ── Tag value ──────────────────────────────────────────────────────
        $tagValue = $null
        if ($vm.Tags -and $vm.Tags.ContainsKey('BackupEnabled')) {
            $tagValue = $vm.Tags['BackupEnabled'].Trim()
        }

        $tagNormalized = if (-not $tagValue) {
            'Missing'
        } elseif ($tagValue -match '(?i)^yes$') {
            'Yes'
        } elseif ($tagValue -match '(?i)^no$') {
            'No'
        } else {
            "Unknown ($tagValue)"
        }

        # ── Actual backup state ────────────────────────────────────────────
        # Try ID match first, then RG/Name, then Name alone
        $vmIdLower   = $vm.Id.ToLower()
        $rgVmKey     = "$($vm.ResourceGroupName)/$($vm.Name)".ToLower()
        $nameKey     = $vm.Name.ToLower()

        $protectionStatus = $byId[$vmIdLower]
        if (-not $protectionStatus) { $protectionStatus = $byRgVm[$rgVmKey] }
        if (-not $protectionStatus) { $protectionStatus = $byRgVm[$nameKey] }

        # Normalise the raw status into a display value
        # ProtectionStatus: Healthy | IRPending | Unhealthy | $null (not registered in any vault)
        $actualDetail = if ($protectionStatus) { $protectionStatus } else { 'NotFound' }

        # ── Cross-check: tag VALUE drives every branch ────────────────────
        # Tag=Yes means backup must be Healthy.
        # Tag=No  means no active backup item should exist.
        # Anything else is a data quality issue on the tag itself.
        $mismatch = $false
        $finding  = 'OK'

        switch ($tagNormalized) {

            'Yes' {
                switch ($protectionStatus) {
                    'Healthy'   { $finding = 'OK' }
                    'IRPending' { $finding = 'OK_INITIAL_BACKUP_PENDING' }   # policy assigned, first run not yet done
                    'Unhealthy' { $mismatch = $true; $finding = 'TAG_YES_BACKUP_UNHEALTHY' }
                    default     { $mismatch = $true; $finding = 'TAG_YES_NO_BACKUP_FOUND' }
                }
            }

            'No' {
                switch ($protectionStatus) {
                    $null       { $finding = 'OK' }
                    'NotFound'  { $finding = 'OK' }
                    'Healthy'   { $mismatch = $true; $finding = 'TAG_NO_BUT_BACKUP_ACTIVE' }
                    'IRPending' { $mismatch = $true; $finding = 'TAG_NO_BUT_BACKUP_ACTIVE' }
                    'Unhealthy' { $mismatch = $true; $finding = 'TAG_NO_BUT_BACKUP_EXISTS_UNHEALTHY' }
                    default     { $mismatch = $true; $finding = "TAG_NO_BUT_BACKUP_STATUS_$($protectionStatus.ToUpper())" }
                }
            }

            'Missing' {
                $mismatch = $true
                $finding  = 'TAG_MISSING'
            }

            default {
                $mismatch = $true
                $finding  = 'TAG_VALUE_INVALID'   # tag exists but value is not Yes or No
            }
        }

        if ($MismatchesOnly -and -not $mismatch) { continue }

        $results.Add([PSCustomObject]@{
            SubscriptionName  = $sub.Name
            SubscriptionId    = $sub.Id
            ResourceGroup     = $vm.ResourceGroupName
            VMName            = $vm.Name
            Location          = $vm.Location
            PowerState        = ($vm.Statuses | Where-Object Code -match 'PowerState' | Select-Object -First 1).DisplayStatus
            BackupEnabledTag  = if ($tagValue) { $tagValue } else { '(not set)' }
            TagNormalized     = $tagNormalized
            ActualBackupState = $actualState
            ProtectionStatus  = $actualDetail
            Mismatch          = $mismatch
            Finding           = $finding
        })
    }
}

# ─── Output ──────────────────────────────────────────────────────────────────

Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  AUDIT COMPLETE - $($results.Count) VM(s) evaluated" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan

$mismatches = $results | Where-Object { $_.Mismatch }

if ($mismatches.Count -eq 0) {
    Write-Host "  All tags match actual backup state. No issues found." -ForegroundColor Green
} else {
    Write-Host "  $($mismatches.Count) mismatch(es) found:`n" -ForegroundColor Red
    $mismatches | Format-Table -AutoSize `
        SubscriptionName, ResourceGroup, VMName, BackupEnabledTag, ActualBackupState, ProtectionStatus, Finding
}

Write-Host "`n  Summary by Finding:`n"
$results | Group-Object Finding | Sort-Object Count -Descending |
    Select-Object @{N='Finding';E={$_.Name}}, @{N='Count';E={$_.Count}} |
    Format-Table -AutoSize

# ─── CSV Export ──────────────────────────────────────────────────────────────

if ($CsvOutputPath) {
    $results | Export-Csv -Path $CsvOutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "`n  Full results exported to: $CsvOutputPath" -ForegroundColor Cyan
}
