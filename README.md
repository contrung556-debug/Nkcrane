# NKCrane v0.3.0

Clean-room multi-container engine for jailbroken iOS, designed to integrate with NKTouch.

> NKCrane recreates multi-container behavior independently. It does not copy Crane's private source code.

## v0.3 highlights

- Separate virtual home for each app/container.
- Remap `NSHomeDirectory`, `NSTemporaryDirectory`, common search paths, `HOME`, and `TMPDIR`.
- Separate `NSUserDefaults` and current-app `CFPreferences*` domains.
- Namespace common Keychain records for named containers:
  - Generic Password (`kSecClassGenericPassword`)
  - Internet Password (`kSecClassInternetPassword`)
  - hooks `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, and `SecItemDelete`
- Automatic terminate + relaunch when switching containers.
- Create/list/switch/rename/wipe/delete/restart/status commands through `nkcranectl`.
- Rootless Theos packaging.
- GitHub Actions workflow that builds a `.deb` artifact from a phone-friendly repository workflow.

## Build locally

Requires Theos:

```sh
make clean package FINALPACKAGE=1
```

The package is written to `packages/`.

## Build on GitHub

Open **Actions -> Build NKCrane -> Run workflow**. The resulting `.deb` is uploaded as the `NKCrane-rootless` workflow artifact.

## Basic usage

```sh
nkcranectl enable com.facebook.Facebook
nkcranectl create com.facebook.Facebook FB01
nkcranectl create com.facebook.Facebook FB02
nkcranectl list com.facebook.Facebook
nkcranectl switch com.facebook.Facebook FB01
```

`switch` terminates and relaunches the target app by default:

```sh
nkcranectl switch com.facebook.Facebook FB02
```

Change active container without relaunching:

```sh
nkcranectl switch com.facebook.Facebook FB02 --no-relaunch
```

Useful commands:

```sh
nkcranectl status com.facebook.Facebook
nkcranectl active com.facebook.Facebook
nkcranectl rename com.facebook.Facebook FB01 Personal
nkcranectl restart com.facebook.Facebook
nkcranectl wipe com.facebook.Facebook FB02
nkcranectl delete com.facebook.Facebook FB02
nkcranectl path com.facebook.Facebook FB01
```

## Isolation model

A named container is stored under the app's real data container:

```text
<app-data>/.nkcrane/<container-id>/Root/
```

The `Default` container remains the app's original data container.

### Keychain in v0.3

For named containers, common service/server and account attributes are namespaced before calls reach Security.framework. Attribute dictionaries returned to the app are translated back.

This is an **experimental first Keychain layer**, not full Keychain virtualization. Broad queries that omit normal identifying attributes, custom/shared access groups, keys, certificates, identities, synchronizable records, and daemon-owned storage still need deeper handling.

## Important limitations

- App Groups/extensions are not virtualized yet.
- Push notification registration/state is not virtualized.
- Some WebKit/network data can live in helper processes outside the app sandbox.
- A container is not a separate physical device and does not change device attestation or server-side identity signals.

See [ROADMAP.md](ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
