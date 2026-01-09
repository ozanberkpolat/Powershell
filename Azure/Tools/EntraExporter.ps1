Install-Module EntraExporter
Export-Entra -Path 'C:\EntraBackup\' -All

# export default all users as well as default objects and settings
Export-Entra -Path 'C:\EntraBackup\' -Type "Config","Users"

# export applications only
Export-Entra -Path 'C:\EntraBackup\' -Type "Applications"

# export B2C specific properties only
Export-Entra -Path 'C:\EntraBackup\' -Type "B2C"

# export B2B properties along with AD properties
Export-Entra -Path 'C:\EntraBackup\' -Type "B2B","Config"