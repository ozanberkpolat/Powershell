Connect-AzAccount

$subscriptions = @(
    "90992e51-523b-431a-92ce-76828ffb7957",
    "d3a1c6d4-b44d-4763-811e-cb2ba1ef7f5b",
    "daecf2a9-4ad0-41a5-8d24-be2f3e4ab637"          # ← bunu ekle
)

$results = @()

foreach ($subId in $subscriptions) {
    Set-AzContext -SubscriptionId $subId | Out-Null
    Write-Host "Subscription: $subId" -ForegroundColor Cyan

    $vms = Get-AzVM | Where-Object {
        $_.SecurityProfile.SecurityType -eq "TrustedLaunch" -and
        $_.SecurityProfile.UefiSettings.SecureBootEnabled -eq $true
    }

    if (-not $vms) {
        Write-Host "  Etkilenen VM yok." -ForegroundColor Green
        continue
    }

    foreach ($vm in $vms) {
        Write-Host "  Checking: $($vm.Name)"
        try {
            $output = Invoke-AzVMRunCommand `
                -ResourceGroupName $vm.ResourceGroupName `
                -VMName $vm.Name `
                -CommandId "RunPowerShellScript" `
                -ScriptString 'Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -Name UEFICA2023Status -EA SilentlyContinue | Select-Object -ExpandProperty UEFICA2023Status'

            $status = $output.Value[0].Message.Trim()
            if (-not $status) { $status = "Key not found" }
        }
        catch {
            $status = "Run Command failed: $_"
        }

        $results += [PSCustomObject]@{
            Subscription = $subId
            VM           = $vm.Name
            RG           = $vm.ResourceGroupName
            Location     = $vm.Location
            Status       = $status
        }
    }
}

# Ekrana yaz
$results | Format-Table -AutoSize

# CSV'ye aktar
$results | Export-Csv -Path "SecureBootStatus_$(Get-Date -Format 'yyyyMMdd').csv" `
           -NoTypeInformation -Encoding UTF8

Write-Host "CSV kaydedildi: SecureBootStatus_$(Get-Date -Format 'yyyyMMdd').csv" -ForegroundColor Yellow