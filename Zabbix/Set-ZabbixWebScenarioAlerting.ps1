#Requires -Version 5.1
<#
.SYNOPSIS
    Makes a Zabbix web scenario able to raise a problem: required HTTP status code, tags and a High trigger on repeated failure.

.DESCRIPTION
    A web scenario created in the UI records results but does not alert. Two stages:
      Scenario: sets `status_codes` (default 200) on every step, merges tags into the scenario and optionally turns
                SSL peer/host verification on (-VerifySsl).
      Trigger:  creates `min(/<host>/web.test.fail[<scenario>],#N)>0` at priority High. web.test.fail is 0 when the
                scenario passes and the failed step number otherwise, so a minimum above 0 over N checks means N
                failed runs in a row.

    Safety rules kept from production use
      * httptest.update REPLACES the steps, so every existing step field is read and sent back with the status code added.
      * Tags are merged with the existing ones (an update replaces the whole list otherwise).
      * The Trigger stage REFUSES unless the last 3 stored values of the fail item are all 0, otherwise the trigger
        would fire the moment it is created (check failing, or too little history).
      * web scenario items are type 9; item.get needs `webitems = true` to see them.
      * -VerifySsl is separate on purpose: a poller behind SSL inspection fails verification. Watch a few runs first.
      * Evidence JSON before and after.

    Creating or updating asks for confirmation (ConfirmImpact High). Use -WhatIf to preview.

.PARAMETER HostName
    Zabbix technical host name that owns the scenario.

.PARAMETER ScenarioName
    Web scenario name, exactly as in Zabbix.

.PARAMETER Stage
    Scenario or Trigger.

.PARAMETER StatusCodes
    Required status codes per step. Default 200. Zabbix syntax allows ranges, for example 200-299.

.PARAMETER Tag
    Tags to add to the scenario and trigger as hashtable. Default @{ check = 'web-availability' }.

.PARAMETER ConsecutiveFailures
    Failed runs in a row before the trigger fires. Default 3.

.PARAMETER TriggerName
    Trigger description. Default "<ScenarioName>: web check is failing (N consecutive failed runs)".

.PARAMETER VerifySsl
    Scenario stage: also set verify_peer and verify_host to 1.

.PARAMETER EvidenceDir
    Folder for before/after JSON. Default .\evidence.

.EXAMPLE
    .\Set-ZabbixWebScenarioAlerting.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -HostName web-www -ScenarioName 'https://www.contoso.com' -Stage Scenario -WhatIf

.EXAMPLE
    .\Set-ZabbixWebScenarioAlerting.ps1 -Url https://zabbix.contoso.com -TokenFile C:\secure\zabbix.token -HostName web-www -ScenarioName 'https://www.contoso.com' -Stage Trigger

.NOTES
    WRITES to Zabbix (httptest.update, trigger.create). The API token needs write access to the host. Port of a
    two-stage Python script. Scenario names containing quotes or commas make the item key hard to embed in an
    expression; rename such scenarios first.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][string]$ScenarioName,
    [Parameter(Mandatory)][ValidateSet('Scenario', 'Trigger')][string]$Stage,
    [string]$StatusCodes = '200',
    [hashtable]$Tag = @{ check = 'web-availability' },
    [ValidateRange(1, 100)][int]$ConsecutiveFailures = 3,
    [string]$TriggerName,
    [switch]$VerifySsl,
    [string]$EvidenceDir = (Join-Path (Get-Location) 'evidence'),
    [string]$Url,
    [string]$TokenFile,
    [securestring]$Token
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-ZabbixApi.ps1')
Connect-ZabbixApi -Url $Url -TokenFile $TokenFile -Token $Token

$priorityHigh = 4
if (-not $TriggerName) { $TriggerName = "${ScenarioName}: web check is failing ($ConsecutiveFailures consecutive failed runs)" }

function Get-Scenario {
    $h = (Invoke-ZabbixApi -Method host.get -Params @{ filter = @{ host = @($HostName) }; output = @('hostid', 'host') })[0]
    $t = Invoke-ZabbixApi -Method httptest.get -Params @{ hostids = $h.hostid; filter = @{ name = $ScenarioName }; output = 'extend'; selectSteps = 'extend'; selectTags = 'extend' }
    if ($t.Count -ne 1) { throw "Expected one web scenario '$ScenarioName' on $HostName, found $($t.Count)." }
    $h, $t[0]
}
$hostRow, $scenario = Get-Scenario
Write-Host ("Evidence (before): " + (Save-ZabbixEvidence -Name "webscenario-$Stage-before" -Object $scenario -Dir $EvidenceDir))

if ($Stage -eq 'Scenario') {
    # Resend every step field; steps are replaced, not merged.
    $steps = @($scenario.steps | ForEach-Object {
        $s = @{}
        foreach ($f in 'name', 'url', 'timeout', 'follow_redirects', 'required', 'posts', 'no') { $s[$f] = $_.$f }
        $s['status_codes'] = $StatusCodes
        $s
    })
    $tags = @($scenario.tags | ForEach-Object { @{ tag = $_.tag; value = $_.value } })
    foreach ($k in $Tag.Keys) {
        if (-not ($tags | Where-Object { $_.tag -eq [string]$k -and $_.value -eq [string]$Tag[$k] })) { $tags += @{ tag = [string]$k; value = [string]$Tag[$k] } }
    }
    $change = @{ httptestid = $scenario.httptestid; steps = $steps; tags = $tags }
    if ($VerifySsl) { $change['verify_peer'] = '1'; $change['verify_host'] = '1' }
    $sslNote = if ($VerifySsl) { 'verify_peer/host -> 1' } else { 'SSL verification unchanged' }
    Write-Host "~ scenario '$($scenario.name)': status_codes -> $StatusCodes, $($tags.Count) tag(s), $sslNote"
    if ($PSCmdlet.ShouldProcess("$HostName / $ScenarioName", 'update web scenario (status codes, tags)')) {
        [void](Invoke-ZabbixApi -Method httptest.update -Params $change -AllowEmpty)
    }
} else {
    $failItems = Invoke-ZabbixApi -Method item.get -Params @{ hostids = $hostRow.hostid; webitems = $true; search = @{ key_ = "web.test.fail[$ScenarioName]" }; output = @('itemid', 'key_', 'lastvalue') }
    if ($failItems.Count -ne 1) { throw "Expected one web.test.fail item for '$ScenarioName', found: $(($failItems | ForEach-Object { $_.key_ }) -join ', ')" }
    $item = $failItems[0]
    $hist = @(Invoke-ZabbixApi -Method history.get -AllowEmpty -Params @{ itemids = $item.itemid; history = 3; sortfield = 'clock'; sortorder = 'DESC'; limit = 3; output = 'extend' })
    $values = @($hist | ForEach-Object { $_.value })
    Write-Host "$($item.key_) last values: $($values -join ', ')"
    if ($values.Count -lt 3 -or @($values | Where-Object { $_ -ne '0' }).Count -gt 0) {
        throw 'REFUSED: the check is failing or has too little history (needs 3 stored values, all 0); the trigger would fire on create. Fix the scenario or wait for history.'
    }
    $existing = @(Invoke-ZabbixApi -Method trigger.get -AllowEmpty -Params @{ hostids = $hostRow.hostid; filter = @{ description = $TriggerName }; output = @('triggerid') })
    if ($existing.Count -gt 0) { Write-Host '= trigger already exists'; return }
    $tags = @($Tag.Keys | ForEach-Object { @{ tag = [string]$_; value = [string]$Tag[$_] } })
    $trigger = @{
        description = $TriggerName
        expression  = "min(/$($hostRow.host)/$($item.key_),#$ConsecutiveFailures)>0"
        priority    = $priorityHigh
        tags        = $tags
        comments    = "Web scenario requires status $StatusCodes; fires after $ConsecutiveFailures failed runs in a row."
    }
    Write-Host "+ trigger: $($trigger.expression) (High)"
    if ($PSCmdlet.ShouldProcess("$HostName / $ScenarioName", 'create High trigger')) {
        [void](Invoke-ZabbixApi -Method trigger.create -Params @($trigger) -AllowEmpty)
    }
}

if (-not $WhatIfPreference) {
    $h2, $after = Get-Scenario
    $trig = Invoke-ZabbixApi -Method trigger.get -AllowEmpty -Params @{ hostids = $h2.hostid; output = 'extend'; selectTags = 'extend' }
    Write-Host ("Evidence (after): " + (Save-ZabbixEvidence -Name "webscenario-$Stage-after" -Object @{ httptest = $after; triggers = $trig } -Dir $EvidenceDir))
}
