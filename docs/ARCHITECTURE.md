# NKCrane architecture (v0.4)

NKCrane is a clean-room multi-container engine for jailbroken iOS.

## Runtime path isolation

For a named container, each participating process maps common application paths to:

`<that process data container>/.nkcrane/<container-id>/Root`

The Default container is left untouched.

## Bundle families

Extensions/helper bundles can be explicitly linked to an owner bundle with `nkcranectl link`. The linked process resolves the owner's active container ID, so all family members select the same profile. Process-local normal storage remains in each process's own sandbox.

## App Groups

NKCrane first asks iOS for the real entitlement-backed App Group URL. For named containers it returns a child directory under that real group:

`<real group>/.nkcrane/<owner>/<container>/<group>/Root`

This keeps the filesystem access inside a group the process is already entitled to use and lets linked family members share the same per-container group data.

App Group `NSUserDefaults` suites are not yet virtualized in v0.4.

## Preferences isolation

`NSUserDefaults.standardUserDefaults` and the current process's `CFPreferences*` application domain are redirected to a container-specific process-local domain.

## Keychain isolation

Generic Password and Internet Password records namespace service/server/account values with the owner bundle + active container.

Queries that already identify service/server/account are rewritten directly. Broader queries are enumerated with attributes + persistent references, filtered to items carrying the active container prefix, and then shaped back to the result type requested by the application. Broad update/delete operations execute only against the filtered persistent references.

Anonymous password records get an internal synthetic identity so they remain filterable; that identity is removed before attributes are returned to the application.

Keys, certificates, identities, synchronizable Keychain behavior, and daemon-owned stores are still outside the v0.4 scope.

## Security boundary

Containers isolate application data. They do not represent separate physical devices, and NKCrane does not alter device attestation or server-side identity signals.
