# NKCrane v0.5.0

Clean-room multi-container engine for jailbroken iOS, designed to integrate with NKTouch.

> NKCrane independently recreates multi-container behavior. It does not copy Crane's private source code.

## v0.5 highlights

- Everything from v0.4: virtual app home, Preferences/CFPreferences isolation, stronger Generic/Internet Password Keychain isolation, bundle-family coordination, App Group file virtualization, CLI and rootless CI build.
- Clone a container into a new named container.
- Filesystem backup packages (`.nkcb`) with a JSON manifest.
- Restore a backup into a **named** container.
- Background backup/restore jobs with persistent JSON status.
- Automation-friendly `--json` and `--quiet` output.
- `--safe` backup mode terminates the app family before snapshotting and optionally relaunches it afterward.

## Build

```sh
make clean package FINALPACKAGE=1
```

Or use **Actions -> Build NKCrane -> Run workflow**. GitHub uploads the resulting rootless `.deb` as `NKCrane-rootless`.

## Basic containers

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

## Backup / restore

Normal backup (app can remain running):

```sh
nkcranectl backup com.facebook.Facebook FB01 --json
```

Consistent backup: terminate the linked app family first, make the snapshot, then relaunch the owner app:

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --json
```

Restore into a named container (restore never overwrites the Default container):

```sh
nkcranectl restore com.facebook.Facebook FB02 /var/mobile/Library/NKCrane/Backups/com.facebook.Facebook/backup.nkcb --json
```

List saved backup packages:

```sh
nkcranectl backups com.facebook.Facebook
```

## Background / silent operations for NKTouch

Start a background backup and immediately get a job ID:

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --background --json
```

Example response:

```json
{"ok":true,"job_id":"...","state":"running"}
```

Query it later without opening any UI:

```sh
nkcranectl job <job-id>
```

Background restore:

```sh
nkcranectl restore com.facebook.Facebook FB02 /path/to/file.nkcb --background --json
```

Use `--quiet` when NKTouch does not need stdout. Background workers are created by re-executing `nkcranectl`, so the worker starts with a clean Objective-C/runtime state rather than continuing directly after `fork()`.

Job status files live in:

```text
/var/mobile/Library/NKCrane/Jobs/<job-id>.json
```

Default backups live in:

```text
/var/mobile/Library/NKCrane/Backups/<owner-bundle>/
```

## Bundle family / extensions

```sh
nkcranectl link com.example.App com.example.App.ShareExtension
nkcranectl family com.example.App
nkcranectl resolve com.example.App.ShareExtension
```

The owner and linked child bundles share the active container selection. Linked children are terminated before switch/restore operations.

## What a v0.5 backup contains

The `.nkcb` package currently contains the virtual app filesystem plus `manifest.json`. Backing up the Default container excludes its `.nkcrane` directory to prevent recursive backup of all containers.

**Not yet included in backup/restore:** Keychain records and virtualized App Group data. Runtime isolation for those features remains enabled, but v0.5 intentionally marks them as excluded in the manifest rather than pretending the backup is complete. These are the next full-backup targets.

## Important limits

- App Group file URLs are virtualized; App Group `NSUserDefaults` suite virtualization is still pending.
- Keychain keys/certificates/identities and synchronizable/iCloud Keychain behavior are not fully virtualized.
- Push notification registration/state is not virtualized.
- WebKit/network helper processes may keep additional state outside currently intercepted paths.
- A container is not a separate physical device; NKCrane does not alter device attestation or server-side identity signals.

See [ROADMAP.md](ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
