# NKCrane roadmap

## v0.1 — Core store + virtual home
- [x] Per-app container metadata
- [x] Create/list/switch/wipe/delete
- [x] Basic virtual home redirection

## v0.2 — Preferences + lifecycle
- [x] `NSUserDefaults` isolation
- [x] `CFPreferences*` isolation
- [x] `HOME` / `TMPDIR`
- [x] Automatic app terminate/relaunch on switch

## v0.3 — Keychain + CI
- [x] Generic/Internet Password namespacing
- [x] Security.framework hooks
- [x] GitHub Actions rootless build

## v0.4 — Robust isolation
- [x] Broad Generic/Internet Password query filtering
- [x] App Group file-container virtualization
- [x] Bundle-family extension coordination
- [ ] App Group `NSUserDefaults` suite isolation
- [ ] Keys/certificates/identities and synchronizable Keychain records
- [ ] More WebKit/helper-process coordination

## v0.5 — Backup / automation
- [x] Filesystem backup package + manifest
- [x] Restore into named container
- [x] Duplicate/clone container
- [x] Background backup/restore jobs
- [x] JSON/quiet automation output
- [ ] Include App Group data in backup/restore
- [ ] Include supported Keychain records in backup/restore

## v0.6 — Management UI + NKTouch integration
- [ ] Container picker UI
- [ ] Backup/restore UI
- [ ] Lua API: list/create/switch/clone/backup/restore/job-status
- [ ] Always-ask app-launch selector
- [ ] Launch directly into a selected container
