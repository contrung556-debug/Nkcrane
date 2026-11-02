# Changelog

## 0.3.0
- Added experimental Keychain namespacing for Generic Password and Internet Password records.
- Added Security.framework hooks for add/copy/update/delete.
- Added Keychain result attribute de-namespacing.
- Added `nkcranectl status`.
- Added GitHub Actions rootless package build.
- Simplified build dependencies by using runtime lookup for private APIs.
- Targeted `arm64` for portable CI builds aimed at App Store application injection.

## 0.2.0
- Added CFPreferences isolation.
- Added HOME/TMPDIR and common directory remapping.
- Added automatic restart after container switch.
- Added rename/restart commands.

## 0.1.0
- Initial clean-room container store and CLI.
