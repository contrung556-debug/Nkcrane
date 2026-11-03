# NKCrane v0.7.0

Clean-room multi-container engine for jailbroken iOS, designed to integrate with NKTouch.

> NKCrane independently recreates multi-container behavior. It does not copy Crane's private source code.

## v0.7: on-device manager

After installation, open **Settings → NKCrane**.

The manager provides:

- **Applications**: browse installed user apps and enable/disable NKCrane per app.
- **Containers**: see Default and named containers, with a checkmark on the active one.
- **Create**: add a container from the `+` button.
- **Container actions**: Switch, Clone, Background Backup, Background Restore, Rename, Wipe and Delete.
- **Background Jobs**: inspect the state of backup/restore jobs without opening the target app.

Backup and restore launched from Settings use the existing `nkcranectl --background` worker flow. Settings only submits the job and remains responsive while the worker copies data.

## Core engine

Named app data is stored under:

```text
<process-data>/.nkcrane/<container-id>/Root/
```

NKCrane currently virtualizes common app paths, `NSUserDefaults`/`CFPreferences`, Generic/Internet Password Keychain records, and entitlement-backed App Group file URLs for named containers.

Bundle-family linking lets an owner app and its extensions/helpers share the same active container selection:

```sh
nkcranectl link com.example.App com.example.App.ShareExtension
```

## Full backup / restore

For a consistent snapshot:

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

Start a background job and get its ID immediately:

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --background --json
nkcranectl job <job-id>
```

Use `--quiet` when NKTouch does not need stdout.

## Build

```sh
make clean package FINALPACKAGE=1
```

The rootless package now includes the tweak, `nkcranectl`, and the `NKCranePrefs` PreferenceLoader bundle.

## Important limits

- Keychain backup currently covers Generic Password and Internet Password records only.
- Synchronizable/iCloud Keychain and daemon-owned credential stores are not guaranteed to be portable.
- App Group `NSUserDefaults` suite virtualization is still pending.
- Push notification registration/state is not virtualized.
- WebKit/network helper processes may keep state outside currently intercepted paths.
- A container is not a separate physical device; NKCrane does not alter device attestation or server-side identity signals.
