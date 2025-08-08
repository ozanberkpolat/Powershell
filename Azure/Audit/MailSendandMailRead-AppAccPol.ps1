# Connect to Graph and Exchange Online
Import-Module Microsoft.Graph
Import-Module ExchangeOnlineManagement
Connect-MgGraph -Scopes "Application.Read.All"
Connect-ExchangeOnline

# Permission IDs

# Mail.Send
$mailSendDelegatedId = "e383f46e-2787-4529-855e-0e479a3ffac0"
$mailSendApplicationId = "b633e1c5-b582-4048-a93e-9f11b44c7e96"

# Mail.Read
$mailReadDelegatedId = "570282fd-fa5c-430d-a7fd-fc8dc98a9dca"
$mailReadApplicationId = "64e1323f-f55e-4e3d-9c72-59734e4c4d70"

# Get all app access policies
$appAccessPolicies = Get-ApplicationAccessPolicy
$allowedAppIds = $appAccessPolicies | Select-Object -ExpandProperty AppId

# Get all app registrations
$appRegs = Get-MgApplication -All -Property "id,displayName,appId,createdDateTime,requiredResourceAccess"

$result = @()

foreach ($app in $appRegs) {
    $hasMailSend = $false
    $hasMailRead = $false

    $permissionTypes = @()

    foreach ($rra in $app.RequiredResourceAccess) {
        foreach ($res in $rra.ResourceAccess) {
            switch ($res.Id.ToString()) {
                $mailSendDelegatedId {
                    $hasMailSend = $true
                    if (-not $permissionTypes.Contains("Delegated")) { $permissionTypes += "Delegated" }
                }
                $mailSendApplicationId {
                    $hasMailSend = $true
                    if (-not $permissionTypes.Contains("Application")) { $permissionTypes += "Application" }
                }
                $mailReadDelegatedId {
                    $hasMailRead = $true
                    if (-not $permissionTypes.Contains("Delegated")) { $permissionTypes += "Delegated" }
                }
                $mailReadApplicationId {
                    $hasMailRead = $true
                    if (-not $permissionTypes.Contains("Application")) { $permissionTypes += "Application" }
                }
            }
        }
    }

    if ($hasMailSend -or $hasMailRead) {
        $isPolicyProtected = $allowedAppIds -contains $app.AppId

        $result += [PSCustomObject]@{
            AppDisplayName    = $app.DisplayName
            AppId             = $app.AppId
            CreatedDateTime   = $app.CreatedDateTime
            HasMailSend       = $hasMailSend
            HasMailRead       = $hasMailRead
            PermissionType    = ($permissionTypes -join ", ")
            IsPolicyProtected = if ($isPolicyProtected) { "Yes" } else { "No" }
        }
    }
}

# Export to CSV
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputPath = "D:\OBP\Audit Results\AppReg_MailPerms_$timestamp.csv"
$result | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
Write-Host "Exported to $outputPath"
