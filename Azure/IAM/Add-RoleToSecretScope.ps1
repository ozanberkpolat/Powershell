############################################################
# App Service Managed Identity -> Key Vault Secret RBAC
############################################################

# ===== VARIABLES (BURAYI DOLDUR) =====
$subscriptionId = "SUBSCRIPTION_ID"
$appServiceResourceGroup = "APP_SERVICE_RESOURCE_GROUP"
$appServiceName = "APP_SERVICE_NAME"
$keyVaultName = "KEYVAULT_NAME"
$secretName = "SECRET_NAME"
$roleName = "Key Vault Secrets User"   # read only (istersen Secrets Officer yapabilirsin)

############################################################

Write-Host "Azure login..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop

Write-Host "Subscription context set ediliyor..." -ForegroundColor Cyan
Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

############################################################
# APP SERVICE AL + MANAGED IDENTITY ENABLE ET
############################################################

Write-Host "App Service kontrol ediliyor..." -ForegroundColor Cyan
$app = Get-AzWebApp -ResourceGroupName $appServiceResourceGroup -Name $appServiceName -ErrorAction Stop

if (-not $app.Identity -or -not $app.Identity.PrincipalId) {
    Write-Host "App Service managed identity yok -> enable ediliyor..." -ForegroundColor Yellow
    
    Set-AzWebApp `
        -ResourceGroupName $appServiceResourceGroup `
        -Name $appServiceName `
        -AssignIdentity `
        -ErrorAction Stop

    Start-Sleep -Seconds 10

    $app = Get-AzWebApp -ResourceGroupName $appServiceResourceGroup -Name $appServiceName
}

$principalId = $app.Identity.PrincipalId

if (-not $principalId) {
    throw "App Service managed identity principalId alınamadı."
}

Write-Host "App Service Managed Identity PrincipalId:" $principalId -ForegroundColor Green

############################################################
# KEY VAULT AL + RBAC MODE KONTROL
############################################################

Write-Host "Key Vault alınıyor..." -ForegroundColor Cyan
$keyVault = Get-AzKeyVault -VaultName $keyVaultName -ErrorAction Stop

if (-not $keyVault.EnableRbacAuthorization) {
    Write-Host "Key Vault RBAC mode kapalı -> açılıyor..." -ForegroundColor Yellow
    
    Update-AzKeyVault `
        -VaultName $keyVaultName `
        -EnableRbacAuthorization $true `
        -ErrorAction Stop

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
Write-Host "RBAC propagation 5-10 dakika sürebilir." -ForegroundColor Yellow