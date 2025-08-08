# Connect to Microsoft Graph with required scopes
Import-Module Microsoft.Graph.Applications -Force
Connect-MgGraph -Scopes "Application.Read.All", "Directory.Read.All", "User.Read.All"

# Get all App Registrations with createdDateTime included
$appRegs = Get-MgApplication -All -Property "id,displayName,appId,createdDateTime"
$result = @()

foreach ($app in $appRegs) {
    $owners = Get-MgApplicationOwner -ApplicationId $app.Id

    if ($owners.Count -gt 0) {
        foreach ($owner in $owners) {
            $ownerType = $owner.AdditionalProperties.'@odata.type'

            if ($ownerType -eq "#microsoft.graph.user") {
                $user = Get-MgUser -UserId $owner.Id
                $result += [PSCustomObject]@{
                    AppDisplayName         = $app.DisplayName
                    AppId                  = $app.AppId
                    CreatedDateTime        = $app.CreatedDateTime
                    OwnerDisplayName       = $user.DisplayName
                    OwnerUserPrincipalName = $user.UserPrincipalName
                    OwnerType              = "User"
                }
            }
            elseif ($ownerType -eq "#microsoft.graph.servicePrincipal") {
                $sp = Get-MgServicePrincipal -ServicePrincipalId $owner.Id
                $result += [PSCustomObject]@{
                    AppDisplayName         = $app.DisplayName
                    AppId                  = $app.AppId
                    CreatedDateTime        = $app.CreatedDateTime
                    OwnerDisplayName       = $sp.DisplayName
                    OwnerUserPrincipalName = $sp.AppId
                    OwnerType              = "ServicePrincipal"
                }
            }
            else {
                $result += [PSCustomObject]@{
                    AppDisplayName         = $app.DisplayName
                    AppId                  = $app.AppId
                    CreatedDateTime        = $app.CreatedDateTime
                    OwnerDisplayName       = "<Unknown Type>"
                    OwnerUserPrincipalName = $owner.Id
                    OwnerType              = $ownerType
                }
            }
        }
    }
    else {
        $result += [PSCustomObject]@{
            AppDisplayName         = $app.DisplayName
            AppId                  = $app.AppId
            CreatedDateTime        = $app.CreatedDateTime
            OwnerDisplayName       = "<No Owner>"
            OwnerUserPrincipalName = "<No Owner>"
            OwnerType              = "-"
        }
    }
}


$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputPath = "D:\OBP\Audit Results\AppRegistrationsWithOwners_$timestamp.csv"
$result | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8
Write-Host "Exported to $outputPath"
