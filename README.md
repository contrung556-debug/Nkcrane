# NKCrane v0.6.0

Clean-room multi-container engine for jailbroken iOS, designed to integrate with NKTouch.

> NKCrane independently recreates multi-container behavior. It does not copy Crane's private source code.

## v0.6 highlights

- Everything from v0.5: virtual app home, Preferences/CFPreferences isolation, bundle-family coordination, App Group file virtualization, clone, background backup/restore jobs, JSON/quiet automation output and rootless CI builds.
- `.nkcb` format v2 now backs up the named container filesystem plus discovered virtualized App Group data.
- Supported NKCrane Keychain records (`kSecClassGenericPassword` and `kSecClassInternetPassword`) are exported to `Keychain.plist` when securityd permits access.
- Keychain restore re-namespaces records for the destination container.
- Backup packages use restrictive permissions (`0700` package directories, `0600` manifest/Keychain files).
- Manifest records `includes_keychain`, `keychain_status`, `keychain_item_count`, `includes_app_groups`, `app_group_count`, and warnings so callers can tell whether a backup is really complete.
- v0.5 format-1 backups remain restorable.

## Build

```sh
make clean package FINALPACKAGE=1
```

Or use **Actions -> Build NKCrane -> Run workflow**. GitHub uploads the resulting rootless `.deb` as `NKCrane-rootless`.

## Containers

```sh
nkcranectl enable com.facebook.Facebook
nkcranectl create com.facebook.Facebook FB01
nkcranectl create com.facebook.Facebook FB02
nkcranectl switch com.facebook.Facebook FB01
```

Clone:

```sh
nkcranectl clone com.facebook.Facebook FB01 FB01-Copy --json
```

## Full backup / restore

For the most consistent snapshot, terminate the linked app family while backing up:

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --json
```

A v0.6 package can contain:

```text
backup.nkcb/
├── manifest.json
├── Root/
├── AppGroups/
└── Keychain.plist
```

`Keychain.plist` is present only when export could be written. The manifest is authoritative: check `includes_keychain` and `keychain_status` rather than assuming Keychain access succeeded.

Restore into a named container:

```sh
nkcranectl restore com.facebook.Facebook FB02 /path/to/backup.nkcb --json
```

NKCrane intentionally refuses to restore directly over the Default app container.

## Background / silent backup and restore

Start a background backup:

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --background --json
```

Response:

```json
{"ok":true,"job_id":"...","state":"running"}
```

Check it from NKTouch without opening a UI:

```sh
nkcranectl job <job-id>
```

Background restore:

```sh
nkcranectl restore com.facebook.Facebook FB02 /path/to/backup.nkcb --background --json
```

Use `--quiet` when no stdout is wanted. Workers re-exec `nkcranectl` after `fork()` so they start with a clean Objective-C/runtime state.

## App Group backup behavior

NKCrane scans the virtual App Group directories created by the runtime hook under `/var/mobile/Containers/Shared/AppGroup/*/.nkcrane/...`. Each discovered group is copied into `AppGroups/` and recorded in the manifest. Restore first tries the original App Group parent path and then searches existing NKCrane group trees for a matching group key.

The Default container's original App Group data is not guessed or swept globally; v0.6 only backs up App Group data that NKCrane has virtualized for named containers.

## Keychain backup behavior

The backup engine targets the two password classes already isolated by NKCrane: Generic Password and Internet Password. Service/server/account values are de-namespaced in the archive and re-namespaced for the destination container on restore.

`nkcranectl` is signed with jailbreak-oriented entitlements to improve Keychain access. Actual access still depends on the jailbreak/securityd configuration. If access is denied, the backup continues for filesystem/App Group data and writes `keychain_status: "unavailable"` plus warnings in `manifest.json` rather than falsely claiming a complete Keychain backup.

Keychain archives contain credential data and should be treated as sensitive files.

## Bundle family / extensions

```sh
nkcranectl link com.example.App com.example.App.ShareExtension
nkcranectl family com.example.App
nkcranectl resolve com.example.App.ShareExtension
```

The owner and linked child bundles share the active container selection. Linked children are terminated before switch/restore operations.

## Important limits

- Keychain keys, certificates and identities are not included; v0.6 covers Generic/Internet Password records only.
- Synchronizable/iCloud Keychain and daemon-owned credential stores are not guaranteed to be portable.
- Push notification registration/state is not virtualized.
- WebKit/network helper processes may keep additional state outside currently intercepted paths.
- App Group `NSUserDefaults` suite virtualization is still pending.
- A container is not a separate physical device; NKCrane does not alter device attestation or server-side identity signals.

See [ROADMAP.md](ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
