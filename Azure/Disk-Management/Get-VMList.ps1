Connect-AzAccount

Import-Module Az.Compute
$vms = Get-AzVM -Status

$result = foreach ($vm in $vms) {

    if ($vm.PowerState -ne "VM running") { continue }

    [PSCustomObject]@{
        VMName         = $vm.Name
        ResourceGroup  = $vm.ResourceGroupName
        Location       = $vm.Location
        OSType         = $vm.StorageProfile.OSDisk.OSType
        OperatingSystem= $vm.InstanceView.OSVersion
        PowerState     = $vm.PowerState
    }
}

$result | Sort-Object VMName
