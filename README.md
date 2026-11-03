# NKCrane v0.4.0

Clean-room multi-container engine for jailbroken iOS, designed to integrate with NKTouch.

> NKCrane recreates multi-container behavior independently. It does not copy Crane's private source code.

## v0.4 highlights

- Everything from v0.3: virtual app home, Preferences/CFPreferences isolation, password Keychain isolation, CLI, rootless CI build.
- Stronger Keychain isolation for Generic Password and Internet Password records:
  - broad `SecItemCopyMatching` queries are enumerated and filtered to the active container;
  - broad update/delete operations are applied only to persistent refs belonging to the active container;
  - anonymous password entries receive an internal container identity and that identity is hidden again when results are returned.
- Bundle-family coordination for app extensions/helper app bundles.
- App Group file-container virtualization using the real entitlement-backed group URL as the parent directory.
- Switching an owner app terminates linked child bundles before relaunching the owner.

## Build

Local Theos:

```sh
make clean package FINALPACKAGE=1
```

Or open **Actions -> Build NKCrane -> Run workflow**. GitHub uploads the resulting package as `NKCrane-rootless`.

## Basic usage

```sh
nkcranectl enable com.facebook.Facebook
nkcranectl create com.facebook.Facebook FB01
nkcranectl create com.facebook.Facebook FB02
nkcranectl switch com.facebook.Facebook FB01
```

Useful commands:

```sh
nkcranectl list com.facebook.Facebook
nkcranectl status com.facebook.Facebook
nkcranectl active com.facebook.Facebook
nkcranectl rename com.facebook.Facebook FB01 Personal
nkcranectl restart com.facebook.Facebook
nkcranectl wipe com.facebook.Facebook FB02
nkcranectl delete com.facebook.Facebook FB02
nkcranectl path com.facebook.Facebook FB01
```

## Link an extension/helper to its owner

The owner and linked child processes use the same active container ID. Normal process-local data still lives under each process's own sandbox, while entitlement-backed App Group paths are redirected to the same per-container group directory.

```sh
nkcranectl link com.example.App com.example.App.ShareExtension
nkcranectl family com.example.App
nkcranectl resolve com.example.App.ShareExtension
```

Remove the relationship:

```sh
nkcranectl unlink com.example.App.ShareExtension
```

Do not guess extension bundle IDs; obtain the real bundle ID from the installed app before linking it.

## Isolation model

Named app data:

```text
<process-data>/.nkcrane/<container-id>/Root/
```

Virtualized App Group files:

```text
<real-entitled-group>/.nkcrane/<owner-bundle>/<container-id>/<group-id>/Root/
```

The `Default` container is not remapped.

## Current Keychain scope

v0.4 isolates `kSecClassGenericPassword` and `kSecClassInternetPassword`, including common broad queries. Custom/shared access groups are preserved rather than forged, so an app and a legitimately entitled linked extension can share the active container's namespaced password items.

Still not fully virtualized: keys, certificates, identities, synchronizable/iCloud Keychain behavior, and daemon-owned credential stores.

## Important limits

- App Group **file URLs** are virtualized. App Group `NSUserDefaults` suite virtualization is still pending.
- Push notification registration/state is not virtualized.
- WebKit/network helper processes may keep additional state outside the paths currently intercepted.
- A container is not a separate physical device. NKCrane does not alter device attestation or server-side identity signals.

See [ROADMAP.md](ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
