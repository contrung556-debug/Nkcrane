## v1.4.1 — Canonical path and diagnostic hotfix

- Fixed mismatch where Tweak.xm used .nkcrane/<UUID>/Root even though the in-app resolver created the canonical Library/__NKCrane_Containers/<UUID> directory. Named hooks now use the resolver's canonical path directly.
- Preserve existing legacy Root directories and unexpected links during symlink compatibility setup; no automatic destructive relocation.
- Write named-container shim markers into the canonical physical directory so diagnostics do not depend on the legacy link.
- Probe uses lstat to separate missing, broken, and occupied legacy paths and reports an explicit UNKNOWN state if task_for_pid cannot inspect a process.
- Runtime marker now records the actual compatibility symlink state instead of hardcoding true.
- No RunningBoard hook, no daemon injection, no low-level POSIX interception.

## v1.4.0 — Safety foundation (PR preview)

- Fix destructive container operations: exact canonical UUID leaf only, reject symlink and legacy directory ambiguity, refuse active container deletion/wipe, surface filesystem errors.
- Add independent bounded `NKCLaunchCapsule` parser with separate ABSENT, DEFAULT, NAMED, INVALID and UNKNOWN states. ABSENT/UNKNOWN never imply Default.
- Add read-only `KERN_PROCARGS2` launch-capsule diagnostics to `nkcraneprobe` and native parser tests in CI.
- Preserve v1.3.2 runtime and POSIX-hook safety behavior. RunningBoard injection, daemon hooks and migration remain **not enabled** until test-device validation.

# Changelog

## 1.3.1
- Fixed constructor-order handling around `HOME` and `CFFIXED_USER_HOME`.
- The early filesystem bootstrap now installs canonical physical-root routing first without changing the process home seen by the main Logos constructor.
- `HOME`, `CFFIXED_USER_HOME`, and `TMPDIR` are canonicalized on the main queue after static constructors finish, preventing recursive/nested container path construction.
- Runtime markers now report the post-constructor home-environment phase and version `1.3.1`.

## 1.3.0
- Unified non-default runtime storage on the v1.2.2 physical layout: `Library/__NKCrane_Containers/<container-id>`.
- Linked the existing low-level POSIX filesystem interception layer into `NKCrane.dylib`; these sources previously existed in the repository but were not part of the tweak build.
- Added a runtime filesystem bootstrap that resolves the canonical container through `NKCStore` and installs hooks against the same physical root used by the in-app layout resolver.
- Synchronized the named-container runtime environment and added `.nkcrane-runtime.json` diagnostics inside each active physical container.
- Preserved migration and compatibility symlinks for legacy `.nkcrane/<id>/Root` callers.
- Added `nkcraneprobe` checks for physical-root existence, layout/runtime markers, and legacy-symlink correctness.
- This release intentionally focuses on filesystem/home consistency before adding the separate SpringBoard/RunningBoard and daemon-support layers.

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
