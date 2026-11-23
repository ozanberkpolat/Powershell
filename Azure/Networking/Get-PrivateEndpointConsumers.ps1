#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Who talks to your private endpoints, and what changes if you put an NSG (or a route) on their subnets.
    Read-only: Resource Graph + Traffic Analytics.

.DESCRIPTION
    Before you enable network policies or attach an NSG to private endpoint subnets you need to know which
    sources reach the endpoints today, or the new rules cut them off. Sections:

      A. Private endpoint subnets: prefix, endpoint count, privateEndpointNetworkPolicies, NSG, route table.
      B. Private endpoints: subnet, private IP (from the endpoint NIC), group ID (blob, vault, sites ...),
         target resource and connection state.
      C. NSG rules on those subnets (when an NSG is attached).
      D. Route table routes anywhere in scope whose prefix contains or equals a PE subnet (these steer
         traffic to the endpoints through a firewall or NVA).
      E. Traffic Analytics consumers (-WorkspaceId): source IP / subnet / VM, port, flows, last seen, per PE
         subnet, over -Days. A control count of all flows in the same window is printed first: zero flows
         in the window means Traffic Analytics is not flowing, NOT that nobody uses the endpoints.
      F. Verdict per subnet: what enabling an NSG would require.

    Every section is written to CSV under -OutputFolder.

.PARAMETER Subscription
    Subscription IDs. Default: every enabled subscription you can read.
.PARAMETER Location
    Only virtual networks in this region (for example westeurope). Default: all.
.PARAMETER SubnetNamePattern
    Subnets whose name matches are included even without endpoints yet. Default '(?i)(^|[-_])pe([-_]|$)|privateendpoint'.
.PARAMETER WorkspaceId
    Log Analytics workspace customerId (GUID) that receives Traffic Analytics (NTANetAnalytics). Optional.
.PARAMETER Days
    Traffic window. Default 30. Interactive retention limits how far back this can go.
.PARAMETER OutputFolder
    Default ./pe-consumers-<timestamp>.

.EXAMPLE
    ./Azure/Networking/Get-PrivateEndpointConsumers.ps1 -Location westeurope -WorkspaceId <workspace customerId>

.EXAMPLE
    ./Azure/Networking/Get-PrivateEndpointConsumers.ps1 -Subscription $subA,$subB -Days 7

.NOTES
    Role: Reader on the subscriptions; Log Analytics Reader on the Traffic Analytics workspace.
    Modules: Az.Accounts (Resource Graph and Log Analytics through Azure/Common/Az-Helpers.ps1).
    UNTESTED: section E as one query (the source ran one query per subnet range with ipv4_is_in_range); verify the
    mv-apply attribution on a workspace with Traffic Analytics before relying on per-subnet counts.
    Traps kept from real use:
      - privateEndpointNetworkPolicies decides whether NSG rules and UDRs apply to endpoint traffic at all:
        Disabled = both ignored, NetworkSecurityGroupEnabled / RouteTableEnabled / Enabled = applied. An
        NSG on a subnet with policies Disabled gives a false sense of control.
      - A private endpoint adds a /32 system route in every peered VNet; a broader UDR does not override it
        unless RouteTableEnabled is set on the endpoint subnet. Section D lists the candidates.
      - Zero rows from Traffic Analytics is not "no consumers": check the control count and that flow logs
        (VNet flow logs with Traffic Analytics) cover the SOURCE networks; traffic from on-premises or from
        unlogged VNets is invisible.
      - Always pass a timespan to the Log Analytics API matching the query window (the helper does).
      - Customer DNS records (custom DNS configs) can be empty with private DNS zone groups; the private IP
        is read from the endpoint NIC instead.
#>
[CmdletBinding()]
param(
    [string[]]$Subscription,
    [string]$Location,
    [string]$SubnetNamePattern = '(?i)(^|[-_])pe([-_]|$)|privateendpoint',
    [string]$WorkspaceId,
    [ValidateRange(1, 90)][int]$Days = 30,
    [string]$OutputFolder = "./pe-consumers-$(Get-Date -Format yyyyMMdd-HHmmss)"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
if (-not (Get-AzContext)) { throw 'No Az context. Run Connect-AzAccount first.' }
$subs = if ($Subscription) { @($Subscription) } else { @((Get-EnabledSubscription).Id) }
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$locFilter = if ($Location) { "| where location =~ '$($Location -replace "'", "''")'" } else { '' }

function ConvertTo-Range([string]$cidr) {
    $ip, $len = $cidr.Split('/')
    $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes()
    if ($b.Count -ne 4) { return $null }   # IPv6 prefixes are not compared
    [Array]::Reverse($b)
    $n = [BitConverter]::ToUInt32($b, 0)
    $size = [uint64][Math]::Pow(2, 32 - [int]$len)
    $start = [uint64]($n - ($n % $size))
    [pscustomobject]@{ Start = $start; End = $start + $size - 1 }
}
function Test-Contains([string]$outer, [string]$inner) {
    $o = ConvertTo-Range $outer; $i = ConvertTo-Range $inner
    $o -and $i -and $o.Start -le $i.Start -and $o.End -ge $i.End
}
function Save($rows, [string]$name) { @($rows) | Export-Csv (Join-Path $OutputFolder "$name.csv") -NoTypeInformation -Encoding utf8 }

# ---- A. subnets --------------------------------------------------------------------------------------
$qA = @"
resources
| where type =~ 'microsoft.network/virtualnetworks' $locFilter
| mv-expand s = properties.subnets
| extend sn = tostring(s.name)
| extend pes = coalesce(array_length(todynamic(s.properties.privateEndpoints)), 0)
| extend pfx = iff(isnotempty(tostring(s.properties.addressPrefix)), tostring(s.properties.addressPrefix), tostring(s.properties.addressPrefixes[0]))
| extend nsgId = tostring(s.properties.networkSecurityGroup.id), rtId = tostring(s.properties.routeTable.id)
| extend policy = tostring(s.properties.privateEndpointNetworkPolicies)
| project subscriptionId, vnet = name, subnet = sn, subnetId = tolower(tostring(s.id)), prefix = pfx, endpoints = pes, policy, nsgId, rtId
"@
$subnets = @(Search-Graph -Query $qA -Subscription $subs | Where-Object { $_.endpoints -gt 0 -or $_.subnet -match $SubnetNamePattern })
if (-not $subnets.Count) { throw 'No private endpoint subnets found in scope (no subnet holds an endpoint or matches -SubnetNamePattern).' }
Write-Host "`n== A. Private endpoint subnets ($($subnets.Count))" -ForegroundColor Cyan
$subnets | Format-Table vnet, subnet, prefix, endpoints, policy, @{ n = 'nsg'; e = { if ($_.nsgId) { $_.nsgId.Split('/')[-1] } else { 'NONE' } } }, @{ n = 'routeTable'; e = { if ($_.rtId) { $_.rtId.Split('/')[-1] } else { '-' } } } -AutoSize
Save $subnets 'A-subnets'

# ---- B. endpoints ------------------------------------------------------------------------------------
$qB = @"
resources
| where type =~ 'microsoft.network/privateendpoints' $locFilter
| extend subnetId = tolower(tostring(properties.subnet.id)), nicId = tolower(tostring(properties.networkInterfaces[0].id))
| extend conns = array_concat(properties.privateLinkServiceConnections, properties.manualPrivateLinkServiceConnections)
| mv-expand c = conns
| project name, resourceGroup, subscriptionId, subnetId, nicId, groupId = tostring(c.properties.groupIds[0]),
    target = tostring(c.properties.privateLinkServiceId), state = tostring(c.properties.privateLinkServiceConnectionState.status)
"@
$qNic = @"
resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isnotempty(properties.privateEndpoint)
| mv-expand ipc = properties.ipConfigurations
| project nicId = tolower(id), ip = tostring(ipc.properties.privateIPAddress)
"@
$eps = @(Search-Graph -Query $qB -Subscription $subs)
$nicIps = @{}
foreach ($n in @(Search-Graph -Query $qNic -Subscription $subs)) { if (-not $nicIps.ContainsKey($n.nicId)) { $nicIps[$n.nicId] = @() }; $nicIps[$n.nicId] += $n.ip }
$subnetById = @{}; foreach ($s in $subnets) { $subnetById[$s.subnetId] = $s }
$epRows = @(foreach ($e in $eps | Where-Object { $subnetById.ContainsKey($_.subnetId) }) {
    $s = $subnetById[$e.subnetId]
    [pscustomobject]@{
        Vnet = $s.vnet; Subnet = $s.subnet; Endpoint = $e.name; PrivateIp = (@($nicIps[$e.nicId]) -join ',')
        GroupId = $e.groupId; TargetType = (($e.target -split '/providers/')[-1] -split '/')[0..1] -join '/'
        Target = $e.target.Split('/')[-1]; State = $e.state; ResourceGroup = $e.resourceGroup
    }
})
Write-Host "`n== B. Private endpoints ($($epRows.Count))" -ForegroundColor Cyan
$epRows | Sort-Object Vnet, Subnet, PrivateIp | Format-Table Vnet, Subnet, PrivateIp, GroupId, Target, State -AutoSize
$epRows | Group-Object GroupId | Sort-Object Count -Descending | ForEach-Object { '  {0,-20} x{1}' -f $_.Name, $_.Count }
Save $epRows 'B-endpoints'

# ---- C. NSG rules ------------------------------------------------------------------------------------
$nsgIds = @($subnets | Where-Object nsgId | ForEach-Object { $_.nsgId.ToLower() } | Sort-Object -Unique)
$ruleRows = @()
if ($nsgIds.Count) {
    $list = ($nsgIds | ForEach-Object { "'$_'" }) -join ','
    $qC = "resources | where type =~ 'microsoft.network/networksecuritygroups' | where tolower(id) in~ ($list) | mv-expand r = properties.securityRules " +
          "| project nsg = name, nsgId = tolower(id), rule = tostring(r.name), direction = tostring(r.properties.direction), priority = toint(r.properties.priority), access = tostring(r.properties.access), " +
          "src = strcat(tostring(r.properties.sourceAddressPrefix), tostring(r.properties.sourceAddressPrefixes)), dst = strcat(tostring(r.properties.destinationAddressPrefix), tostring(r.properties.destinationAddressPrefixes)), " +
          "ports = strcat(tostring(r.properties.destinationPortRange), tostring(r.properties.destinationPortRanges)), protocol = tostring(r.properties.protocol)"
    $ruleRows = @(Search-Graph -Query $qC -Subscription $subs | Sort-Object nsg, direction, priority)
}
Write-Host "`n== C. NSG rules on PE subnets ($($ruleRows.Count) custom rules; default rules not listed)" -ForegroundColor Cyan
$ruleRows | Format-Table nsg, direction, priority, access, src, dst, ports, protocol -AutoSize
Save $ruleRows 'C-nsg-rules'

# ---- D. routes that steer traffic to the PE subnets --------------------------------------------------
$qD = "resources | where type =~ 'microsoft.network/routetables' $locFilter | mv-expand r = properties.routes " +
      "| project routeTable = name, rtId = tolower(id), subscriptionId, route = tostring(r.name), prefix = tostring(r.properties.addressPrefix), nextHopType = tostring(r.properties.nextHopType), nextHop = tostring(r.properties.nextHopIpAddress), subnets = array_length(properties.subnets)"
$routes = @(Search-Graph -Query $qD -Subscription $subs | Where-Object { $_.prefix -match '^\d+\.\d+\.\d+\.\d+/\d+$' })
$routeRows = @(foreach ($s in $subnets | Where-Object { $_.prefix -match '^\d+\.\d+\.\d+\.\d+/\d+$' }) {
    foreach ($r in $routes | Where-Object { Test-Contains $_.prefix $s.prefix }) {
        [pscustomobject]@{ PeSubnet = "$($s.vnet)/$($s.subnet)"; PeSubnetPrefix = $s.prefix; RouteTable = $r.routeTable; Route = $r.route; RoutePrefix = $r.prefix; NextHopType = $r.nextHopType; NextHop = $r.nextHop; UsedBySubnets = $r.subnets }
    }
})
Write-Host "`n== D. Routes covering PE subnets ($($routeRows.Count))" -ForegroundColor Cyan
$routeRows | Format-Table PeSubnet, RouteTable, RoutePrefix, NextHopType, NextHop, UsedBySubnets -AutoSize
Save $routeRows 'D-routes'

# ---- E. Traffic Analytics consumers ------------------------------------------------------------------
$consumers = @()
$control = $null
if ($WorkspaceId) {
    $prefixes = @($subnets | Where-Object { $_.prefix -match '^\d+\.\d+\.\d+\.\d+/\d+$' } | ForEach-Object prefix | Sort-Object -Unique)
    $ts = "P$($Days)D"
    $control = @(Invoke-LaKql -WorkspaceId $WorkspaceId -Timespan $ts -Kql "NTANetAnalytics | where TimeGenerated > ago($($Days)d) | where SubType == 'FlowLog' | summarize rows = count(), last = max(TimeGenerated)")
    Write-Host "`n== E. Traffic Analytics: control count $($control[0].rows) flow rows in $Days days, last $($control[0].last)" -ForegroundColor Cyan
    if (-not $control.Count -or [int64]$control[0].rows -eq 0) {
        Write-Warning 'NTANetAnalytics has NO rows in the window: Traffic Analytics is not flowing into this workspace. The consumer list below proves nothing.'
    }
    $arr = ($prefixes | ForEach-Object { "'$_'" }) -join ','
    $kql = @"
let pe = dynamic([$arr]);
NTANetAnalytics
| where TimeGenerated > ago($($Days)d)
| where SubType == 'FlowLog'
| where ipv4_is_in_any_range(DestIp, pe)
| mv-apply p = pe to typeof(string) on (where ipv4_is_in_range(DestIp, p) | take 1 | project PeSubnetPrefix = p)
| summarize flows = sum(AllowedInFlows) + sum(DeniedInFlows) + sum(AllowedOutFlows) + sum(DeniedOutFlows), denied = sum(DeniedInFlows) + sum(DeniedOutFlows),
    destinations = dcount(DestIp), ports = make_set(DestPort, 20), lastSeen = max(FlowEndTime) by PeSubnetPrefix, SrcIp, SrcSubnet, SrcVm
| order by PeSubnetPrefix asc, flows desc
| take 2000
"@
    $consumers = @(Invoke-LaKql -WorkspaceId $WorkspaceId -Timespan $ts -Kql $kql)
    $consumers | Select-Object -First 40 | Format-Table PeSubnetPrefix, SrcIp, SrcSubnet, SrcVm, flows, denied, destinations, ports, lastSeen -AutoSize
    Save ($consumers | Select-Object PeSubnetPrefix, SrcIp, SrcSubnet, SrcVm, flows, denied, destinations, @{ n = 'ports'; e = { ($_.ports | ConvertTo-Json -Compress) } }, lastSeen) 'E-consumers'
    if ($consumers.Count -ge 2000) { Write-Warning 'Consumer list capped at 2000 rows; narrow -Days or the scope. Verdicts below may undercount.' }
} else {
    Write-Warning 'No -WorkspaceId: Traffic Analytics section skipped, so consumers are unknown and the verdict cannot say GO.'
}

# ---- F. verdict per subnet ---------------------------------------------------------------------------
$verdict = @(foreach ($s in $subnets) {
    $notes = @()
    if (-not $s.nsgId) { $notes += 'no NSG attached' }
    if ($s.policy -in '', 'Disabled') { $notes += 'network policies Disabled: an NSG/UDR would be ignored for endpoint traffic until enabled' }
    $mine = @($consumers | Where-Object { $_.PeSubnetPrefix -eq $s.prefix })
    $srcCount = $mine.Count
    $srcSubnets = @($mine | ForEach-Object { if ($_.SrcSubnet) { $_.SrcSubnet } else { $_.SrcIp } } | Sort-Object -Unique)
    $state = if (-not $WorkspaceId -or ($control -and [int64]$control[0].rows -eq 0)) { 'UNKNOWN: no traffic evidence' }
             elseif ($consumers.Count -ge 2000) { 'REVIEW: consumer list was capped, counts are incomplete' }
             elseif ($srcCount -eq 0) { 'GO (flow-log evidence only): no consumers seen in the window' }
             else { 'REVIEW: allow the sources in E before enabling an NSG' }
    [pscustomobject]@{ Vnet = $s.vnet; Subnet = $s.subnet; Prefix = $s.prefix; Endpoints = $s.endpoints; Policy = $s.policy; Nsg = $(if ($s.nsgId) { $s.nsgId.Split('/')[-1] } else { 'NONE' })
        Consumers = $srcCount; SourceSubnets = (($srcSubnets | Select-Object -First 10) -join ', '); Verdict = $state; Notes = ($notes -join '; ') }
})
Write-Host "`n== F. Verdict" -ForegroundColor Cyan
$verdict | Format-Table Vnet, Subnet, Endpoints, Policy, Nsg, Consumers, Verdict, Notes -AutoSize -Wrap
Save $verdict 'F-verdict'
Write-Host "CSV files: $OutputFolder" -ForegroundColor Cyan
