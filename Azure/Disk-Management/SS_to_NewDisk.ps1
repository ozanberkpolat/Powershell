# --- Login / context ---
Connect-AzAccount | Out-Null
Set-AzContext -SubscriptionId "90992e51-523b-431a-92ce-76828ffb7957" | Out-Null

# --- Settings ---
$RgName     = "RG-ISBANKAG-DRTEST-GW"
$Location   = "germanywestcentral"
$NewDiskSku = "Premium_LRS"   # "" yaparsan override etmez

# --- Snapshot'ları al (ss- ile başlayanlar) ---
$snapshots = Get-AzSnapshot -ResourceGroupName $RgName | Where-Object Name -like "ss-*"

if (-not $snapshots) {
    Write-Host "No snapshots starting with 'ss-' found in RG: $RgName"
    return
}

Write-Host "Found $($snapshots.Count) snapshots. Creating disks..."
Write-Host ""

foreach ($snap in $snapshots) {

    # Disk adı: ss- → disk-
    $diskName = $snap.Name -replace '^ss-','disk-'

    Write-Host "==> Snapshot: $($snap.Name)"
    Write-Host "    Disk    : $diskName"

    # Disk varsa geç
    $existingDisk = Get-AzDisk -ResourceGroupName $RgName -DiskName $diskName -ErrorAction SilentlyContinue
    if ($existingDisk) {
        Write-Host "    SKIP (disk exists)"
        continue
    }

    # Disk config
    $diskCfg = New-AzDiskConfig `
        -Location $Location `
        -NetworkAccessPolicy DenyAll `
        -PublicNetworkAccess Disabled `
        -CreateOption Copy `
        -SourceResourceId $snap.Id

    if ($NewDiskSku -and $NewDiskSku -ne "") {
        $diskCfg.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new($NewDiskSku)
    }

    # Disk oluştur
    New-AzDisk `
        -ResourceGroupName $RgName `
        -DiskName $diskName `
        -Disk $diskCfg `
        -ErrorAction Stop | Out-Null

    Write-Host "    OK (disk created)"
}

Write-Host ""
Write-Host "Done."
