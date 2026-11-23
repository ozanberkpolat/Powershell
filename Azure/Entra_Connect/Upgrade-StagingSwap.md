# Entra Connect upgrade by staging server swap (runbook)

Upgrade Microsoft Entra Connect Sync with two servers (one active, one in staging mode) so synchronization never stops and every step can be rolled back. This is Microsoft's "swing migration" method for an existing active/staging pair.

References:
- [Upgrade from a previous version (swing migration)](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-upgrade-previous-version#swing-migration)
- [Staging server and disaster recovery](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-sync-staging-server)
- [Sync scheduler](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-sync-feature-scheduler)
- [Release version history](https://learn.microsoft.com/entra/identity/hybrid/connect/reference-connect-version-history)

## Rules that prevent most incidents

- **Only one server may export at any time.** When you switch roles, put the active server into staging mode FIRST, then take the other one out of staging mode. Two active servers write competing changes to Entra ID.
- **Check staging with `StagingModeEnabled`, not `SyncCycleEnabled`.** A staging server keeps running import and synchronization (it only suppresses exports), and Microsoft recommends leaving its scheduler on so it is current when it takes over.
- **The scheduler configuration is stored in Entra ID and shared by both servers** (except the staging flag). `Set-ADSyncScheduler -SyncCycleEnabled $false` on one server also stops the other. Turn it back on when you are done.
- **Never set staging mode with `Set-ADSyncScheduler`** (the old `isStagingModeEnabled` parameter is unsupported). Use the wizard: Configure > Configure staging mode.
- **Upgrade the staging server first.** It is the one you can afford to break; you see the new version run against real data before it takes over.
- Download the installer from the Microsoft Entra admin center (Entra Connect > Get started); that is the only official source of the MSI. Check the release notes for the minimum version and for authentication changes (newer versions require application-based authentication by a fixed date).

## 1. Preparation

1. Change approval and a maintenance window. Tell the owners of downstream systems (HR provisioning, Exchange hybrid, SSO) that sync may pause for a few minutes during the switch.
2. Permissions: local administrator on both servers; Hybrid Identity Administrator (or Global Administrator) in Entra ID for the wizard; the AD DS connector account credentials if the wizard asks for them.
3. Identify the roles. On each server:
   ```powershell
   Import-Module ADSync
   Get-ADSyncScheduler | Select-Object SyncCycleEnabled, StagingModeEnabled, NextSyncCycleStartTimeInUTC
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
       Where-Object DisplayName -match 'Entra Connect|Azure AD Connect' | Select-Object DisplayName, DisplayVersion
   ```
   Exactly one server must show `StagingModeEnabled : False`.
4. Back up:
   - Take a VM snapshot or system backup of both servers.
   - Export the configuration on both servers: wizard > Configure > View or export current configuration > Export settings. Store the JSON file on another server.
5. Check prerequisites of the target version (supported Windows Server version, .NET Framework, TLS 1.2) on both servers.
6. Confirm both servers have the same configuration: OU filtering, custom synchronization rules, optional features. A custom rule that exists only on the active server must be moved first (see the Microsoft swing migration page: export it from the Synchronization Rules Editor and replace the connector GUID with the staging server's).

## 2. Upgrade the staging server

1. On the staging server, run the new installer and choose **Upgrade**. Enter credentials when asked.
2. At the end, leave **staging mode enabled**. Let it run a full import and full synchronization (the installer usually starts one; otherwise `Start-ADSyncSyncCycle -PolicyType Initial`).
3. Verify the result before it ever exports:
   - Synchronization Service Manager > Operations: the runs completed without errors.
   - Review what it WOULD export (pending exports to Entra ID), as described under "Verify the configuration of a server" in the staging server article (`csexport` and `CSExportAnalyzer`). An unexpected mass update or delete means the configuration differs from the active server: fix it and sync again until the pending exports look right.

## 3. Switch roles (old active server goes to staging first)

1. On the **active** server, make sure no run is in progress (Synchronization Service Manager > Operations), then open the wizard > Configure > Configure staging mode > tick **Enable staging mode** > Configure. Confirm:
   ```powershell
   (Get-ADSyncScheduler).StagingModeEnabled   # True
   ```
2. On the **upgraded** server, wizard > Configure staging mode > clear **Enable staging mode** > Configure (start the sync process when asked). Confirm:
   ```powershell
   (Get-ADSyncScheduler).StagingModeEnabled   # False
   (Get-ADSyncScheduler).SyncCycleEnabled     # True; if False, Set-ADSyncScheduler -SyncCycleEnabled $true
   Start-ADSyncSyncCycle -PolicyType Delta
   ```
3. Validate on the new active server:
   - The delta run and its export completed without errors (Operations tab, Application event log).
   - A test change in AD (for example a user attribute) appears in Entra ID after the next cycle.
   - Password hash sync works (if used): event IDs 656/657 in the Application log, or a test password change.
   - Entra admin center > Entra Connect shows a recent last sync time; Connect Health (if used) shows no new alerts.

## 4. Upgrade the other server

1. On the server that is now in staging mode, run the installer and choose **Upgrade**, keep staging mode enabled.
2. Let it run full import and synchronization, check the Operations tab, and confirm the version matches the active server.
3. It is now the failover-ready staging server. Microsoft recommends keeping the pair on the same version.

## 5. Optional: restore the original roles

If the original active server must be active again (naming, monitoring, documentation), repeat section 3 in the other direction: current active server to staging first, then the other one out of staging, then a delta sync and the same validation. Record which server is active in the operations documentation.

## 6. Rollback

- **Problem on the upgraded staging server before the switch:** nothing has changed in production. Revert that server's snapshot or reinstall the previous version from its configuration export; it stays in staging.
- **Problem after the switch:** put the new active server back into staging mode first, then take the old (not yet upgraded) server out of staging mode and run a delta sync. Investigate on the staging server.
- **A server reverted from a snapshot** has an older connector space. Keep it in staging mode and let it complete a full import and full synchronization before it is allowed to become active again.
- Never run two servers out of staging mode at the same time, not even for a quick test.
