# NKCrane v1.4.2

Clean-room multi-container engine for jailbroken iOS, designed to integrate with NKTouch.

> NKCrane independently recreates multi-container behavior. It does not copy Crane's private source code.

**v1.4.2 hotfix:** Named-container hooks use the canonical Library/__NKCrane_Containers/<UUID> root directly. Missing/broken legacy symlinks no longer determine the primary routing path; nkcraneprobe reports their exact state. Do not wipe/delete legacy containers before backing up and verifying the target app's session. RunningBoard injection is **not included** in the Sileo build.

## v1.3: one runtime container, one filesystem truth

v1.3.0 fixes the most important runtime inconsistency found while testing v1.2.x: the high-level Foundation hooks and the in-app physical resolver could resolve the same logical container through different path layouts.

For a named container the canonical physical root is now:

```text
<real-app-data>/Library/__NKCrane_Containers/<container-id>/
```

The previous compatibility path:

```text
<real-app-data>/.nkcrane/<container-id>/Root
```

is retained only as a migration/compatibility symlink to the canonical physical root.

Broad POSIX filesystem interception was disabled in v1.3.2 to avoid crashes. The current runtime synchronizes the following environment variables:

```text
HOME
CFFIXED_USER_HOME
TMPDIR
NKCRANE_CONTAINER_ID
NKCRANE_OWNER_BUNDLE_ID
NKCRANE_PROCESS_BUNDLE_ID
```

A successful non-default launch writes:

```text
<physical-root>/.nkcrane-layout.json
<physical-root>/.nkcrane-runtime.json
```

These markers are diagnostic evidence only; container selection remains stored in NKCrane's registry/store.

## On-device verification

After switching an app to a named container, terminate the app completely, launch it again, then run:

```sh
sudo nkcraneprobe com.facebook.Facebook
```

For a healthy v1.3 Facebook launch, the JSON should normally show:

```text
registry_active                         = selected container id
loader_truth.nkcrane_loaded             = true
physical_runtime.physical_root_exists   = true
physical_runtime.layout_marker_seen     = true
physical_runtime.runtime_marker_seen    = true
physical_runtime.legacy_root_is_symlink = true
physical_runtime.legacy_points_to_physical = true
```

If the loader and both runtime markers are correct but application credentials/session state still crosses containers, the next subsystem to investigate is service-owned state such as Keychain/container-manager/preferences helper behavior rather than basic HOME/path routing.

## Settings manager

After installation, open **Settings → NKCrane**.

The manager includes:

- Installed-app browsing and enable/disable controls.
- App icons and search by app name or bundle identifier.
- Named container creation, rename, wipe and delete controls.
- Quick Switch for configured apps.
- Per-container storage size through `nkcranemeta`.
- Backup/restore and background-job status.

## Container isolation

NKCrane currently virtualizes or namespaces:

- Common application filesystem paths.
- Foundation home/search-path APIs.
- Direct canonical path routing for NKCrane Foundation hooks (broad POSIX interception remains disabled).
- `NSUserDefaults` / `CFPreferences` for supported app-local flows.
- Generic Password and Internet Password Keychain records.
- Entitlement-backed App Group file URLs used through the intercepted API.

Bundle-family linking lets an owner app and extensions/helpers share the active container selection:

```sh
nkcranectl link com.example.App com.example.App.ShareExtension
```

## Full backup / restore

For a consistent background snapshot:

```sh
nkcranectl backup com.facebook.Facebook FB01 --safe --background --json
```

A `.nkcb` package can contain:

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

The package is built rootless for arm64.

## Architecture direction

The current v1.3 milestone deliberately fixes app-process filesystem/home consistency first. The next layers are kept separate so failures can be diagnosed independently:

```text
App process
  └─ NKCrane.dylib
       ├─ virtual HOME/search paths
       ├─ POSIX filesystem routing
       ├─ preferences namespace
       └─ supported Keychain namespace

Future launch/service layer
  ├─ SpringBoard / runningboardd launch context
  ├─ container-manager aware routing where required
  └─ helper service for privileged operations that cannot safely live in apps
```

## Important limits

- v1.3 does not pretend that a container is a separate physical device.
- NKCrane does not alter device attestation or server-side identity signals.
- Synchronizable/iCloud Keychain and daemon-owned credential stores are not guaranteed to be portable.
- Push notification registration/state is not yet virtualized.
- Some private container-manager or helper-process access patterns may require a later support layer.
- WebKit/network helper processes can keep state outside app-local paths if they are not part of the configured bundle family.
- Deeper SpringBoard/runningboardd/daemon hooks are intentionally being added only after the app-local runtime is proven on-device.

## One-screen diagnostics (v1.4.2)

Run the compact read-only probe in NewTerm after launching an app in a
named container:

```sh
sudo nkcraneprobe com.facebook.Facebook --brief
```

To share the output as text instead of many screenshots:

```sh
sudo nkcraneprobe com.facebook.Facebook --brief > /var/mobile/nkcrane-brief.txt
```

The brief mode reports app selection, process, tri-state dylib visibility,
canonical physical root, layout/runtime/shim marker status and age, marker
PID matching, legacy symlink state, Choicy block rules and safe mode. The full
JSON mode remains available by omitting `--brief`.

Neither unreadable process images nor old marker files prove a dylib missing
or present. Even positive app-local runtime evidence is **not** proof of
independent account sessions or complete isolation.
