# Input bindings are passed in via param block.
param($Timer)
Connect-MgGraph -Identity

#Variables
$secret_acs_endpoint = Get-AzKeyVaultSecret -VaultName "kv-apps-itautomation-swn" -Name "acsEndpoint" -AsPlainText
$secret_acs_accesskey = Get-AzKeyVaultSecret -VaultName "kv-apps-itautomation-swn" -Name "acsAccessKey" -AsPlainText
$TestRecipient = @("ozan.polat@company.com")
$RecipientBcc = @("ozan.polat@company.com","muhammet.ozkan@company.com") 

### Function for Azure AD App Registration secrets/certificates ###
Function Get-MgApplicationCertificateAndSecretExpiration {
    [CmdletBinding(DefaultParameterSetName='Default')]
    param(
        [Parameter(Mandatory = $false, ParameterSetName = 'CertOnly')]
        [switch]    $ShowOnlyCertificates,

        [Parameter(Mandatory = $false, ParameterSetName = 'SecretOnly')]
        [switch]    $ShowOnlySecrets,

        [Parameter(Mandatory = $false)]
        [switch]    $ShowExpiredKeys,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1,720)]
        [int]    $DaysWithinExpiration = 30,

        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('ApplicationId', 'ClientId')]
        [string]    $AppId
    )

    BEGIN {
        $ConnectionGraph = Get-MgContext
        if (-not $ConnectionGraph) {
            Write-Error "Please connect to Microsoft Graph" -ErrorAction Stop
        }
        # Adding an extra day to account for hour differences and offsets.
        $DaysWithinExpiration++
    }

    PROCESS {
        try {
            if ($PSBoundParameters.ContainsKey('AppId')) {
                $ApplicationList = Get-MgApplication -Filter "AppId eq '$AppId'" -ErrorAction Stop
            } else {
                $ApplicationList = Get-MgApplication -All -Property AppId, DisplayName, PasswordCredentials, KeyCredentials, Notes, Id -PageSize 999 -ErrorAction Stop
            }

            $ExpiringItems = @()
            # Process certificates
            $CertificateApps  = $ApplicationList | Where-Object {$_.keyCredentials}
            foreach ($App in $CertificateApps) {
                if ($App.Notes -match "Owner:\s*(\S+)") {
                    $OwnerEmail = $Matches[1]
                } else {
                    $OwnerEmail = "Unknown Owner"
                }
                foreach ($Cert in $App.keyCredentials) {
                    if ($Cert.endDateTime -le (Get-Date).AddDays($DaysWithinExpiration)) {
                        $ExpiringItems += [PSCustomObject]@{
                            AppDisplayName      = $App.DisplayName
                            KeyType             = 'Certificate'
                            ExpirationDate      = $Cert.EndDateTime
                            DaysUntilExpiration = (($Cert.EndDateTime) - (Get-Date) | select -ExpandProperty TotalDays) -as [int]
                            OwnerEmail          = $OwnerEmail
                        }
                    }
                }
            }

            # Process secrets
            $ClientSecretApps = $ApplicationList | Where-Object {$_.passwordCredentials}
            foreach ($App in $ClientSecretApps) {
                if ($App.Notes -match "Owner:\s*(\S+)") {
                    $OwnerEmail = $Matches[1]
                } else {
                    $OwnerEmail = "Unknown Owner"
                }
                foreach ($Secret in $App.PasswordCredentials) {
                    if ($Secret.EndDateTime -le (Get-Date).AddDays($DaysWithinExpiration)) {
                        $ExpiringItems += [PSCustomObject]@{
                            AppDisplayName      = $App.DisplayName
                            KeyType             = 'ClientSecret'
                            ExpirationDate      = $Secret.EndDateTime
                            DaysUntilExpiration = (($Secret.EndDateTime) - (Get-Date) | select -ExpandProperty TotalDays) -as [int]
                            OwnerEmail          = $OwnerEmail
                        }
                    }
                }
            }

            return $ExpiringItems | Sort-Object DaysUntilExpiration | Where-Object {$_.DaysUntilExpiration -ge 0}
        } catch {
            Write-Error $_.Exception.Message
        }
    }
}

### Function for Enterprise Application SAML certificates ###
Function Get-MgEnterpriseAppSamlCertExpiration {
    BEGIN {
        $ConnectionGraph = Get-MgContext
        if (-not $ConnectionGraph) {
            Write-Error "Please connect to Microsoft Graph" -ErrorAction Stop
        }
    }

    PROCESS {
        try {
            $EnterpriseAppList = Get-MgServicePrincipal -All -Property DisplayName, KeyCredentials, Notes
            $ExpiringItems = @()
            $CertificateApps = $EnterpriseAppList | Where-Object {
                $_.keyCredentials | Where-Object { $_.usage -eq "Sign" -and $_.type -eq "AsymmetricX509Cert" }
            }
            foreach ($App in $CertificateApps) {
                if ($App.Notes -match "Owner:\s*(\S+)") {
                    $OwnerEmail = $Matches[1]
                } else {
                    $OwnerEmail = "Unknown Owner"
                }
                foreach ($Cert in $App.keyCredentials) {
                    $today = Get-Date
                    $next15Days = $today.AddDays(15)
                    if ($Cert.endDateTime -ge $today -and $Cert.endDateTime -le $next15Days) {
                        $ExpiringItems += [PSCustomObject]@{
                            AppDisplayName      = $App.DisplayName
                            KeyType             = 'SAML Signing Certificate'
                            ExpirationDate      = $Cert.endDateTime
                            DaysUntilExpiration = (($Cert.EndDateTime) - (Get-Date) | Select-Object -ExpandProperty TotalDays) -as [int]
                            OwnerEmail          = $OwnerEmail
                        }
                    }
                }
            }

            return $ExpiringItems | Sort-Object DaysUntilExpiration
        } catch {
            Write-Error $_.Exception.Message
        }
    }
}
# Ensure the variables are initialized as empty arrays
$ExpiringAppSecrets = @()
$ExpiringSamlCerts = @()

# Get Expiring App Registrations and Enterprise App SAML Certificates
$ExpiringAppSecrets = Get-MgApplicationCertificateAndSecretExpiration -DaysWithinExpiration 21
$ExpiringSamlCerts = Get-MgEnterpriseAppSamlCertExpiration

# Safeguard against null values
if ($ExpiringAppSecrets -eq $null) {
    $ExpiringAppSecrets = @()
}
if ($ExpiringSamlCerts -eq $null) {
    $ExpiringSamlCerts = @()
}

# Combine results
$AllExpiringCerts = @($ExpiringAppSecrets) + @($ExpiringSamlCerts)

# Group expiring credentials by application display name
$GroupedExpiringCerts = $AllExpiringCerts | Group-Object -Property AppDisplayName

#----------------------------------------------------------------------------------------------------------------------------
# Azure Communication Services - Email Sending Function 
function Send-ACSEmail {
    param (
        [string]$SenderAddress,
        [string[]]$RecipientTo,
        [string[]]$RecipientBcc,
        [string]$Subject,
        [string]$AppName,
        [string]$ContentHtml
    )

    $UserEngagementTrackingDisabled = $true

    # Format the recipients into the structure expected by the API
    $emailRecipientTo = @()
    foreach ($recipient in $RecipientTo) {
        $emailRecipientTo += @{Address = $recipient; DisplayName = $recipient}
    }

    $emailRecipientBcc = @()
    foreach ($recipient in $RecipientBcc) {
        $emailRecipientBcc += @{Address = $recipient; DisplayName = $recipient}
    }

    # Set email headers and content
    $headers = @{
        "Key1" = "$secret_acs_accesskey"
        "Importance" = "high"
    }

    # Prepare the email message with content and recipients
    $message = @{
        ContentSubject = $Subject
        RecipientTo = $emailRecipientTo
        RecipientBcc = $emailRecipientBcc
        SenderAddress = $SenderAddress
        ContentHtml = $ContentHtml
        Header = $headers
        UserEngagementTrackingDisabled = $UserEngagementTrackingDisabled
    }

    # Send the email using Azure Communication Services
    $answer = Send-AzEmailServicedataEmail -Message $message -Endpoint $secret_acs_endpoint -Verbose
    return $answer
}
#End of the Function
#----------------------------------------------------------------------------------------------------------------------------
# Iterate over each application group
foreach ($Group in $GroupedExpiringCerts) {
    $AppName = $Group.Name
    $OwnerEmails = $Group.Group | Select-Object -ExpandProperty OwnerEmail -Unique

    # Consolidate expiring credentials for the current application
    $UniqueCredentials = $Group.Group | Select-Object KeyType, ExpirationDate, DaysUntilExpiration -Unique

    # Generate the email body in the desired format
    $ExpiringCredentials = "<ul style='font-family: Arial, sans-serif; font-size: 14px; list-style-type: disc; padding-left: 20px;'>"
    foreach ($Credential in $UniqueCredentials) {
        $ExpiringCredentials += "<li style='margin-bottom: 10px;'><b>Application Name:</b> $AppName</li>"
        $ExpiringCredentials += "<li style='margin-bottom: 10px;'><b>Key Type:</b> $($Credential.KeyType)</li>"
        $ExpiringCredentials += "<li style='margin-bottom: 10px;'><b>Expiration Date:</b> $($Credential.ExpirationDate.ToString("yyyy-MM-dd"))</li>"
        $ExpiringCredentials += "<li style='margin-bottom: 10px;'><b>Days Until Expiration:</b> $($Credential.DaysUntilExpiration)</li>"
    }
    $ExpiringCredentials += "</ul>"

    # Ensure the subject is defined in the $Subject variable for proper usage
    $Subject = "ACTION REQUIRED: Azure Credential Expiry Alert for $AppName"

    foreach ($OwnerEmail in $OwnerEmails) {
        # Check if the owner's account is enabled
        try {
            $User = Get-MgUser -Filter "mail eq '$OwnerEmail'" -Property accountEnabled -ErrorAction Stop
            $accstatus = $User.accountEnabled
            if ($accstatus -eq $false) {
                # Send a notification for the disabled account owner
                $disabledUserSubject = "ALERT: Disabled User App Ownership Notification"
                $disabledUserBody = [string]::Format(@"
                    <div style="font-family: Arial, sans-serif; font-size: 14px;">
                        <p><strong>This user is no longer working for Gunvor Group:</strong> $OwnerEmail</p>
                        <p>They were listed as the owner for the following application:</p>
                        <ul>
                            <li><strong>Application Name:</strong> $AppName</li>
                        </ul>
                        <p>Please review and update the ownership of this application.</p>
                    </div>
"@, $AppName)

                $erroremailParams = @{
                
                    SenderAddress = "AzureAlerts@automation.company.com" 
                    RecipientTo = @("cloudteam@company.com")
                    Subject = $disabledUserSubject
                    AppName = $AppName
                    ContentHtml = $disabledUserBody
                }
                Send-ACSEmail @erroremailParams
                Write-Host "Disabled user notification sent for $OwnerEmail related to application '$AppName'."
                continue  # Skip sending notification to this disabled user's email
            }
        } catch {
            Write-Warning "Unable to verify user status for $OwnerEmail : $_"
        }
# Error Email Template (existing)
    $ExpiringCredentials = [string]::Format(@"
        <div style="align-items:center;background-color:#f9f9fb;display:flex;height:100%;justify-content:center;width:100%;">
            <div style="background-color:#fff;border-radius:10px;box-shadow:0 4px 12px rgba(0,0,0,0.1);max-width:600px;padding:30px;text-align:center;">
                <h1 style="color:#f44336;">Action Required</h1>
                <p style="font-family: Arial, sans-serif; font-size: 14px;">Dear Application Owner,</p>
                <p style="font-family: Arial, sans-serif; font-size: 14px;">
                The following Azure resource has a credential that will <span style="color: red; font-weight: bold;">expire soon</span>:
                </p>
                <div style="background-color:#f1f1f1;border-left:4px solid #f44336;padding:12px;text-align:left;margin:20px 0;">
                $ExpiringCredentials
                </div>
    <p style="font-family: Arial, sans-serif; font-size: 14px;">In order to avoid service disruption, please create a ticket from the button below for the renewal of your application credentials before the expiration date.</p>
    <p style="font-family: Arial, sans-serif; font-size: 14px;">While creating a ticket, please include the purpose of the secret and where it is being kept, such as the Key Vault name.</p>
    <p style="font-family: Arial, sans-serif; font-size: 14px;">Thank you.</p>
    <p>&nbsp;</p>
                <p><a style="background-color:#f44336;border-radius:5px;color:white;padding:12px 24px;text-decoration:none;" target="_blank" rel="noopener noreferrer" href="https://support.company.com/support?id=sc_cat_item&sys_id=ad8d0f7187fa6dd04734a9370cbb35ab&referrer=popular_items">Create a ticket for credential renewal</a></p>
    <p>&nbsp;</p>
    </div>
    </div>
"@, $AppName)
        # Prepare the parameters for Send-ACSEmail
        $emailParams = @{
            SenderAddress   = "AzureAlerts@automation.company.com"
            RecipientTo     = @($OwnerEmail) # Send to current owner
            RecipientBcc    = $RecipientBcc
            Subject         = $Subject
            AppName         = $AppName
            ContentHtml     = $ExpiringCredentials
            Header          = $headers
        }

        # Send the email
        try {
            Send-ACSEmail @emailParams
            Write-Host "Notification email sent for application '$AppName' to $OwnerEmail."
        } catch {
            Write-Error "Failed to send email for application '$AppName' to $OwnerEmail : $_"
        }
    }
}


