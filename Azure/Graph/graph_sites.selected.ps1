Import-Module Microsoft.Graph.Applications
Import-Module Microsoft.Graph.Sites

# Object ID of the Service Principal to which you want to assign permissions on the Graph API
$ObjectId = "OBJECT-ID-OF-SERVICE-PRINCIPAL" #Object ID 

# Client ID of the Service Principal to which you want to assign permissions on the Sharepoint level
$application = @{
id = "CLIENT-ID-OF-SERVICE-PRINCIPAL" # Replace with your actual Client ID
displayName = "DISPLAY-NAME-OF-SERVICE-PRINCIPAL" # Replace with your actual Display Name
}

# Add the correct Graph scope to grant
$graphScope = "Sites.Selected"

# Connect to Graph
Connect-MgGraph -Scope Directory.AccessAsUser.All -TenantId 11980ae3-cae6-4552-94d2-5ad474856f9e

#Sharepoint Permission
$graph = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0ff1-ce00-000000000000'"
$graphAppRole = $graph.AppRoles | ? Value -eq $graphScope

$appRoleAssignment = @{
"principalId" = $ObjectId
"resourceId" = $graph.Id
"appRoleId" = $graphAppRole.Id
}

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ObjectID -BodyParameter $appRoleAssignment | Format-List

# GraphAPI Permission
$graph = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
$graphAppRole = $graph.AppRoles | ? Value -eq $graphScope

$appRoleAssignment = @{
"principalId" = $ObjectId
"resourceId" = $graph.Id
"appRoleId" = $graphAppRole.Id
}

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ObjectID -BodyParameter $appRoleAssignment | Format-List

############################################################################




# Add the correct role to grant the Managed Identity (read or write)
$appRole = "write"

# Add the correct SharePoint Online tenant URL and site name
$spoTenant = "company.sharepoint.com"
$spoSite = "SP-SITE-NAME" # Replace with your actual SharePoint site name

# No need to change anything below
$spoSiteId = $spoTenant + ":/sites/" + $spoSite + ":"

Import-Module Microsoft.Graph.Sites

Connect-MgGraph -Scope Sites.FullControl.All
New-MgSitePermission -SiteId $spoSiteId -Roles $appRole -GrantedToIdentities @{ Application = $application }

Write-Host "Permission assignment completed for site: $spoSite"


$perms = Get-MgSitePermission -SiteId $spoSiteId

foreach ($p in $perms) {
    foreach ($id in $p.grantedToIdentities) {

        if ($id.application -ne $null) {
            $appId = $id.application.id
            $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'"
            
            [PSCustomObject]@{
                AppId        = $appId
                DisplayName  = $sp.DisplayName
                Permission   = $p.Roles -join ","
            }
        }
    }
}
