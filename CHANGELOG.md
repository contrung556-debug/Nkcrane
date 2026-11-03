# Changelog

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
- Default-container backups exclude `.nkcrane` to prevent recursive container copies.
- Backup manifests explicitly report that Keychain and App Group backup are not included yet.

## 0.4.0
- Added stronger broad-query isolation for Generic Password and Internet Password Keychain items.
- Added bundle-family owner/child mapping for extensions/helper bundles.
- Added App Group file-container virtualization.
- App switching terminates linked children before relaunching the owner.

## 0.3.0
- Added experimental Keychain namespacing for Generic Password and Internet Password records.
- Added Security.framework hooks for add/copy/update/delete.
- Added Keychain result attribute de-namespacing.
- Added `nkcranectl status`.
- Added GitHub Actions rootless package build.

## 0.2.0
- Added CFPreferences isolation.
- Added HOME/TMPDIR and common directory remapping.
- Added automatic app terminate/relaunch on switch.
- Added rename/restart commands.

## 0.1.0
- Initial clean-room container store and CLI.
