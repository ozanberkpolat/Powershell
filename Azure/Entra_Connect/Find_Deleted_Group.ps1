Import-Module Microsoft.Graph
Connect-MgGraph -Scopes "Group.Read.All"
Get-MgDirectoryDeletedItem -DirectoryObjectId "d37a741b-538c-432b-99c0-3eda20f6e19e"
