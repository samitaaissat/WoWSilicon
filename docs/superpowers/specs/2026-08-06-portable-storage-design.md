# Portable Storage Design ("WoWSilicon Data")

Date: 2026-08-06
Status: Approved
Supersedes: the "WINEPREFIX stays `~/.wine`" statements in
`docs/superpowers/plans/2026-08-05-v3-bundled-wine-runtime.md` (line 17) and
`docs/superpowers/specs/2026-08-05-v3-bundled-wine-design.md` (line 86).

## Problem

WoWSilicon stores state in three scattered places: the shared global Wine
prefix `~/.wine`, `~/Library/Application Support/WoWSilicon/` (versions.json,
prefs.json), and nothing travels with the app. The 2026-08-06 investigation
into "randomly reset" prefixes confirmed two root causes that this design
eliminates:

1. **External deletion masked by silent rebuild** — anything that deletes
   `~/.wine` is invisibly papered over by the app auto-recreating a bare
   prefix on next contact, so users lose settings "randomly".
2. **Shared-prefix churn** — `~/.wine` is co-owned by CrossOver, GameHub and
   any other Wine on the machine; every wine.inf mtime difference re-runs a
   full prefix update, and the game itself launches with **no WINEPREFIX at
   all**, landing in whatever `~/.wine` happens to be.

## Goal

A 100% portable app, fully transparent to the user: all mutable state (a
dedicated Wine prefix + all configuration) lives in a `WoWSilicon Data`
folder **beside** `WoWSilicon.app`. Copying the parent folder moves the whole
installation. No setup, no dialogs, no behavior cliffs.

Storing state *inside* the bundle was rejected: Sparkle replaces the whole
`.app` on update (state loss every release), and DMG/App Translocation runs
are read-only.

## Non-goals (verified intentionally unchanged)

- Game-folder persistence (Config.wtf, realmlist, addons, mods/dlls.txt,
  dxvk.conf, d9vk shader caches in cwd) stays in the game folder.
- `MigrationService`'s TurtleSilicon→WoWSilicon rename stays Application
  Support-scoped (v2-era cleanup).
- `WineRuntime` bundle-relative read-only paths; `makeWineEnvironment`
  signature; `LaunchService` `process.environment` lines.
- Sparkle internals and its UserDefaults/cache residue (check-scheduling
  metadata only; loss is harmless).
- `TelemetryService` (install_id travels inside prefs.json — one portable
  install keeps one id across machines, by design).
- No UserDefaults/@AppStorage exist anywhere in Sources/Tests (verified).

## Architecture

Two new services plus one choke-point edit:

- **`Services/PortableStorage.swift`** — single authority for where state
  lives. `init(bundleURL: URL = Bundle.main.bundleURL, fallbackSupportRoot:
  URL? = nil, fileManager: FileManager = .default)` + `static let shared`
  (WineRuntime pattern). Resolves once at startup, synchronously,
  FileManager-only, **before** any store or wine-touching service runs
  (`MainDashboardViewModel` fires wine reg-queries from init). Exposes
  `dataRootURL`, `configDirectory`, `prefixURL`, `isPortable`, a `Location`
  enum (`besideApp(URL)` | `applicationSupport(URL)`) and a machine-readable
  reason (`existingDataFolder | createdBesideApp | translocated |
  blockedByFile | parentNotWritable | creationFailed |
  prefixVolumeUnsupported`). Tests construct their own instances, never
  `.shared`.
- **`Services/PrefixBootstrapService.swift`** — explicit prefix
  initialization with progress UI (see Bootstrap).
- **Choke point**: `WineRegistrySupport.winePrefixURL()` (today `~/.wine`)
  returns `PortableStorage`'s `prefixURL`. This single edit retargets
  `DependencyService` (:124, :142-143, :235), `RetinaModeService` (:23, :38,
  :67, :115), `OptionAsAltService` (:24, :63, :83, :158) and `userRegURL()`
  (all direct user.reg text edits) with zero call-site changes (verified
  exhaustively). `makeWineEnvironment` already sets WINEPREFIX from its
  parameter — no edit.

## Resolution algorithm (every launch; nothing persisted)

1. `appURL = bundleURL.resolvingSymlinksInPath()` — called exactly once; all
   paths derive from it.
2. `appURL.pathComponents.contains("AppTranslocation")` →
   `applicationSupport(reason: .translocated)`. Never use SecTranslocate*
   (private SPI); never attempt original-path recovery.
3. `dataURL = parent/"WoWSilicon Data"`. Exists as plain file →
   fallback(`blockedByFile`). Exists as directory → write probe inside it:
   pass → `besideApp(existingDataFolder)`, fail →
   fallback(`parentNotWritable`).
4. Else `createDirectory(withIntermediateDirectories: false)`: success →
   probe → `besideApp(createdBesideApp)`; error → fallback, reason classified
   from the error **for the Troubleshooting message only**: EROFS(30)/Cocoa
   642 or parent `volumeIsReadOnly` → "running from disk image — drag to
   Applications"; EACCES(13)/EPERM/Cocoa 513 → "location not writable".
   Never use `volumeIsReadOnly` or `FileManager.isWritableFile` for control
   flow.

Write probe = real create-then-delete of `.ws-write-probe-<UUID>` in the
target directory; any throw = unwritable. (`isWritableFile(atPath:)` is
advisory and wrong on ACLs/network mounts/TCC; may serve as fast-negative
pre-check only.)

Persist **nothing** about the location: positional re-resolution is
self-healing, implements fallback→portable adoption for free, and a
persisted path could point into a dead AppTranslocation UUID mount.

Fallback root is `~/Library/Application Support/WoWSilicon` (existing dir);
fallback prefix at `.../WoWSilicon/prefix`. Fallback is a normal steady
state — `/Applications` is root:admin `drwxrwxr-x`, so **standard users
always land here** (verified). No privilege escalation.

## Data folder layout

```
WoWSilicon Data/
├── prefix/                  # dedicated Wine prefix (isExcludedFromBackup)
├── versions.json
├── prefs.json
├── version_manager.json     # only if migrated from a legacy install
└── About this folder.txt    # written at creation: deleting = reset
```

The space in "WoWSilicon Data" is verified safe end-to-end: wine reads
WINEPREFIX via raw getenv (absolute path is the only requirement; verified in
pinned wine `server/request.c:576-605`); ProcessRunner passes env as a dict;
`LaunchService.doubleQuote` protects both `/bin/sh` and Terminal/osascript
paths (empirically tested). Only winetricks (never invoked) has space bugs.

Stores receive a **fully-resolved config directory** and append only file
names: the hardcoded `"WoWSilicon"` directoryName moves out of
`VersionStore`/`UserPrefsStore` into root resolution. `UserPrefsStore` gains
its first injection point. `VersionStore`'s "Application Support" warning
string is reworded location-neutrally.

## Migration and adoption

Startup sequence:

1. `PortableStorage` resolution (folder creation only).
2. Existing TurtleSilicon→WoWSilicon prompt/migration runs first, unchanged,
   Application Support-scoped (it gains only an injectable root for tests).
3. Portable first-run import: **byte-copy** (`FileManager.copyItem`, never
   decode→re-encode) `versions.json`, `version_manager.json`, `prefs.json`
   from App Support into the Data root. Copying version_manager.json keeps
   `VersionStore`'s v2 legacy-merge alive for pre-versions.json installs.
4. Stores load against the Data root. In fallback mode today's paths run
   unchanged.

Rules:

- **Latch**: `Data/versions.json` exists ⇒ Data root is authoritative; the
  import never runs again (import always finishes by writing
  `Data/versions.json`, defaults if App Support had nothing). No marker
  files. `prefs.json` absence alone never retriggers import.
- **Precedence**: Data wins outright when both locations have content —
  never merge.
- **Copy, not move**: App Support stays intact as a rollback net (delete the
  Data folder → app falls back to App Support state).
- **Adoption** (fallback→portable transition): MOVE the app-created fallback
  prefix into `Data/prefix` (rename on same volume; copy+verify+delete across
  volumes) — a fresh prefix would cost a full wineboot init plus a VC++
  re-download. Precondition: no wine/wineserver running against it (if busy,
  stay on fallback this session, retry next launch). After the move, verify
  `dosdevices/c:` is a relative symlink (rewrite if absolute). Prefixes are
  verified relocatable (relative `c:` symlink, `C:\`-based registry paths,
  wineserver re-keys on new dev/inode).
- **`~/.wine` is never read, seeded from, or deleted.** It belongs to
  CrossOver/GameHub now. After upgrade, VC++/Retina/Option-as-Alt read
  fresh: Retina Mode and Option-as-Alt are auto re-applied from persisted
  `VersionSettings` after any successful bootstrap; the VC++ install stays
  user-initiated (tile correctly shows Not installed once).

## Prefix bootstrap

Explicit, via ProcessRunner (env dict, no shell):

1. `<runtime>/bin/wine wineboot -u`, WINEPREFIX pinned, **600 s** timeout
   (wine's own implicit-boot wait is hardcoded 5 min; dual-arch inf passes
   under cold Rosetta anchor the budget).
2. `<runtime>/bin/wineserver -w`, **120 s** timeout.
3. Indeterminate progress UI: "Setting up the Wine environment — first run
   can take a few minutes".

"Initialized" = app-written sentinel `prefix/.wowsilicon-prefix-ok`
containing the bundled runtime VERSION, written only after both steps exit 0
plus a structural sanity check (`system.reg`, `user.reg`,
`drive_c/windows`, `dosdevices/c:` resolves). **Never** treat wine's
`.update-timestamp` as proof of initialization (wineboot stamps it BEFORE
running the install sections — `wineboot.c:1620` — so a killed half-init
looks permanently up-to-date; source-verified). Sentinel version ≠ runtime
version after an app update → re-run the same explicit flow with UI before
any other wine call. The dashboard's implicit 10 s reg-queries are gated
behind the sentinel check.

On timeout: never SIGKILL — `wineserver -k`, brief wait, delete the
half-built prefix, surface a retryable error.

Prefix-hostile filesystems: never hardcode "exFAT = refuse" (modern FSKit
exFAT/FAT32 mounts pass every prefix requirement — empirically verified). At
prefix creation/adoption, probe: symlink literally named `c:` →
`../drive_c`, readlink round-trip, `st_uid == getuid()`. Overrides: treat as
hostile when `volumeSupportsSymbolicLinks == false` or the Data path is under
`~/Library/Mobile Documents` / `~/Library/CloudStorage` (cloud eviction
corrupts prefixes). Warn (don't block) when `volumeIsLocal == false`. On
hostile: **prefix-only fallback** — Data folder keeps the JSON config beside
the app, prefix goes to `~/Library/Application Support/WoWSilicon/prefix`,
Troubleshooting reports both locations. Never refuse to run.

## WINEPREFIX pinning (complete inventory of holes)

- `LaunchService.makeShellCommand` (:225-254): add `winePrefixPath`
  parameter, emit `WINEPREFIX=<doubleQuote(path)>` **last** in envParts —
  after user custom env, so the app pin wins under sh last-assignment-wins.
  A user-typed WINEPREFIX in the advanced env field is no longer honored
  (honoring it only at game launch would split game and toggles across two
  prefixes). Covers both integrated `/bin/sh` and Terminal/osascript modes
  (env is inline in the command string).
- All three call sites pass the prefix: `prepareLaunchArtifacts` (:124-130),
  `launchInstaller` (:294-300), `launchThirdPartyLauncher` (:349-356) — the
  latter two run wine with **no WINEPREFIX today**.
- `PatchService.patchDivxDecoder` (:90-119): add `env["WINEPREFIX"]` to the
  hand-built environment (silently initializes `~/.wine` today).
- `VanillaTweaksService` (:56-62, :116-131): delete the private PATH-only
  `makeWineEnvironment`, use
  `WineRegistrySupport.makeWineEnvironment(prefixURL:wineExecutable:)`.

This is the complete set — the audit found no other wine invocations lacking
WINEPREFIX.

## forceQuitWine rework (in scope)

Replace the global `pkill -9 -f ".exe"` cascade (kills every Wine app on the
machine; SIGKILL on wineserver discards ≤30 s of unflushed registry) with:

1. `wineserver -k` with WINEPREFIX pinned to the dedicated prefix,
2. ~5 s grace wait,
3. targeted `pkill -9` limited to the bundled runtime's wine/wineserver
   binary paths and rosettax87.

## Troubleshooting UI and debug log

- New storage section (between runtime and actions sections): "Storage:
  Portable — /Volumes/…/WoWSilicon Data" or "Storage: Application Support
  (fallback — running from a read-only location)", including the effective
  prefix location when it differs (hostile-FS split). Fed by new
  `@Published` fields on `TroubleshootingViewModel` populated in `refresh()`.
- `deleteWinePrefixes` splits: primary **Reset Wine Prefix** =
  `deleteDedicatedPrefix(prefixURL:)` (graceful-quit precondition); separate
  explicitly-labeled legacy action `deleteLegacyPrefixes(homeDirectory:
  gamePath:)` for `~/.wine` + `<gamePath>/.wine` behind a confirmation
  listing exact paths and warning it affects CrossOver/GameHub. `~/.wine` is
  never part of the default action again. Legacy action kept indefinitely
  until it stops earning its place.
- `resetApplicationSupport` → `resetStorage(dataRoot:supportRoot:)`: deletes
  the active storage root (incl. prefix) plus the App Support fallback dir
  when portable; button names the exact paths wiped.
- `generateDebugLog` gains `=== Storage ===`: active location + resolution
  reason, data root + exists, prefix path + exists, sentinel/runtime-version
  state, legacy `~/.wine` presence (informational). Existing `/Users/<name>`
  redaction already covers fallback paths.
- `MainDashboardViewModel.selectLauncherPath` NSOpenPanel seed retargets from
  `~/.wine/drive_c` to `<prefix>/drive_c`.

## Verified facts (for reviewers)

- **Sparkle 2.9.1** (vendored source verified: `SUPlainInstaller.m`,
  `SUInstaller.m`, `SUFileManager.m`): plain installer replaces only the
  `.app`, atomically in place at its original path (`renamex_np`
  RENAME_SWAP), stages/deletes the old bundle in its own temp/cache area
  (never the app's parent dir), relaunches from the identical path. Sibling
  Data folder and path-keyed resolution survive updates structurally.
- **Concurrency**: wineserver instances rendezvous on
  `/tmp/.wine-<uid>/server-<dev>-<inode>` derived from the prefix dir
  (pinned source `server/request.c:597-671`) — two app copies with separate
  Data folders get independent wineservers; even a shared prefix degrades to
  a single serializing wineserver, not corruption. Foreign-ownership volumes
  fail wineserver's "is not owned by you" check — detected by the `st_uid`
  probe (macOS mounts external volumes `noowners` by default, which passes).
- **Translocation**: read-only per-launch mount whose path contains the
  stable `AppTranslocation` component (survives `resolvingSymlinksInPath`'s
  `/private` stripping); Sec* recovery APIs are private.
- **/Applications**: standard users get EACCES creating siblings (verified);
  fallback is their normal steady state.

## Deferred (follow-ups, not in this change)

- **Runtime tarball mtime normalization** (`tools/runtime/
  build-wine-runtime.sh`: `tar --mtime` pin): stops wine.inf churn
  re-triggering a prefix refresh after every app update. Needs a new
  `runtime-v` tag + Makefile pin bump — next scheduled runtime release. Cost
  of deferral: one progress-reported refresh per app update, no data loss.
  App-side staging (when the bundle staging Makefile work lands) must use
  mtime-preserving copy (ditto/tar, not `cp -R`).

## Test strategy

New test files, following the repo convention (real filesystem, per-test
temp dirs, tearDownWithError, constructor-injected roots, no mocking):

- `PortableStorageResolverTests` — one test per branch: existing Data folder
  wins; writable parent creates silently; chmod-555 parent falls back
  (restore 0o755 before removeItem; `XCTSkipIf(geteuid()==0)`); translocated
  bundleURL falls back without probing; plain-file collision; existing Data
  folder wins over populated App Support; idempotent re-resolution.
- `PortableStorageAdoptionTests` — move semantics (fallback prefix GONE
  after move); never overwrites an existing Data folder; busy-prefix skip;
  a `.wine` canary in the injected fake home is never read or moved.
- `StorageMigrationTests` — first-run copy leaves originals intact; clean
  start; Data-wins precedence; TurtleSilicon end-to-end chain
  (version_manager.json fixture → MigrationService → VersionStore merge →
  portable copy); TurtleSilicon merge-into-existing dir.
- `UserPrefsStoreTests` — first-ever coverage: round-trip via injected
  configDirectory, defaults on missing/corrupt file.
- Updates: `LaunchCommandTests` (new winePrefixPath arg; pinned WINEPREFIX
  doubleQuoted with spaced/hostile paths; app pin after user env; rewrite
  `testCustomEnvironmentVariableValuesAreQuoted` with a non-WINEPREFIX
  example), `VersionStoreTests` (resolved-config-directory shape),
  `TroubleshootingServiceTests` (new split actions + storage debug block),
  `WineRegistrySupportTests` (prefix derives from injected PortableStorage).

Rules: never resolve against the real home/App Support in tests (defensive
assert); resolver stays synchronous/FileManager-only; no hdiutil in unit
tests.

Manual release-candidate checklist (what XCTest cannot cover): real wineboot
init; run from DMG; quarantined/translocated launch; Sparkle update with
populated Data folder; non-admin /Applications; exFAT USB stick; Data-folder
deletion recovery; prefix-reset scoping with a `~/.wine` canary; real
TurtleSilicon data; two app copies alternating.

## File-by-file change inventory

| File | Change |
|---|---|
| `Services/PortableStorage.swift` | NEW — resolver, probe, Data-folder creation + README, import latch/precedence, adoption move, hostility probe, isExcludedFromBackup |
| `Services/PrefixBootstrapService.swift` | NEW — wineboot -u + wineserver -w, sentinel, timeout cleanup, settings re-apply |
| `Services/WineRegistrySupport.swift` | `winePrefixURL()` body → PortableStorage prefix |
| `Services/LaunchService.swift` | makeShellCommand winePrefixPath (emitted last) + 3 call sites; forceQuitWine graceful rework |
| `Services/PatchService.swift` | patchDivxDecoder WINEPREFIX |
| `Services/VanillaTweaksService.swift` | use shared makeWineEnvironment |
| `Stores/VersionStore.swift` | resolved config dir; move "WoWSilicon" out; reword warning |
| `Stores/UserPrefsStore.swift` | init(fileManager:configDirectory:) |
| `Services/MigrationService.swift` | injectable support root (behavior unchanged) |
| `Services/TroubleshootingService.swift` | resetStorage; deleteDedicatedPrefix + deleteLegacyPrefixes; Storage debug block; injectable roots |
| `ViewModels/TroubleshootingViewModel.swift` | storage status fields; relabeled actions |
| `Views/TroubleshootingView.swift` | storage section; split prefix actions |
| `ViewModels/MainDashboardViewModel.swift` | stores from PortableStorage; init sequencing (TurtleSilicon → import → load); sentinel-gated reg queries; NSOpenPanel seed; makePathStatus fileExists downgrade (cosmetic) |
| `Tests/…` | 4 new files + 4 updated (see Test strategy) |
| `CLAUDE.md` | document portable contract, dedicated prefix, resolution rules |
| `README` | portable contract + "do not delete WoWSilicon Data" note |
