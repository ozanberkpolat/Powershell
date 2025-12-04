# Input bindings are passed in via param block.
param($Timer)

### VARIABLES ###

# Connect to Graph using Managed Identity
Connect-MgGraph -Identity

# Check Connection
$Context = Get-MgContext
if (-not $Context) {
    throw "Not connected to Microsoft Graph. Exiting."
}

Write-Output "Connected as: $($Context.Account)"

# Variables
$E5SKUName = "SPE_E5"
$E3SKUName = "SPE_E3"
$EntraIDSKUName = "AAD_PREMIUM_P2"
$O365MGEOSKUName = "OFFICE365_MULTIGEO"
$LowerThreshold = 7

# Get all subscribed SKUs
$Cloud_SKUs = Get-MgSubscribedSku -All

if (-not $Cloud_SKUs) {
    throw "No SKUs found. Possible permission issue or no available licenses in tenant."
}

# Helper function to safely calculate available licenses
function Get-AvailableLicenseCount {
    param(
        [string]$SkuName
    )
    $sku = $Cloud_SKUs | Where-Object { $_.SkuPartNumber -eq $SkuName }
    if ($sku) {
        return $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
    } else {
        Write-Output "WARNING: SKU $SkuName not found."
        return 0
    }
}

# Calculate available licenses
$E5_AvLicsCount = Get-AvailableLicenseCount -SkuName $E5SKUName
Write-Output "  # [ $E5SKUName ] licenses currently available [ $E5_AvLicsCount ]."

$E3_AvLicsCount = Get-AvailableLicenseCount -SkuName $E3SKUName
Write-Output "  # [ $E3SKUName ] licenses currently available [ $E3_AvLicsCount ]."

$EntraID_AvLicsCount = Get-AvailableLicenseCount -SkuName $EntraIDSKUName
Write-Output "  # [ $EntraIDSKUName ] licenses currently available [ $EntraID_AvLicsCount ]."

$O365MGEO_AvLicsCount = Get-AvailableLicenseCount -SkuName $O365MGEOSKUName
Write-Output "  # [ $O365MGEOSKUName ] licenses currently available [ $O365MGEO_AvLicsCount ]."

### MAIL BODY ###

$body = @"
<div style='font-family: Arial, sans-serif; color: #333; line-height: 1.6;'>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        <strong>Hello,</strong>
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        We wanted to inform you that currently, there are <strong>$E5_AvLicsCount</strong> E5 licenses available. Please consider increasing the available license count to avoid potential interruptions in the new-joiner process.
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        To review current license assignments, kindly visit the <a href="https://admin.microsoft.com/Adminportal/Home?#/licenses" style='color: #0078D4; text-decoration: none;'>M365 Admin Center</a>.
    </p>
    <p style='font-size: 16px;'>
        Thank you for your attention to this matter.
    </p>
</div>
"@

$body2 = @"
<div style='font-family: Arial, sans-serif; color: #333; line-height: 1.6;'>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        <strong>Hello,</strong>
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        We wanted to inform you that currently, there are <strong>$E3_AvLicsCount</strong> E3 licenses available.
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        To review current license assignments, kindly visit the <a href="https://admin.microsoft.com/Adminportal/Home?#/licenses" style='color: #0078D4; text-decoration: none;'>M365 Admin Center</a>.
    </p>
    <p style='font-size: 16px;'>
        Thank you for your attention to this matter.
    </p>
</div>
"@

$body3 = @"
<div style='font-family: Arial, sans-serif; color: #333; line-height: 1.6;'>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        <strong>Hello,</strong>
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        We wanted to inform you that currently, there are <strong>$EntraID_AvLicsCount</strong> Microsoft Entra ID P2 licenses available.
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        To review current license assignments, kindly visit the <a href="https://admin.microsoft.com/Adminportal/Home?#/licenses" style='color: #0078D4; text-decoration: none;'>M365 Admin Center</a>.
    </p>
    <p style='font-size: 16px;'>
        Thank you for your attention to this matter.
    </p>
</div>
"@

$body4 = @"
<div style='font-family: Arial, sans-serif; color: #333; line-height: 1.6;'>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        <strong>Hello,</strong>
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        We wanted to inform you that currently, there are <strong>$O365MGEO_AvLicsCount</strong> Multi-Geo Capabilities in Office 365 licenses available.
    </p>
    <p style='font-size: 16px; margin-bottom: 20px;'>
        To review current license assignments, kindly visit the <a href="https://admin.microsoft.com/Adminportal/Home?#/licenses" style='color: #0078D4; text-decoration: none;'>M365 Admin Center</a>.
    </p>
    <p style='font-size: 16px;'>
        Thank you for your attention to this matter.
    </p>
</div>
"@

### SEND EMAIL ###

if($E5_AvLicsCount -lt $LowerThreshold) {
    $Parameters = @{
        From = 'CloudTeam@company.com'
        To = 'linus.joyeux@company.com'
        Cc = 'cloudteam@company.com','murat.duman@company.com'
        Subject = 'O365 E5 License Count Alert!'
        Body = [string]$body
        BodyAsHtml = $true
        SmtpServer = '10.192.144.4'
    }
    Send-MailMessage @Parameters
}

if($E3_AvLicsCount -lt $LowerThreshold) {
    $Parameters = @{
        From = 'CloudTeam@company.com'
        To = 'linus.joyeux@company.com'
        Cc = 'cloudteam@company.com'
        Subject = 'O365 E3 License Count Alert!'
        Body = [string]$body2
        BodyAsHtml = $true
        SmtpServer = '10.192.144.4'
    }
    Send-MailMessage @Parameters
}

if($EntraID_AvLicsCount -lt 5) {
    $Parameters = @{
        From = 'CloudTeam@company.com'
        To = 'linus.joyeux@company.com'
        Cc = 'cloudteam@company.com'
        Subject = 'Microsoft Entra ID P2 License Count Alert!'
        Body = [string]$body3
        BodyAsHtml = $true
        SmtpServer = '10.192.144.4'
    }
    Send-MailMessage @Parameters
}

if($O365MGEO_AvLicsCount -lt 10) {
    $Parameters = @{
        From = 'CloudTeam@company.com'
        To = 'linus.joyeux@company.com'
        Cc = 'muhammet.ozkan@company.com','ozan.polat@company.com'
        Subject = 'Multi-Geo Capabilities in Office 365 License Count Alert!'
        Body = [string]$body4
        BodyAsHtml = $true
        SmtpServer = '10.192.144.4'
    }
    Send-MailMessage @Parameters
}