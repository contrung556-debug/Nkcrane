# NKCrane v0.8.0

Clean-room multi-container engine for jailbroken iOS, designed to integrate with NKTouch.

> NKCrane independently recreates multi-container behavior. It does not copy Crane's private source code.

## v0.8: faster on-device management

After installation, open **Settings → NKCrane**.

v0.8 adds:

- App icons in the Applications and Quick Switch pages.
- Search by app name or bundle identifier.
- Per-container storage size loaded through the standalone `nkcranemeta` helper so Settings itself does not recursively scan app data.
- Latest-backup metadata in container details; a `↻` marker appears for containers with a recorded backup.
- Background Jobs auto-refresh every 2 seconds while the page is visible, with coarse activity percentages for queued/running/completed states.
- **Quick Switch** for configured apps: choose a container and NKCrane switches it through the existing CLI/relaunch flow.

The v0.8 package contains the tweak, `nkcranectl`, `nkcranemeta`, and the `NKCranePrefs` PreferenceLoader bundle.

## Containers

Named app data is stored under:

```text
<process-data>/.nkcrane/<container-id>/Root/
```

NKCrane virtualizes common app paths, `NSUserDefaults`/`CFPreferences`, Generic/Internet Password Keychain records, and entitlement-backed App Group file URLs for named containers.

Bundle-family linking lets an owner app and its extensions/helpers share the same active container selection:

```sh
nkcranectl link com.example.App com.example.App.ShareExtension
```

## Full backup / restore

For a consistent background snapshot:

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --background --json
```

A v0.6+ `.nkcb` package can contain:

```text
backup.nkcb/
├── manifest.json
├── Root/
├── AppGroups/
└── Keychain.plist
```

The manifest is authoritative. Check `includes_keychain`, `keychain_status`, `includes_app_groups` and warnings rather than assuming every subsystem was accessible.

Restore into a named container:

```sh
nkcranectl restore com.facebook.Facebook FB02 /path/to/backup.nkcb --background --json
```

NKCrane intentionally refuses to restore directly over the Default app container.

## Automation / NKTouch

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --background --json
nkcranectl job <job-id>
```

Use `--quiet` when NKTouch does not need stdout.

`nkcranemeta app <bundle-id>` outputs JSON containing container byte counts and latest backup metadata for the Settings manager.

## Build

```sh
make clean package FINALPACKAGE=1
```

## Important limits

- The job percentage shown in v0.8 Settings is a coarse state indicator, not byte-accurate copy progress.
- The fast switcher lives in **Settings → NKCrane → Quick Switch**. A SpringBoard-level “Always Ask before every app launch” interceptor is intentionally not enabled yet; that requires a separate, version-sensitive launch hook and will not be shipped as a fake/unreliable feature.
- Keychain backup currently covers Generic Password and Internet Password records only.
- Synchronizable/iCloud Keychain and daemon-owned credential stores are not guaranteed to be portable.
- App Group `NSUserDefaults` suite virtualization is still pending.
- Push notification registration/state is not virtualized.
- WebKit/network helper processes may keep state outside currently intercepted paths.
- A container is not a separate physical device; NKCrane does not alter device attestation or server-side identity signals.
