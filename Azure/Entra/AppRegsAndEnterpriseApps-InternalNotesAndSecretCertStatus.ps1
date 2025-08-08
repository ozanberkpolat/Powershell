# Authenticate and get the token for the required scopes
Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All","Application.Read.All","Directory.AccessAsUser.All"

### Function to Get All App Registrations with Certificates/Secrets ###
Function Get-AllAppCertSecretInfo {
    BEGIN {
        $ConnectionGraph = Get-MgContext
        if (-not $ConnectionGraph) {
            Write-Error "Please connect to Microsoft Graph" -ErrorAction Stop
        }
    }

    PROCESS {
        try {
            # Fetch all app registrations
            $ApplicationList = Get-MgApplication -All -Property AppId, DisplayName, PasswordCredentials, KeyCredentials, Notes -PageSize 999 -ErrorAction Stop
            $Results = @()

            foreach ($App in $ApplicationList) {
                $HasSecret = $false
                $HasCert = $false
                $Expired = $false

                if ($App.PasswordCredentials -ne $null -and $App.PasswordCredentials.Count -gt 0) {
                    $HasSecret = $true
                    foreach ($Secret in $App.PasswordCredentials) {
                        if ($Secret.EndDateTime -lt (Get-Date)) {
                            $Expired = $true
                        }
                    }
                }

                if ($App.KeyCredentials -ne $null -and $App.KeyCredentials.Count -gt 0) {
                    $HasCert = $true
                    foreach ($Cert in $App.KeyCredentials) {
                        if ($Cert.EndDateTime -lt (Get-Date)) {
                            $Expired = $true
                        }
                    }
                }

                $ExistsType = if ($HasCert -and $HasSecret) {
                    "Both"
                } elseif ($HasCert) {
                    "Certificate"
                } elseif ($HasSecret) {
                    "Secret"
                } else {
                    "None"
                }

                $Results += [PSCustomObject]@{
                    DisplayName = $App.DisplayName
                    CertOrSecretExists = if ($HasSecret -or $HasCert) { "Yes" } else { "No" }
                    ExistsType = $ExistsType
                    IsExpired = if ($Expired) { "Yes" } else { "No" }
                    InternalNote = $App.Notes
                    Type = "App Registration"  # Added Type column
                }
            }

            return $Results
        } catch {
            Write-Error $_.Exception.Message
        }
    }
}

### Function to Get All App Registrations with Certificates/Secrets ###
Function Get-AllAppCertSecretInfo {
    BEGIN {
        $ConnectionGraph = Get-MgContext
        if (-not $ConnectionGraph) {
            Write-Error "Please connect to Microsoft Graph" -ErrorAction Stop
        }
    }

    PROCESS {
        try {
            # Fetch all app registrations
            $ApplicationList = Get-MgApplication -All -Property AppId, DisplayName, PasswordCredentials, KeyCredentials, Notes -PageSize 999 -ErrorAction Stop
            $Results = @()

            foreach ($App in $ApplicationList) {
                $HasSecret = $false
                $HasCert = $false
                $Expired = $false

                if ($App.PasswordCredentials -ne $null -and $App.PasswordCredentials.Count -gt 0) {
                    $HasSecret = $true
                    foreach ($Secret in $App.PasswordCredentials) {
                        if ($Secret.EndDateTime -lt (Get-Date)) {
                            $Expired = $true
                        }
                    }
                }

                if ($App.KeyCredentials -ne $null -and $App.KeyCredentials.Count -gt 0) {
                    $HasCert = $true
                    foreach ($Cert in $App.KeyCredentials) {
                        if ($Cert.EndDateTime -lt (Get-Date)) {
                            $Expired = $true
                        }
                    }
                }

                $ExistsType = if ($HasCert -and $HasSecret) {
                    "Both"
                } elseif ($HasCert) {
                    "Certificate"
                } elseif ($HasSecret) {
                    "Secret"
                } else {
                    "None"
                }

                $Results += [PSCustomObject]@{
                    DisplayName = $App.DisplayName
                    CertOrSecretExists = if ($HasSecret -or $HasCert) { "Yes" } else { "No" }
                    ExistsType = $ExistsType
                    IsExpired = if ($Expired) { "Yes" } else { "No" }
                    InternalNote = $App.Notes
                    Type = "App Registration"  # Added Type column
                }
            }

            return $Results
        } catch {
            Write-Error $_.Exception.Message
        }
    }
}

### Function to Get All Enterprise Applications with SAML Signing Certificates ###
Function Get-AllEnterpriseAppCertInfo {
    BEGIN {
        $ConnectionGraph = Get-MgContext
        if (-not $ConnectionGraph) {
            Write-Error "Please connect to Microsoft Graph" -ErrorAction Stop
        }
    }

    PROCESS {
        try {
            # Fetch all enterprise applications
            $EnterpriseAppList = Get-MgServicePrincipal -All
            $Results = @()

            foreach ($App in $EnterpriseAppList) {
                # Check if SAML signing certificate exists
                $SamlSigningCertExists = $false
                $Expired = $false

                if ($App.KeyCredentials -ne $null) {
                    foreach ($Cert in $App.KeyCredentials) {
                        if ($Cert.Usage -eq "Sign" -and $Cert.Type -eq "AsymmetricX509Cert") {
                            $SamlSigningCertExists = $true
                            if ($Cert.EndDateTime -lt (Get-Date)) {
                                $Expired = $true
                            }
                        }
                    }
                }

                $ExistsType = if ($SamlSigningCertExists) {
                    "Certificate"
                } else {
                    "None"
                }

                $Results += [PSCustomObject]@{
                    DisplayName = $App.DisplayName
                    CertOrSecretExists = if ($SamlSigningCertExists) { "Yes" } else { "No" }
                    ExistsType = $ExistsType
                    IsExpired = if ($Expired) { "Yes" } else { "No" }
                    InternalNote = $App.Notes
                    Type = "Enterprise Application"  # Added Type column
                }
            }

            return $Results
        } catch {
            Write-Error $_.Exception.Message
        }
    }
}

# Get All App Registrations and Enterprise Apps
$AppCertSecretInfo = Get-AllAppCertSecretInfo
$EnterpriseAppCertInfo = Get-AllEnterpriseAppCertInfo

# Combine results into a single table
$AllAppInfo = $AppCertSecretInfo + $EnterpriseAppCertInfo

# Export the results to a CSV file
$csvFilePath = "Y:\temp-kerim\OZAN\csv exports\AzureAD_Apps_Cert_Secret_Info_Enhanced.csv"
$AllAppInfo | Export-Csv -Path $csvFilePath -NoTypeInformation -Force

Write-Host "Export complete. CSV saved to $csvFilePath"