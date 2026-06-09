Connect-AzAccount | Out-Null
Set-AzContext -SubscriptionId $env:AZURE_SUBSCRIPTION_ID | Out-Null

$RgName     = "RG-ISBANKAG-DRTEST-GW"
$Location   = "germanywestcentral"
$NewDiskSku = "Premium_LRS" 

$snapshots = Get-AzSnapshot -ResourceGroupName $RgName | Where-Object Name -like "ss-*"

if (-not $snapshots) {
    Write-Host "No snapshots starting with 'ss-' found in RG: $RgName"
    return
}

Write-Host "Found $($snapshots.Count) snapshots. Creating disks..."
Write-Host ""

foreach ($snap in $snapshots) {

    $diskName = $snap.Name -replace '^ss-','disk-'

    Write-Host "==> Snapshot: $($snap.Name)"
    Write-Host "    Disk    : $diskName"

    $existingDisk = Get-AzDisk -ResourceGroupName $RgName -DiskName $diskName -ErrorAction SilentlyContinue
    if ($existingDisk) {
        Write-Host "    SKIP (disk exists)"
        continue
    }

    $diskCfg = New-AzDiskConfig `
        -Location $Location `
        -NetworkAccessPolicy DenyAll `
        -PublicNetworkAccess Disabled `
        -CreateOption Copy `
        -SourceResourceId $snap.Id

    if ($NewDiskSku -and $NewDiskSku -ne "") {
        $diskCfg.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new($NewDiskSku)
    }

    New-AzDisk `
        -ResourceGroupName $RgName `
        -DiskName $diskName `
        -Disk $diskCfg `
        -ErrorAction Stop | Out-Null

    Write-Host "    OK (disk created)"
}

Write-Host ""
Write-Host "Done."
