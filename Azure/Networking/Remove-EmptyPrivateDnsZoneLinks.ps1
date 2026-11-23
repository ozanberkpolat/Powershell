#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Unlink EMPTY private DNS zones (SOA record only) from one virtual network. Report by default.

.DESCRIPTION
    A private DNS zone linked to a VNet is authoritative for its whole namespace inside that VNet. If the
    zone is empty (only its SOA record), every name under it answers NXDOMAIN. For a privatelink zone such
    as privatelink.blob.core.windows.net that shadows the public CNAME chain: a storage account WITHOUT a
    private endpoint stops resolving from the VNet, although it works from everywhere else. A mass
    deployment of "all privatelink zones, linked to the hub" causes exactly that.

    Removing the link of an EMPTY zone can only make names resolve again (they fall through to public DNS).
    The zones themselves are never deleted; only the virtual network links to the given VNet are removed.

    Guards:
      - Only zones whose numberOfRecordSets is 1 (the SOA) are touched. Zones with records are listed
        loudly and skipped.
      - The record count is read again from ARM right before each delete (a record may have been added
        since the report).
      - Links with auto-registration enabled are skipped: VMs register their own records in them, so "empty
        now" does not mean "unused".

    Default run only reports. -Apply removes the links (each guarded by ShouldProcess), then polls until
    the deletes have finished.

.PARAMETER VirtualNetworkId
    Resource ID of the VNet whose links are examined (typically the hub VNet whose DNS servers or resolver
    serve the spokes).
.PARAMETER Subscription
    Subscriptions to search for zones. Default: every enabled subscription.
.PARAMETER ResourceGroup
    Only zones in these resource groups.
.PARAMETER ZoneNamePattern
    Wildcard on the zone name. Default '*'. Use 'privatelink.*' to stay with private link zones.
.PARAMETER Apply
    Remove the links. Without it the script only reports.
.PARAMETER PollMinutes
    How long to wait for the deletes to finish. Default 5.

.EXAMPLE
    ./Remove-EmptyPrivateDnsZoneLinks.ps1 -VirtualNetworkId /subscriptions/<sub>/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub

.EXAMPLE
    ./Remove-EmptyPrivateDnsZoneLinks.ps1 -VirtualNetworkId $hubId -ZoneNamePattern 'privatelink.*' -Apply -WhatIf

.NOTES
    Role: Reader for the report. Private DNS Zone Contributor on the zones for -Apply (the link delete also
    needs Microsoft.Network/virtualNetworks/join/action on the VNet, which Network Contributor has); activate
    PIM first. Modules: Az.Accounts.
    Traps kept:
      - An empty linked privatelink zone returns NXDOMAIN for every name under it: it is not harmless.
      - Clients behind the VNet's DNS (spokes that use a hub resolver or DNS forwarders, on-premises
        conditional forwarders pointing at it) see the change too, in both directions.
      - Link deletes are asynchronous (202). The script polls until each link is gone; a link still present
        at the end is reported and the script fails.
      - DNS caches keep a negative answer for the SOA minimum TTL; clients can need a few minutes (or an
        ipconfig /flushdns) before they resolve again.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$VirtualNetworkId,
    [string[]]$Subscription,
    [string[]]$ResourceGroup,
    [string]$ZoneNamePattern = '*',
    [switch]$Apply,
    [int]$PollMinutes = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
$api = '2024-06-01'
$vnet = $VirtualNetworkId.TrimEnd('/')
if ($vnet -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+$') {
    throw "VirtualNetworkId is not a VNet resource ID: $VirtualNetworkId"
}

$kql = "resources | where type =~ 'microsoft.network/privatednszones' | where toint(properties.numberOfVirtualNetworkLinks) > 0 | project id, name, resourceGroup, records = toint(properties.numberOfRecordSets)"
$zones = @(if ($Subscription) { Search-Graph -Query $kql -Subscription $Subscription } else { Search-Graph -Query $kql })
if ($ResourceGroup) { $zones = @($zones | Where-Object { $ResourceGroup -contains $_.resourceGroup }) }
$zones = @($zones | Where-Object { $_.name -like $ZoneNamePattern })
if (-not $zones.Count) { throw 'No linked private DNS zone found in the selected scope.' }

# Links to THIS VNet, per zone (live ARM read; Resource Graph only gives the counts).
$plan = foreach ($z in $zones) {
    foreach ($l in @(Invoke-Arm -Path "$($z.id)/virtualNetworkLinks" -ApiVersion $api)) {
        if ("$($l.properties.virtualNetwork.id)".TrimEnd('/') -ne $vnet) { continue }
        $action = if ($z.records -ne 1) { 'SKIP-HAS-RECORDS' }
                  elseif ($l.properties.registrationEnabled) { 'SKIP-AUTOREGISTRATION' }
                  else { 'UNLINK' }
        [pscustomobject]@{ Zone = $z.name; ZoneId = $z.id; Records = $z.records; Link = $l.name; LinkId = $l.id; Action = $action }
    }
}
$plan = @($plan)
if (-not $plan.Count) { Write-Warning "No zone in scope is linked to $vnet."; return }

$plan | Sort-Object Action, Zone | Format-Table Zone, Records, Link, Action -AutoSize | Out-String | Write-Host
$todo = @($plan | Where-Object Action -eq 'UNLINK')
$skip = @($plan | Where-Object Action -ne 'UNLINK')
Write-Host "Links to this VNet: $($plan.Count)  empty (unlink): $($todo.Count)  skipped: $($skip.Count)"
foreach ($s in $skip) { Write-Warning "SKIP $($s.Zone): $($s.Action) (records=$($s.Records))" }
if (-not $Apply) { if ($todo.Count) { Write-Host 'Report only. Re-run with -Apply to remove the empty links.' }; return }
if (-not $todo.Count) { Write-Host 'Nothing to unlink.'; return }

$submitted = @()
foreach ($t in $todo) {
    # Re-check emptiness right before the delete.
    $live = Invoke-ArmRequest -Path "$($t.ZoneId)?api-version=$api" -IgnoreNotFound
    if (-not $live) { Write-Host "SKIP (zone gone): $($t.Zone)"; continue }
    if ([int]$live.properties.numberOfRecordSets -ne 1) { Write-Warning "ABORT $($t.Zone): now holds $($live.properties.numberOfRecordSets) record sets. Not unlinked."; continue }
    if (-not $PSCmdlet.ShouldProcess("$($t.Zone) -> $($vnet.Split('/')[-1])", 'Remove virtual network link')) { continue }
    Invoke-ArmRequest -Method DELETE -Path "$($t.LinkId)?api-version=$api" | Out-Null   # 202, async
    $submitted += $t
}
if (-not $submitted.Count) { return }

Write-Host "Submitted $($submitted.Count) link delete(s). Polling..."
$deadline = (Get-Date).AddMinutes($PollMinutes)
do {
    Start-Sleep -Seconds 10
    $remaining = @($submitted | Where-Object { Invoke-ArmRequest -Path "$($_.LinkId)?api-version=$api" -IgnoreNotFound })
    Write-Host "  links still present: $($remaining.Count)"
} while ($remaining.Count -and (Get-Date) -lt $deadline)
if ($remaining.Count) { throw "$($remaining.Count) link(s) still present after $PollMinutes min: $(($remaining.Zone) -join ', ')" }
Write-Host "DONE. $($submitted.Count) empty zone(s) unlinked from $($vnet.Split('/')[-1]). Zones were not deleted."
