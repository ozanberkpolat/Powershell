#Requires -Version 7.0
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    List and delete managed Run Command resources on VMs (25 per VM limit).

.DESCRIPTION
    Every managed Run Command (PUT .../runCommands/<name>, or az vm run-command create) is a
    resource that stays on the VM until deleted. A VM holds at most 25. At the limit Azure refuses a
    new one, and it also refuses to overwrite an existing name (the update fails with 400), so the
    only way forward is to delete old ones.

    Without a selector the script only reports, per VM, how many run commands exist (n/25) with state
    and end time. Deletion needs a selector (-NamePattern, -OlderThanDays, or both) and is guarded
    by ShouldProcess, so -WhatIf shows exactly what would go.

    Resources you must not touch (for example the ones that document an approved change) are kept with
    -ExcludePattern.

.PARAMETER VmName
    VM names (resolved with Resource Graph across readable subscriptions). Or use -ResourceId, or
    -ResourceGroup alone to take every VM in that group.
.PARAMETER ResourceId
    Full VM resource IDs.
.PARAMETER ResourceGroup
    Narrows -VmName, or selects every VM in the group when no name is given.
.PARAMETER NamePattern
    Wildcard on the run command name, for example 'rc-*' or 'myproject-*'. Delete only matches.
.PARAMETER ExcludePattern
    Wildcards that are never deleted.
.PARAMETER OlderThanDays
    Delete only commands whose last execution ended more than N days ago. Commands with no end time are
    never selected by age alone.

.EXAMPLE
    ./Remove-StaleRunCommands.ps1 -VmName vm-db-01          # report only

.EXAMPLE
    ./Remove-StaleRunCommands.ps1 -VmName vm-db-01 -NamePattern 'rc-*' -OlderThanDays 7 -WhatIf

.EXAMPLE
    ./Remove-StaleRunCommands.ps1 -ResourceGroup rg-app -OlderThanDays 30 -ExcludePattern 'change-*' -Confirm:$false

.NOTES
    Role: Virtual Machine Contributor (Microsoft.Compute/virtualMachines/runCommands/read and delete).
    Deleting is a write: activate PIM first. Deleting the resource does not undo what the script did on the VM.
    Save the output you still need (Invoke-VmRunCommand.ps1 already stores it in an evidence folder)
    before you delete, because the instance view goes with the resource.
    Legacy (non-managed) Run Command invocations leave nothing behind and are not counted.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
param(
    [Parameter(ParameterSetName = 'ByName')][string[]]$VmName,
    [Parameter(ParameterSetName = 'ByName')][string]$ResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'ById')][string[]]$ResourceId,
    [string]$NamePattern,
    [string[]]$ExcludePattern = @(),
    [int]$OlderThanDays = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Common/Az-Helpers.ps1')
$api = '2024-07-01'
$limit = 25

$kql = "resources | where type =~ 'microsoft.compute/virtualmachines'"
if ($PSCmdlet.ParameterSetName -eq 'ById') {
    $kql += " | where id in~ (" + (($ResourceId | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")"
} else {
    if ($VmName) { $kql += " | where name in~ (" + (($VmName | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")" }
    if ($ResourceGroup) { $kql += " | where resourceGroup =~ '" + ($ResourceGroup -replace "'", "''") + "'" }
    if (-not $VmName -and -not $ResourceGroup) { throw 'Pass -VmName, -ResourceId or -ResourceGroup.' }
}
$vms = @(Search-Graph -Query "$kql | project id, name, resourceGroup")
if (-not $vms.Count) { throw 'No VM matched the selection.' }

$deleting = [bool]($NamePattern -or $OlderThanDays -gt 0)
$cutoff = if ($OlderThanDays -gt 0) { (Get-Date).ToUniversalTime().AddDays(-$OlderThanDays) } else { $null }
$report = @(); $failed = 0

foreach ($vm in $vms) {
    $items = @(Invoke-Arm -Path "$($vm.id)/runCommands" -ApiVersion $api -MinWaitSeconds 5 | Where-Object { $_ })
    # The list call does not return the instance view; expand per item only when age matters.
    foreach ($rc in $items) {
        $end = $null
        if ($cutoff) {
            $one = Invoke-ArmRequest -Path "$($vm.id)/runCommands/$($rc.name)?`$expand=instanceView&api-version=$api"
            $end = $one.properties.instanceView.endTime
        }
        $match = $deleting
        if ($NamePattern -and $rc.name -notlike $NamePattern) { $match = $false }
        if ($cutoff -and (-not $end -or ([datetime]$end).ToUniversalTime() -gt $cutoff)) { $match = $false }
        foreach ($x in $ExcludePattern) { if ($rc.name -like $x) { $match = $false } }
        $report += [pscustomobject]@{ Vm = $vm.name; RunCommand = $rc.name; State = $rc.properties.provisioningState; EndTime = $end; Selected = $match; Count = "$($items.Count)/$limit" }
        if ($match -and $PSCmdlet.ShouldProcess("$($vm.name)/$($rc.name)", 'Delete managed run command')) {
            try {
                [void](Invoke-ArmRequest -Method DELETE -Path "$($vm.id)/runCommands/$($rc.name)?api-version=$api")
                Write-Host "Deleted $($vm.name)/$($rc.name)" -ForegroundColor Yellow
            } catch { $failed++; Write-Warning "Delete failed for $($vm.name)/$($rc.name): $_" }
        }
    }
    if (-not $items.Count) { Write-Host "$($vm.name): 0/$limit managed run commands" }
}

$report | Format-Table Vm, RunCommand, State, EndTime, Selected, Count -AutoSize
$report | Group-Object Vm | ForEach-Object { Write-Host ("{0}: {1}/{2} managed run commands" -f $_.Name, $_.Count, $limit) }
if (-not $deleting) { Write-Host 'Report only. Add -NamePattern and/or -OlderThanDays to select deletions (use -WhatIf first).' }
if ($deleting -and -not @($report | Where-Object Selected).Count) { Write-Warning 'The selector matched nothing; nothing to delete.' }
if ($failed) { throw "$failed delete(s) failed." }
