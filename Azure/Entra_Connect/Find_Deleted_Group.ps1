Import-Module Microsoft.Graph
Connect-MgGraph -Scopes "Group.Read.All"
Get-MgGroup -GroupId "0aa62520-5c37-4fc1-bcc5-b0eb4a19c45d" | Select-Object DisplayName, Id, Mail, MailEnabled, SecurityEnabled