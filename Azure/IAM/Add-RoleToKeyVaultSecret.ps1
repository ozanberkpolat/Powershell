############################################################
# VM Managed Identity -> Key Vault Secret Level RBAC Test
############################################################

# ===== VARIABLES (BURAYI DOLDUR) =====
$subscriptionId = "a9d2eae1-b429-4239-8f18-c3bc7034b03d"
$vmResourceGroup = "rg-vm-prod-gwc"
$vmName = "PLMDBSRV"
$keyVaultName = "kv-ozantest2-gw"
$secretName = "topsecret"
$roleName = "Key Vault Secrets User"   # read only (istersen Secrets Officer yapabilirsin)

############################################################

Write-Host "Azure login..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop

Write-Host "Subscription context set ediliyor..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

############################################################
# VM AL + MANAGED IDENTITY ENABLE ET
############################################################

Write-Host "VM kontrol ediliyor..." -ForegroundColor Cyan
$vm = Get-AzVM -ResourceGroupName $vmResourceGroup -Name $vmName -ErrorAction Stop

if (-not $vm.Identity -or -not $vm.Identity.PrincipalId) {
    Write-Host "VM'de managed identity yok -> enable ediliyor..." -ForegroundColor Yellow
    
    Update-AzVM -ResourceGroupName $vmResourceGroup `
                -VMName $vmName `
                -IdentityType SystemAssigned `
                -ErrorAction Stop

    Start-Sleep -Seconds 10

    $vm = Get-AzVM -ResourceGroupName $vmResourceGroup -Name $vmName
}

$principalId = $vm.Identity.PrincipalId

if (-not $principalId) {
    throw "Managed identity principalId alınamadı."
}

Write-Host "VM Managed Identity PrincipalId:" $principalId -ForegroundColor Green

############################################################
# KEY VAULT AL + RBAC MODE KONTROL
############################################################

Write-Host "Key Vault alınıyor..." -ForegroundColor Cyan
$keyVault = Get-AzKeyVault -VaultName $keyVaultName -ErrorAction Stop

if (-not $keyVault.EnableRbacAuthorization) {
    Write-Host "Key Vault RBAC mode kapalı -> açılıyor..." -ForegroundColor Yellow
    
    Update-AzKeyVault -VaultName $keyVaultName -EnableRbacAuthorization $true -ErrorAction Stop
    
    Write-Host "RBAC mode açıldı. (Access policy yerine RBAC kullanılacak)" -ForegroundColor Green
}

############################################################
# SECRET SCOPE OLUŞTUR
############################################################

$scope = "$($keyVault.ResourceId)/secrets/$secretName"

Write-Host "Secret Scope:" $scope -ForegroundColor Green

############################################################
# ROLE ASSIGNMENT VAR MI KONTROL ET
############################################################

Write-Host "Mevcut role assignment kontrol ediliyor..." -ForegroundColor Cyan

$existing = Get-AzRoleAssignment `
    -ObjectId $principalId `
    -Scope $scope `
    -ErrorAction SilentlyContinue

if ($existing) {
    Write-Host "Role assignment zaten mevcut." -ForegroundColor Yellow
}
else {
    Write-Host "Secret seviyesinde RBAC veriliyor..." -ForegroundColor Cyan

    New-AzRoleAssignment `
        -ObjectId $principalId `
        -RoleDefinitionName $roleName `
        -Scope $scope `
        -ErrorAction Stop

    Write-Host "Role assignment oluşturuldu." -ForegroundColor Green
}

############################################################
# DOĞRULAMA
############################################################

Write-Host "Role assignment doğrulanıyor..." -ForegroundColor Cyan

Get-AzRoleAssignment -ObjectId $principalId |
    Where-Object { $_.Scope -like "*secrets/$secretName" } |
    Select-Object ObjectId, RoleDefinitionName, Scope

Write-Host ""
Write-Host "Tamamlandı." -ForegroundColor Green