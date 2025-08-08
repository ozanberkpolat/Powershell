Connect-GunAzAccount  

#$Subscriptions = ( Get-AzSubscription -WarningAction SilentlyContinue | Where-Object {$_.Name -like 'Gunvor-*'} )  

$Subscriptions = Get-AzSubscription -SubscriptionName Gunvor-DataEng-Prod -WarningAction SilentlyContinue  

   

$output = @()  

   

foreach ($Subscription in $Subscriptions) {  

    Set-AzContext -Tenant 11980ae3-cae6-4552-94d2-5ad474856f9e -Subscription $Subscription.Id -WarningAction SilentlyContinue | Out-Null  

   

    $vms = Get-AzVM  

    $vms | Format-Table -auto  

    foreach($vm in $vms) {  

        $item = [PSCustomObject]@{  

            Name = $vm.Name  

            ResourceGroup = $vm.ResourceGroupName  

            VmSize = $vm.HardwareProfile.VmSize  

            Location = $vm.Location  

            LicenseType = $vm.LicenseType  

        }  

   

        $output += $item  

        $item  

    }  

}  

   

$output | Format-Table -auto  