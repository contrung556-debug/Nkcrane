# Changelog

## 0.8.0
- Added app icons and search by app name/bundle identifier in Settings.
- Added `nkcranemeta` helper for container byte counts and latest-backup metadata.
- Added per-container size display and latest-backup information.
- Added a Quick Switch page for enabled apps and their containers.
- Added 2-second auto-refresh on the Background Jobs page.
- Added coarse queued/running/completed job progress labels in Settings.
- Kept container switching on the existing `nkcranectl` relaunch path rather than adding an unreliable SpringBoard launch interception hook.

## 0.7.0
- Added an on-device NKCrane manager in the iOS Settings app through PreferenceLoader.
- Added installed-app browsing and per-app NKCrane enable/disable control.
- Added container list with active-container indicator and create flow.
- Added per-container Switch, Clone, background Backup, background Restore, Rename, Wipe and Delete actions.
- Added a Background Jobs page for backup/restore job state.
- The Settings UI invokes `nkcranectl`; heavy backup/restore work still runs through the v0.5+ background worker engine rather than blocking Settings.

## 0.6.0
- Upgraded `.nkcb` to format version 2 while preserving restore compatibility with v0.5 format-1 backups.
- Added backup/restore of virtualized App Group filesystem data for named containers.
- Added Generic Password and Internet Password Keychain export/import using `Keychain.plist`.
- Added Keychain namespace translation so restored credentials target the destination container namespace.
- Added truthful manifest fields for Keychain/App Group inclusion, item counts, status and warnings.
- Hardened backup package permissions (`0700`) and sensitive metadata/Keychain files (`0600`).
- Added jailbreak-oriented entitlements for `nkcranectl` to improve Keychain access where securityd permits it.
- Clone now attempts to carry supported App Group and Keychain state as well as the normal container filesystem.

## 0.5.0
- Added `.nkcb` filesystem backups with JSON manifests.
- Added restore into named containers with owner-app validation.
- Added container cloning.
- Added background backup/restore jobs using fork + clean exec workers.
- Added persistent JSON job status under `/var/mobile/Library/NKCrane/Jobs`.
- Added automation-friendly `--json` / `--quiet` output.
- Added `--safe` backup mode and relaunch controls.

## 0.4.0
- Added stronger broad-query isolation for Generic Password and Internet Password Keychain items.
- Added bundle-family owner/child mapping for extensions/helper bundles.
- Added App Group file-container virtualization.

## 0.3.0
- Added experimental Keychain namespacing and CI packaging.

## 0.2.0
- Added CFPreferences isolation, path remapping and lifecycle controls.

## 0.1.0
- Initial clean-room container store and CLI.
