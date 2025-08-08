# This script will check the AD groups in $groups and will remove the user from same groups if the user has "Tallinn" or "Estonia" in their attributes. #


$groups = @("GGrp-ALL-SSLVPN Energy Desk","GGrp-ALL-SSLVPN Tallinn Terminal Users","GGrp-ALL-SSLVPN PersonalDrives Tallinn","GGrp-ALL-SSLVPN Sharepoint Prod","GGrp-ALL-SSLVPN WK RDP Mac Users","GGrp-ALL-SSLVPN WK RDP Users","GGrp-ALL-SSLVPN Citrix Users","GGrp-ALL-SSLVPN OWA Standard Users")

foreach ($group in $groups) {
  $members = Get-ADGroupMember -Identity $group | Get-ADUser -Properties co,l,physicalDeliveryOfficeName
  
  foreach ($member in $members) {
    if ($member.co -eq "Estonia" -or $member.l -eq "Tallinn" -or $member.physicalDeliveryOfficeName -eq "Tallinn") { 
      Write-Output "$($member.Name) is from $group and has 'Estonia or 'Tallinn' in their attributes. Removing from the group..."
     Remove-ADPrincipalGroupMembership -Identity $member -MemberOf $group -Confirm:$false
    }
  }
}
