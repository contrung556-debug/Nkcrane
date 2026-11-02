# NKCrane architecture (v0.3)

NKCrane is a clean-room multi-container engine for jailbroken iOS.

## Runtime path isolation

For a named container, the tweak maps common application paths to:

`<real app data container>/.nkcrane/<container-id>/Root`

It hooks Foundation path helpers and remaps `HOME`/`TMPDIR`. The Default container is left untouched.

## Preferences isolation

`NSUserDefaults.standardUserDefaults` and the current application's `CFPreferences*` domain are redirected to a container-specific domain.

## Keychain isolation

v0.3 namespaces **Generic Password** and **Internet Password** records handled through the Security framework.

For named containers, common identifying attributes such as service/server and account are prefixed with an NKCrane namespace. Returned attribute dictionaries are translated back before the application sees them.

This covers the common Keychain patterns used by many apps, but it is not a full Keychain virtualizer yet. Broad Keychain queries that omit the usual identifying attributes, custom access-group behavior, keys/certificates/identities, synchronizable records, and daemon-mediated storage need additional handling in later versions.

## App switching

`nkcranectl switch` updates the active container and then terminates/relaunches the app by default so the process starts with a consistent container selection.

## Security boundary

Containers isolate application data; they are not separate physical devices. NKCrane does not attempt to defeat server-side anti-abuse systems or device attestation.
