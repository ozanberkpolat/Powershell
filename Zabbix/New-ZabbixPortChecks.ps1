#Requires -Version 5.1
<#
.SYNOPSIS
    Creates net.tcp.listen items and "port is not listening" High triggers on one Zabbix host, in two safe stages.

.DESCRIPTION
    Stage Items:    one `net.tcp.listen[<port>]` item per port (active agent by default, 1m, unsigned integer).
    Stage Triggers: one trigger per port, `max(/<host>/net.tcp.listen[<port>],#N)=0`, priority High (4).

    Safety rules kept from production use
      * Two stages, items first. A trigger created before its item has reported fires immediately.
      * The Triggers stage REFUSES unless every port item has reported (lastclock <> 0) and currently shows 1. This
        check runs even under -WhatIf, because it is read-only and the answer decides whether creating is safe.
      * Idempotent: existing items and triggers (by key / description) are skipped, never duplicated.
      * Evidence: the host's items before the change and items + triggers after it are saved as JSON.
      * The trigger expression uses the technical host name (`host`), not the visible name.

    Creating objects asks for confirmation (ConfirmImpact High). Use -WhatIf to preview, -Confirm:$false to run unattended.

.PARAMETER HostName
    Zabbix technical host name.

.PARAMETER Port
    TCP ports to check.

.PARAMETER Stage
    Items or Triggers.

.PARAMETER Label
    Prefix for item and trigger names, for example the application name. Items: "<Label>: Port 443 is listening".

.PARAMETER ConsecutiveChecks
    The trigger fires after this many consecutive zero values. Default 3 (about 3 minutes at a 1m interval).

.PARAMETER Interval
    Item update interval. Default 1m.

.PARAMETER Passive
    Create passive agent items (type 0) instead of active (type 7).

.PARAMETER Tag
    Extra tags as hashtable, added to items and triggers next to check=port-listen. Example: @{ service = 'billing' }.

.PARAMETER EvidenceDir
    Folder for the before/after JSON. Default .\evidence.

.EXAMPLE
    .\New-ZabbixPortChecks.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -HostName APP01 -Port 8443,9000 -Stage Items -Label App -WhatIf

.EXAMPLE
    .\New-ZabbixPortChecks.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -HostName APP01 -Port 8443,9000 -Stage Triggers -Label App

.NOTES
    WRITES to Zabbix (item.create, trigger.create). The API token needs a role with write access to the host
    (Admin user type with read-write permission on the host group). Port of a two-stage Python script.
    Item type constants: 0 Zabbix agent (passive), 7 Zabbix agent (active). value_type 3 = numeric unsigned.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][ValidateRange(1, 65535)][int[]]$Port,
    [Parameter(Mandatory)][ValidateSet('Items', 'Triggers')][string]$Stage,
    [string]$Label = 'Service',
    [ValidateRange(1, 100)][int]$ConsecutiveChecks = 3,
    [string]$Interval = '1m',
    [switch]$Passive,
    [hashtable]$Tag = @{},
    [string]$EvidenceDir = (Join-Path (Get-Location) 'evidence'),
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

$priorityHigh = 4
$itemType = if ($Passive) { 0 } else { 7 }
$Port = @($Port | Sort-Object -Unique)
function Get-Key([int]$p) { "net.tcp.listen[$p]" }
function Get-TagList([int]$p, [bool]$withPort) {
    $t = @(@{ tag = 'check'; value = 'port-listen' })
    if ($withPort) { $t += @{ tag = 'port'; value = [string]$p } }
    foreach ($k in $Tag.Keys) { $t += @{ tag = [string]$k; value = [string]$Tag[$k] } }
    , $t
}
function Get-PortItems([string]$HostId) {
    Invoke-ZabbixApi -Method item.get -AllowEmpty -Params @{ hostids = $HostId; filter = @{ key_ = @($Port | ForEach-Object { Get-Key $_ }) }; output = @('itemid', 'key_', 'lastvalue', 'lastclock') }
}

$hostRow = (Invoke-ZabbixApi -Method host.get -Params @{ filter = @{ host = @($HostName) }; output = @('hostid', 'host') })[0]
$hostId = [string]$hostRow.hostid
Write-Host ("Evidence (before): " + (Save-ZabbixEvidence -Name "portchecks-$Stage-before" -Object (Get-PortItems $hostId) -Dir $EvidenceDir))

if ($Stage -eq 'Items') {
    $have = @(Get-PortItems $hostId | ForEach-Object { $_.key_ })
    $new = @($Port | Where-Object { $have -notcontains (Get-Key $_) } | ForEach-Object {
        @{ hostid = $hostId; name = "${Label}: Port $_ is listening"; key_ = (Get-Key $_); type = $itemType; value_type = 3; delay = $Interval; tags = (Get-TagList $_ $true) }
    })
    if ($new.Count -eq 0) { Write-Host '= all items exist'; return }
    foreach ($i in $new) { Write-Host "+ item $($i.key_)" }
    if ($PSCmdlet.ShouldProcess("host $HostName", "create $($new.Count) net.tcp.listen item(s)")) {
        [void](Invoke-ZabbixApi -Method item.create -Params $new -AllowEmpty)
    }
} else {
    $items = @(Get-PortItems $hostId)
    $byKey = @{}; foreach ($i in $items) { $byKey[[string]$i.key_] = $i }
    $notReady = @()
    foreach ($p in $Port) {
        $i = $byKey[(Get-Key $p)]
        Write-Host ('{0}: lastvalue={1} lastclock={2}' -f (Get-Key $p), $(if ($i) { $i.lastvalue } else { 'MISSING' }), $(if ($i) { $i.lastclock } else { '-' }))
        if (-not $i -or $i.lastclock -eq '0' -or $i.lastvalue -ne '1') { $notReady += $p }
    }
    if ($notReady.Count -gt 0) {
        throw "REFUSED: port(s) $($notReady -join ', ') are not reporting 1 yet (item missing, never ran, or not listening); the trigger(s) would fire on create. Run the Items stage, wait for a check, and confirm the service listens."
    }
    $existing = @((Invoke-ZabbixApi -Method trigger.get -AllowEmpty -Params @{ hostids = $hostId; output = @('description') }) | ForEach-Object { $_.description })
    $new = @($Port | Where-Object { $existing -notcontains "${Label}: Port $_ is not listening" } | ForEach-Object {
        @{ description = "${Label}: Port $_ is not listening"
           expression = "max(/$($hostRow.host)/$(Get-Key $_),#$ConsecutiveChecks)=0"
           priority = $priorityHigh
           tags = (Get-TagList $_ $false)
           comments = "Fires after $ConsecutiveChecks consecutive checks without a listener on TCP port $_." }
    })
    if ($new.Count -eq 0) { Write-Host '= all triggers exist'; return }
    foreach ($t in $new) { Write-Host "+ trigger $($t.expression) (High)" }
    if ($PSCmdlet.ShouldProcess("host $HostName", "create $($new.Count) trigger(s)")) {
        [void](Invoke-ZabbixApi -Method trigger.create -Params $new -AllowEmpty)
    }
}

if (-not $WhatIfPreference) {
    $after = @{
        items    = Get-PortItems $hostId
        triggers = Invoke-ZabbixApi -Method trigger.get -AllowEmpty -Params @{ hostids = $hostId; search = @{ description = "${Label}: Port" }; output = 'extend'; selectTags = 'extend' }
    }
    Write-Host ("Evidence (after): " + (Save-ZabbixEvidence -Name "portchecks-$Stage-after" -Object $after -Dir $EvidenceDir))
}
