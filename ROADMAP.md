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
- [x] Rename/restart commands

## v0.3 — Keychain + CI
- [x] Namespace Generic Password records
- [x] Namespace Internet Password records
- [x] Translate returned Keychain attributes
- [x] GitHub Actions rootless `.deb` build
- [x] `status` command

## v0.4 — Robust isolation
- [ ] Handle broad Keychain queries safely
- [ ] Keys/certificates/identities and synchronizable Keychain records
- [ ] App Group mapping
- [ ] Extension/process coordination
- [ ] Container-safe cookie/WebKit helper handling

## v0.5 — Management layer
- [ ] Backup/restore container data
- [ ] Duplicate/clone container
- [ ] Import from Default with exclusion rules
- [ ] Per-container metadata/icon/color
- [ ] Helper/daemon for privileged operations

## v0.6 — NKTouch integration
- [ ] Lua API: list/create/switch/delete/status
- [ ] Container picker UI
- [ ] "Always ask" app-launch selector
- [ ] Launch directly into a selected container
