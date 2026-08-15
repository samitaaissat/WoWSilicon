# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project overview

WoWSilicon is a native macOS launcher for older World of Warcraft clients (Vanilla 1.12.1, The Burning Crusade 2.4.3, Wrath of the Lich King 3.3.5a) on Apple Silicon Macs. It orchestrates a bundled, pre-patched Wine runtime (built from `WineAndAqua/wine`, branch `wine-11.14-macos`, shipped inside the app as a nested game bundle at `Contents/SharedSupport/WoWSilicon Game.app/` whose `Contents/MacOS` holds wine's bin, the rosettax87 loader pair, a physical `wine-gamemode` loader copy (the bundle's CFBundleExecutable) and the `wine-rosetta-shim` that routes wine's i386 re-exec through it — this exact geometry is what makes macOS Game Mode recognise the game process; do not deepen, rename, or re-sign it casually), RosettaX87, DX9 translation (d9vk by default, with an optional experimental d9mt D3D9→Metal renderer and an optional experimental wined3d backend — Wine's built-in D3D9 on its Vulkan renderer via MoltenVK, no payload; it stages no d3d9.dll and the launch env selects the renderer via `WINE_D3D_CONFIG="renderer=vulkan"`, mandatory because the runtime is built `--without-opengl`), and runtime patching so 2006–2010 era clients run efficiently on modern macOS — no CrossOver install required. It also ships an addon manager (Git URL installs, bulk import/export), a mod manager for DLL-style mods, a realmlist editor, graphics options, and Sparkle-based auto-updates.

The app is written in Swift 6 with SwiftUI + AppKit. It is Apple Silicon only (arm64).

## Repository layout

- `Sources/WoWSiliconSwift/` — the whole app, as a single SwiftPM executable target:
  - `WoWSiliconSwiftApp.swift` — `@main` entry point (SwiftUI `App`, single fixed-size window, `AppDelegate`).
  - `Models/` — Codable domain models (`GameVersion.swift` holds `GameVersion`, `VersionSettings`, `GraphicsSettings`, and `VersionManager` with the three built-in version profiles; `UserPrefs.swift`).
  - `Stores/` — persistence (`VersionStore` reads/writes `versions.json` under Application Support with legacy migration; `UserPrefsStore`).
  - `Services/` — the bulk of the logic: `WineRuntime` (single authority for bundled Wine runtime paths, version, and validation), `LaunchService` (launching via the bundled Wine runtime), `PatchService`, `PatchingStatusChecker`, `ConfigService` (writes `WTF/Config.wtf`), `AddonService`, `ModService`, `RealmlistService`, `RetinaModeService`, `OptionAsAltService`, `VanillaTweaksService`, `DXVKConfigService`, `UpdaterService` (Sparkle, updates the app itself), `RuntimeUpdateService` + `RuntimeUpdatePaths` (background self-update of the *bundled wine runtime and d9mt payload* from `samitaaissat/WoWSilicon` GitHub releases — downloads land in a checksum-verified cache under the portable Data folder and are assembled into an override copy of the nested game bundle that `WineRuntime`/`PatchService` prefer over the one baked into the app at build time; never writes into the signed app bundle itself), `TelemetryService`, `ProcessRunner`, etc.
  - `ViewModels/` — MVVM view models (`MainDashboardViewModel`, `AddonManagerViewModel`, `ModManagerViewModel`, `TroubleshootingViewModel`).
  - `Views/` — SwiftUI views; `Views/Modifiers/` holds shared view modifiers/environment registration.
  - `Resources/` — binary patching payloads bundled into the app (`Patching/d9vk`, `Patching/libSiliconPatch/{vanilla,wotlk}`, `Patching/rosettax87`, `Patching/winerosetta`, `Patching/vanilla-tweaks`) and the app icon source PNG. `Patching/d9mt` — the optional d9mt renderer payload (`d3d9.dll` plus the `winemetal`/`d9mtmetal` DLLs and `.so` unixlibs) — is also bundled from here but is not committed; it is fetched and checksum-verified by `make fetch-d9mt` (gitignored, see the Makefile bullet). Treat these as vendored third-party binaries; do not regenerate them casually. CrossOver patching was removed in 3.0.0: `Patching/winerosetta` now holds only the game-folder DLLs (`winerosetta.dll`, `libDllLdr.dll`) — its former `ntdll.so` payload is gone because the equivalent patches are built into the bundled Wine runtime.
- `Tests/WoWSiliconSwiftTests/` — XCTest suite mirroring the services (`ConfigServiceTests`, `DXVKConfigServiceTests`, `ModServiceTests`, `RealmlistServiceTests`, `VersionStoreTests`, `ModelCompatibilityTests`).
- `Packaging/Info.plist` — the app bundle Info.plist; **source of truth for the version** (`CFBundleShortVersionString` / `CFBundleVersion`) and Sparkle keys (`SUFeedURL`, `SUPublicEDKey`).
- `Project.swift` + `Tuist/Config.swift` — Tuist manifest for generating an Xcode project (`make xcode`). Keep `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in sync with `Packaging/Info.plist` (the release scripts do this).
- `Makefile` — build, bundle, DMG, appcast, runtime-fetch, and icon-generation targets (see below). Pins the bundled Wine runtime via `RUNTIME_VERSION`/`RUNTIME_SHA256`/`RUNTIME_URL`; `fetch-runtime` downloads and verifies it, and `bundle` stages it as the nested `$(APP_BUNDLE)/Contents/SharedSupport/WoWSilicon Game.app` (bin → `Contents/MacOS` plus the rosettax87 pair, the `wine-gamemode` loader copy + `ntdll.so` symlink + compiled `wine-rosetta-shim`, lib/share as siblings, games-category Info.plist with CFBundleExecutable=wine-gamemode for Game Mode) before codesigning. The optional d9mt renderer payload is pinned the same way via `D9MT_VERSION`/`D9MT_SHA256`/`D9MT_URL`; `fetch-d9mt` downloads and verifies it into `Sources/WoWSiliconSwift/Resources/Patching/d9mt`, and `bundle` stages its winemetal/d9mtmetal files as Wine builtins into the nested game app's `lib/wine` arch dirs (`i386-windows`, `x86_64-windows`, `x86_64-unix`). Since payload v2 the d9mt `d3d9.dll` is built from our fork `samitaaissat/d9mt` (integration branch `wowsilicon`: upstream neo773/d9mt @ `237e2935` plus the depth-bias fix for projected textures clipping into terrain and, since v3, bind-path perf work — the fork's `docs/PERF-ROADMAP.md` tracks landed/next optimizations); `tools/d9mt/build-payload.sh` holds the repo/commit pins.
- `docs/releasing.md` — release process; `docs/releases/<version>.md` — per-version release notes consumed by CI.
- `docs/gpu-optimization-wwdc21-10148.md` — audit of the rendering stack against WWDC21 "Optimize high-end games for Apple GPUs", tip by tip: which are already satisfied (fast math, shared-storage buffers on unified memory, most binding dedupe), which are the game's to make and not ours, and the two that were fixed in the d9mt fork (lossless-compression usage flags; `setViewports` / vertex-buffer redundant bindings). Read it before touching texture usage flags or the bind path.
- `.github/workflows/release.yml` — tag-triggered (`v*.*.*`) release pipeline.
- `.github/workflows/runtime.yml` — tag-triggered (`runtime-v*`) pipeline that builds the pre-patched Wine runtime from the pinned `WineAndAqua/wine` commit and publishes `wowsilicon-wine-<n>-osx64.tar.xz` (+ `.sha256`) as a GitHub release.
- `tools/runtime/` — scripts used by the runtime workflow to build and package the bundled Wine runtime.
- `tools/release/` — version bump and local Sparkle test scripts.
- `tools/telemetry-worker/` — a separate Cloudflare Worker (JavaScript, D1 database) serving telemetry config/stats/event ingestion for `TelemetryService`. It is deployed independently (copy `wrangler.toml.example` to `wrangler.toml`); it is not part of the Swift build.

## Build and test commands

Requirements: macOS with Xcode/Swift 6 toolchain, Apple Silicon. Tuist is optional (only for Xcode project generation).

```sh
swift build          # debug build
swift test           # run the XCTest suite
make debug           # debug build via Makefile (arm64, custom .build path)
make build           # release build
make bundle          # release build + assemble .build/WoWSilicon.app (icon, Sparkle.framework, Info.plist, ad-hoc codesign by default)
make run             # bundle and open the app
make dmg             # bundle + create .build/release-archives/WoWSilicon-<version>.dmg
make appcast         # dmg + generate Sparkle appcast.xml (needs SPARKLE_PRIVATE_KEY or local keychain account)
make xcode           # tuist generate (Xcode project)
make clean           # swift package clean + remove .build
```

Notes:

- The Makefile pins `--arch arm64` and uses `.build/` as the build path with custom module caches; plain `swift build`/`swift test` work too and use SwiftPM defaults.
- Signing defaults to ad-hoc (`CODESIGN_IDENTITY ?=` is `-`); override for a real identity.
- Sparkle is fetched via SwiftPM (`Package.swift`, `Package.resolved`); the Makefile copies `Sparkle.framework` from the SwiftPM build products into the bundle.

## Code style guidelines

- Swift 6, SwiftUI views + MVVM (`ViewModels/`), model/store/service separation. Follow the existing structure: UI in `Views/`, state and orchestration in `ViewModels/`, side effects and filesystem/process work in `Services/`, persistence in `Stores/`, Codable data in `Models/`.
- All domain models are `Codable`, `Equatable`, `Sendable`; persisted models implement custom `init(from:)` with `decodeIfPresent` defaults and in-place migration of legacy keys (see `GameVersion.swift`) — **preserve backward compatibility with existing `versions.json` files on user machines** when changing model fields.
- Singleton services use `static let shared` and are marked `@unchecked Sendable` with internal locking/queues where needed.
- Errors are typed `LocalizedError` enums with user-facing `errorDescription` strings (see `LaunchService`).
- Tests use XCTest with `@testable import WoWSiliconSwift`, temp directories created per test and removed in `tearDownWithError`.
- Comments and documentation are in English.

## Testing instructions

- Run `swift test` before considering any change done; the release CI also runs `swift test`.
- Service tests exercise real filesystem behavior in temporary directories (e.g. `ConfigService` writing `Config.wtf`, `RealmlistService`, `ModService`); match that pattern for new tests instead of mocking.
- `ModelCompatibilityTests` guards the Codable migration paths — update/extend it whenever persisted model shapes change.

## Release and deployment

- Releases are tag-driven: add `docs/releases/<version>.md`, run `tools/release/set_version.sh <version>` (updates `Packaging/Info.plist` and `Project.swift`), commit, tag `v<version>`, push. The GitHub Action (`.github/workflows/release.yml`, macOS runner) builds the DMG, creates/updates the GitHub Release, signs and generates the Sparkle appcast, and publishes `appcast.xml` to the `WoWSilicon/wowsilicon.github.io` Pages repo.
- Versioning: semantic display version plus numeric build number (`2.5.10` → `20510`), computed by `tools/release/version_to_build_number.sh`. CI secrets: `SPARKLE_PRIVATE_KEY` (EdDSA private key value only) and `PAGES_REPO_TOKEN`.
- Runtime releases are decoupled from app releases: tag `runtime-v<n>` to run `.github/workflows/runtime.yml` and publish `wowsilicon-wine-<n>-osx64.tar.xz` + `.sha256`. The app selects which runtime it bundles via the `Makefile` pins (`RUNTIME_VERSION`, `RUNTIME_SHA256`, `RUNTIME_URL`); `make fetch-runtime` verifies the checksum before `make bundle` embeds the runtime. Bump all three pins together in one commit (see `docs/releasing.md`, "Runtime Releases").
- Full details: `docs/releasing.md`.

## Security considerations

- **Never commit secrets.** `SPARKLE_PRIVATE_KEY` lives only in CI secrets / local env; the public key in `Packaging/Info.plist` (`SUPublicEDKey`) is fine.
- The app modifies user-selected directories outside the repo (the WoW game folder) and shells out to processes (`ProcessRunner`, AppleScript terminal launches). It no longer modifies the CrossOver bundle or any other application's bundle. Be careful with path handling, quoting, and command construction when touching `LaunchService`, `PatchService`, or `ProcessRunner` — user input (game paths, Git URLs, env variables) flows into these.
- The vendored DLLs/binaries under `Sources/WoWSiliconSwift/Resources/Patching/` are third-party payloads with their own LICENSE files; don't replace them without reviewing provenance.
- Telemetry is opt-in (`UserPrefs.telemetryEnabled`), sampled, and gated by a server-side config; `TelemetryService` sends only coarse metadata (app/client version, macOS version, realmlist host). Keep it privacy-preserving if modified.

## Known inconsistencies to be aware of

- `Package.swift` and `Project.swift` declare a macOS 14.0 deployment target, while `Packaging/Info.plist` (`LSMinimumSystemVersion` 15.0) and the README require macOS 15. The effective requirement is macOS 15; the lower SwiftPM/Tuist targets are build-time only.
- Some identifiers still reference the project's former "TurtleSilicon" name (icon asset names, `turtle.icns`, a DispatchQueue label). Rename only deliberately.
