#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Find network interfaces that are attached to nothing and, with -Apply, delete them after a live re-check.

.DESCRIPTION
    Default run is read-only: Resource Graph lists every NIC that has no virtual machine, no private
    endpoint, no private link service and no hosted workload, with its private IPs, NSG and load balancer
    pool references. The list is written to a CSV so owners can review it.

    With -Apply each candidate is read again from ARM right before its delete (Resource Graph lags by
    minutes, and a NIC can be re-attached between the report and the run). A NIC that is attached by then
    is reported as ABORT and left alone. The full NIC JSON is saved to a backup file before every delete,
    so the IP configuration can be rebuilt if a delete turns out to be wrong. Each delete is also guarded
    by ShouldProcess, so -Apply -WhatIf prints the plan without deleting.

    Use -InputCsv to act on a reviewed list only (columns SubscriptionId, ResourceGroup, Name; the CSV this
    script writes in report mode has them). Without it, -Apply acts on every discovered candidate that is
    not excluded.

    Before you delete, check outside Azure what still points at the private IPs: DNS A/PTR records,
    firewall address objects and rules, load balancer or application configuration, monitoring targets.
    Azure does not know about those references.

.PARAMETER Subscription
    Subscription IDs to search. Default: every enabled subscription.
.PARAMETER ResourceGroup
    Only NICs in these resource groups.
.PARAMETER InputCsv
    Reviewed list to act on (SubscriptionId, ResourceGroup, Name). Rows not found are reported as SKIP.
.PARAMETER ExcludeNamePattern
    Wildcards for NIC names never to touch.
.PARAMETER Apply
    Delete. Without it the script only reports.
.PARAMETER OutDir
    Folder for the report CSV and the pre-delete backup JSON. Default: current folder.

.EXAMPLE
    ./Remove-DanglingNics.ps1                                   # report every unattached NIC

.EXAMPLE
    ./Remove-DanglingNics.ps1 -InputCsv ./reviewed-nics.csv -Apply -WhatIf

.EXAMPLE
    ./Remove-DanglingNics.ps1 -InputCsv ./reviewed-nics.csv -Apply -Confirm:$false

.NOTES
    Role: Reader for the report. Network Contributor (Microsoft.Network/networkInterfaces/delete) on the
    NICs for -Apply; activate PIM first. Modules: Az.Accounts.
    Traps kept:
      - Resource Graph is minutes behind ARM: never delete on the Resource Graph answer alone, re-read the
        NIC (virtualMachine, privateEndpoint, privateLinkService, hostedWorkloads) right before the delete.
      - A NIC-level NSG becomes orphaned when its NIC goes; the report lists it so you can clean it up
        after. A subnet-level NSG is shared with live workloads: this script never deletes NSGs.
      - A NIC that is still in a load balancer backend pool is attached to nothing but is part of a config
        somebody may expect to work; it is flagged in the report (LbPools column) for review.
      - A NIC detached a moment ago (VM being rebuilt in another network, a resize) looks dangling too.
        Confirm with the owner, or wait a day and run again.
      - The private IP is released with the NIC. Anything outside Azure that still uses the IP will later
        reach whatever gets that IP next.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$Subscription,
    [string[]]$ResourceGroup,
    [string]$InputCsv,
    [string[]]$ExcludeNamePattern = @(),
    [switch]$Apply,
    [string]$OutDir = '.'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
$api = '2024-05-01'
$stamp = Get-Date -Format yyyyMMdd-HHmmss

function Test-Attached($n) {
    $p = $n.properties
    [bool]($p.virtualMachine.id -or $p.privateEndpoint.id -or $p.privateLinkService.id -or @($p.hostedWorkloads | Where-Object { $_ }).Count)   # @($null).Count is 1
}

$kql = @"
resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isempty(tostring(properties.virtualMachine.id))
    and isempty(tostring(properties.privateEndpoint.id))
    and isempty(tostring(properties.privateLinkService.id))
    and (isnull(properties.hostedWorkloads) or array_length(properties.hostedWorkloads) == 0)
| project id, name, resourceGroup, subscriptionId, location, ipc = properties.ipConfigurations,
    Nsg = tostring(properties.networkSecurityGroup.id)
"@
$found = @(if ($Subscription) { Search-Graph -Query $kql -Subscription $Subscription } else { Search-Graph -Query $kql })
if ($ResourceGroup) { $found = @($found | Where-Object { $ResourceGroup -contains $_.resourceGroup }) }
$found = @($found | Where-Object { $n = $_.name; -not ($ExcludeNamePattern | Where-Object { $n -like $_ }) })

if ($InputCsv) {
    $want = @(Import-Csv $InputCsv)
    if (-not $want.Count) { throw "InputCsv $InputCsv has no rows." }
    $targets = foreach ($w in $want) {
        $m = $found | Where-Object { $_.subscriptionId -eq $w.SubscriptionId -and $_.resourceGroup -eq $w.ResourceGroup -and $_.name -eq $w.Name }
        if ($m) { $m } else { Write-Warning "SKIP $($w.Name): not in the unattached list (gone, attached, excluded or not readable)." }
    }
    $targets = @($targets)
} else { $targets = $found }

$rows = foreach ($t in $targets) {
    [pscustomobject]@{
        SubscriptionId = $t.subscriptionId; ResourceGroup = $t.resourceGroup; Name = $t.name; Location = $t.location
        PrivateIPs = (@($t.ipc | ForEach-Object { $_.properties.privateIPAddress }) -join ',')
        Subnet     = (@($t.ipc | ForEach-Object { "$($_.properties.subnet.id)".Split('/')[-1] } | Select-Object -Unique) -join ',')
        Nsg        = ($t.Nsg -split '/')[-1]
        LbPools    = @($t.ipc | ForEach-Object { @($_.properties.loadBalancerBackendAddressPools) | Where-Object { $_ } }).Count
    }
}
$rows = @($rows)
New-Item -ItemType Directory -Force -Path $OutDir -WhatIf:$false | Out-Null
$csv = Join-Path $OutDir "dangling-nics-$stamp.csv"
$rows | Export-Csv $csv -NoTypeInformation -WhatIf:$false
$rows | Format-Table Name, ResourceGroup, PrivateIPs, Nsg, LbPools -AutoSize | Out-String | Write-Host
Write-Host "Unattached NICs: $($rows.Count)  (report: $csv)"
if ($rows | Where-Object { $_.LbPools -gt 0 }) { Write-Warning 'Some NICs are still in a load balancer backend pool (LbPools > 0): review them before deleting.' }
if (-not $Apply) {
    if ($rows.Count) { Write-Host 'Report only. Check DNS records and firewall objects for these IPs, then re-run with -InputCsv <reviewed.csv> -Apply.' }
    return
}
if (-not $rows.Count) { Write-Warning 'Nothing to delete.'; return }

$backup = Join-Path $OutDir "dangling-nics-predelete-$stamp.json"
$saved = New-Object System.Collections.ArrayList
$deleted = 0; $aborted = 0; $failed = 0; $orphanNsg = @()
foreach ($t in $targets) {
    # Live re-check: Resource Graph may be stale.
    $live = Invoke-ArmRequest -Path "$($t.id)?api-version=$api" -IgnoreNotFound
    if (-not $live) { Write-Host "SKIP (gone): $($t.name)"; continue }
    if (Test-Attached $live) { Write-Warning "ABORT $($t.name): attached again since the report. Not deleted."; $aborted++; continue }
    $ips = @($live.properties.ipConfigurations | ForEach-Object { $_.properties.privateIPAddress }) -join ','
    if (-not $PSCmdlet.ShouldProcess("$($t.name) ($ips)", 'Delete network interface')) { continue }
    [void]$saved.Add($live)
    $saved | ConvertTo-Json -Depth 30 | Set-Content -Path $backup -Encoding utf8 -WhatIf:$false   # before the delete, every time
    try {
        Invoke-ArmRequest -Method DELETE -Path "$($t.id)?api-version=$api" | Out-Null
        Write-Host "DELETED $($t.name)"
        $deleted++
        if ($live.properties.networkSecurityGroup.id) { $orphanNsg += $live.properties.networkSecurityGroup.id }
    } catch { Write-Warning "FAILED $($t.name): $_"; $failed++ }
}
Write-Host "Deleted: $deleted  Aborted (attached): $aborted  Failed: $failed  Backup: $backup"
Write-Host 'Orphaned NIC-level NSGs from this run (review, never delete a subnet-level NSG):'
$orphanNsg | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
if ($failed) { throw "$failed NIC delete(s) failed." }
