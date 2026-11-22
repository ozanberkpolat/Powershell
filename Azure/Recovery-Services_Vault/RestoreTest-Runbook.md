# Restore test runbook (Azure Backup, VM into an isolated subnet)

Use with `Invoke-RestoreTest.ps1`, which automates steps 1 to 7 and keeps their order. Follow the manual steps below when you cannot use the script. The order matters: each numbered step exists because a real test lost time on it.

## Before the first restore of the day

1. Activate the privileged roles you need through PIM (vault restore, contributor on the restore-test resource group, and the domain-controller subscription if you restore a domain controller). Activations lapse during long jobs; check before you start.
2. Confirm the isolated subnet is empty, or holds only machines you expect (`Get-AzVirtualNetworkSubnetConfig ... .IpConfigurations`).
3. Confirm the VPN or firewall split tunnel advertises the isolated range to clients. If it does not, nobody can reach the restored machine. Clients pick up routes at connection time: anyone already connected must reconnect.
4. Confirm the isolated subnet NSG denies outbound to Storage, Internet and every private range except the isolated subnet itself (and the platform address 168.63.129.16, which is not subject to NSGs or user-defined routes; a route for it is neither needed nor accepted).
5. Work oldest recovery point first: points expire 30 days after they were taken on a daily policy. Start the largest system first and leave it alone (about 36 minutes for 384 GB, hours for multi-terabyte database servers).

## Per machine

### 1. Trigger the restore

Restore disks into a new VM in the isolated subnet. In PowerShell this is `Restore-AzRecoveryServicesBackupItem` with `-TargetVMName`, `-TargetVNetName`, `-TargetVNetResourceGroup`, `-TargetSubnetName` and a staging storage account. Record the restore job ID and the recovery point ID for the protocol.

Sensitive source systems (databases, anything that holds production data and has scheduled jobs): attach a restrictive NSG to the NIC the moment the NIC resource appears, before the machine boots. A restored copy may carry the credentials and schedules to write to, or expire, production backups, and a storage service tag can include the production account in the same region.

### 2. Wait for the job, then confirm the machine

Power state Running and guest agent Ready. Agent Ready proves the platform channel works.

### 3. Enable boot diagnostics immediately

A restore does **not** carry boot diagnostics over, even when the source has them enabled.

```powershell
Invoke-AzRestMethod -Method PATCH -Path "<vm id>?api-version=2024-07-01" `
  -Payload '{"properties":{"diagnosticsProfile":{"bootDiagnostics":{"enabled":true}}}}'
```

Do this before anything else needs the console. Do **not** restart the machine to make it take effect: on a restored Windows system the restart installs the updates that were pending on the source, which has to be recorded as a deviation.

### 4. Capture the console screenshot early

- The console goes fully black once the display idles. Capture while the sign-in screen is awake.
- On Windows the first frames after boot usually show "Working on updates": a restored machine installs whatever was staged on the source at backup time. No restart is involved. Wait for it to finish, then capture; a frame showing update progress is not evidence of a healthy start. Record the note on system state in the protocol.
- Judge a frame by the number of clearly lit pixels, not mean brightness: a Linux console is white text on black.
- On Windows the image carries the machine clock (timestamp evidence). On Linux it shows the host name.

Get the URIs with `POST <vm id>/retrieveBootDiagnosticsData?sasUriExpirationTimeInMinutes=10`.

### 5. Capture the serial log

Same call, `serialConsoleLogBlobUri`. On Windows it contains the hourly guest health report (report time, adapters and addresses, remote desktop state, the RDP certificate subject that proves machine identity, platform services). The first report can take up to an hour: plan the handover around it. On Linux it holds the boot sequence, mounts and login banner.

### 6. Provision access

- Create or reset a local account. Pass the password as a **protected** Run Command parameter; never in the script text.
- Windows: switch off Network Level Authentication (`UserAuthentication = 0` under `...\WinStations\RDP-Tcp`). No domain controller is reachable in isolation, so pre-authentication cannot complete and RDP fails before it asks for a password. Do it as part of provisioning, not after a failed attempt.
- Linux: enable `PasswordAuthentication yes` in sshd (check that the source allows it, otherwise adjust the restored copy and record it).
- Stop and disable the source's schedulers and workloads (job schedulers, cron-like services, database agents) so the copy does not start work of its own. Build the filter in a here-string: building the shell snippet as an expandable PowerShell string expands `$_` locally and the filter arrives empty.
- Write the credentials to a file. Not in chat, not in the protocol.
- Using VMAccess instead of Run Command needs the machine to download an extension package, which means opening Storage outbound for the duration. Prefer Run Command; if you must open the rule, stamp both moments so the exposure window is on the record, and close it in a `finally` block.

### 7. Verify disk caching and LUNs against the source

Compare OS disk caching, data disk caching and LUN numbers with the source before handover. The restore normally carries caching across, but a mismatch is silent: the system is just slower under load, which on a database server is exactly what a restore test should catch. On Linux device names follow attach order, so a changed LUN moves mount points. Fixing caching needs a deallocate, so do it before release.

### 8. Consider the monitoring and backup agents

The restored machine carries the production monitoring and backup agents and will try to report under the production host name. The egress block should stop them; confirm it rather than assume, or remove the agents after the restore.

### 9. Hand over

Send machine name, address and account; send the credentials separately. Ask for written confirmation of what was checked plus whatever screenshot evidence the system owner considers appropriate, with the reminder that it lands in a document classified for internal use.

### 10. Fill the protocol

Record: recovery point ID and time, restore job ID, every timestamp (UTC), address, console screenshot, serial log, disk comparison, and any change to the restored system state (updates installed, services disabled, NLA off). Anything unusual goes in the deviations section; do not leave it out.

### 11. Clean up after sign-off

`Invoke-RestoreTest.ps1 -Cleanup -TargetVmName <name> ...` deletes the VM, its disks and NICs and checks that the isolated subnet is empty again. Delete the credential file.

## Special cases

- **Domain controllers:** a restored DC answers as a DC of the production domain and may be reachable from the hub. Add inbound rules that allow only the isolated subnet and deny the private ranges before restoring one, and set the VNet DNS to the isolated DC once it is up (until then it can stay on the platform resolver).
- **Database servers:** consider whether the database service starts by itself and what it can reach. Stop scheduled backup jobs (RMAN, SQL Agent jobs) before first boot where possible.
- **SQL in a VM with log backups:** to restore a database to a point in time use the workload restore (restore as files), not a VM restore.
