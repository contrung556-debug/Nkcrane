# NKCrane v1.1.0

- Replace physical-profile switching as the primary path with clean-room runtime routing.
- Publish a non-sensitive central registry at `/var/mobile/Library/NKCrane/Public/registry.json`.
- Use a read-only libSandy profile so sandboxed target apps can resolve enabled/active container state without per-app config files.
- Restore app data, App Group, preferences and supported password-keychain routing through the injected shim.
- Keep privileged CLI lifecycle control and registry verification before relaunch.
- Update diagnostics to report registry visibility and shim runtime state.
