# WoWSilicon 3.0.0 — Bundled pre-patched Wine runtime + rosettax87_jit update

Date: 2026-08-05
Status: approved

## Goal

Version 3.0.0 removes the CrossOver dependency entirely and fixes macOS 27 compatibility:

1. **Bundled, pre-patched Wine runtime.** WoWSilicon.app ships its own Wine inside the bundle. Users no longer install CrossOver, and the app never modifies anything outside the game folder and `~/.wine` (no more `codesign --remove-signature` on another vendor's app).
2. **Latest rosettax87_jit.** The vendored loader binaries are updated to the July 24, 2026 rolling release, which contains the macOS 27 ("Golden Gate") debugger-detach fixes, and they move from the game folder into the app bundle so the game-folder/bundle checksum-drift launch blocker can never happen again.

User-visible outcome: download one DMG (~150–170 MB), select a game folder, apply the game patch, play — on macOS 15 through 27. No CrossOver purchase/install, no CrossOver patching step, no "Play button does nothing" after a runtime update.

## Background: how v2.5.x works (verified against source)

- Launch (CrossOver 26 path, `LaunchService.swift:247-266`):
  `cd <game> && ROSETTA_X87_PATH=<game>/rosettax87/rosettax87 WINEDLLOVERRIDES="d3d9=n,b" <env> "<CrossOver.app>/Contents/SharedSupport/CrossOver/CrossOver-Hosted Application/wineloader2" "WoW.exe"`
- The "CrossOver patch" (`PatchService.swift:213-278`): copies CrossOver's `wineloader` → `wineloader2` and strips its signature; strips the signature of `lib/wine/x86_64-unix/wine`; replaces CrossOver's `ntdll.so` with a patched copy vendored in the app (`Resources/Patching/winerosetta/ntdll.so`, 790,880 B). That patched ntdll.so is what makes Wine consume `ROSETTA_X87_PATH` (it re-execs i386 processes under the rosettax87 loader in `preloader_exec`).
- The game patch copies `rosettax87` + `libRuntimeRosettax87` into `<game>/rosettax87/`, and `PatchingStatusChecker` blocks launch when those copies' SHA-256 don't match the app's bundled copies — the exact macOS-27-era failure mode reported on Discord (stale jit binaries in either place → "Play does nothing").
- The currently vendored `rosettax87` binary is already a rosettax87_jit build (codesign identifier `runtime_loader-…`) but predates the Golden Gate fixes.

## Key research findings (2026-08-05)

- **Provenance solved:** the vendored patched `ntdll.so` matches `github.com/WineAndAqua/wine`, branch `wine-11.0-macos` — a public CodeWeavers-macOS-derived Wine 11.0 tree (maintainer: aquadran/Paweł Kołodziejski, CodeWeavers' macOS Wine dev). Markers: `ROSETTA_X87_PATH` in `dlls/ntdll/unix/loader.c` `preloader_exec` (commit `1fb3eb26`), `dlls/ntdll/unix/msync.c` (CrossOver's Mach-semaphore sync), `toggle_executable_pages_for_rosetta` in `virtual.c`. Building the whole runtime from this tree yields a Wine that is pre-patched by construction — no patch files to maintain, and behaviorally the same family users run today (CrossOver 26 = Wine 11.0).
- **rosettax87_jit** (`github.com/Lifeisawful/rosettax87_jit`, MIT): rolling release `latest`, asset `rosettax87-jit-macos-arm64.tar.gz` (181,357 B, re-uploaded 2026-07-24) containing `runtime_loader` + `libRuntimeRosettax87`. July commits fix Golden Gate Dev Beta 4 detach (`0376631c`, `92107acd`, `a44f1eff` — lldb-debugserver-style detach, verified on Sequoia and Golden Gate). `libRuntimeRosettax87` must sit in the same directory as the loader (located via executable dir, not env). No sudo helper; the loader carries `com.apple.security.cs.debugger` entitlement → one-time macOS "authorize debugging" prompt.
- **Gcenx's Wine-CrossOver prebuilts are gone** (winecx repo + assets 404), which is why we build rather than repack. Proven CI recipe: `srimanachanta/winecx-dist` builds CX-26-sources Wine on the `macos-15-intel` runner (brew: bison ccache gettext mingw-w64 pkgconfig freetype gnutls libpcap sdl2 molten-vk vulkan-loader vulkan-headers; ~1h14m cold, 13–15m warm ccache).
- Stock Gcenx wine-stable 11.0_1 was inspected and rejected as a base: no `ROSETTA_X87_PATH` support in its ntdll.so, and its ntdll.so (577 KB) differs from our vendored build — mixing them is an ABI gamble.
- Rosetta 2 (which this whole stack requires) is supported through macOS 27, with a gaming-focused subset continuing beyond (Apple WWDC25 statement).

## Decisions (user-approved)

| Decision | Choice |
|---|---|
| Runtime distribution | Bundled inside WoWSilicon.app (single self-contained DMG; no first-run download) |
| Runtime production | Built from source in CI |
| Source tree | `WineAndAqua/wine` @ pinned SHA on `wine-11.0-macos` |
| rosettax87 location | Inside the app bundle only; removed from game folders |
| WINEPREFIX | Unchanged (`~/.wine`) — preserves existing users' registry/VC++ runtime |
| CrossOver code | Deleted (no fallback mode) |

## Design

### 1. Runtime build pipeline (`.github/workflows/runtime.yml`)

New workflow, decoupled from app releases, triggered by `runtime-v*` tags (or `workflow_dispatch`):

1. Runner: `macos-15-intel` (x86_64 Unix side is mandatory; arm64-built Wine cannot run x86 Windows apps).
2. Clone `WineAndAqua/wine` at a pinned SHA on `wine-11.0-macos` (recorded in the workflow; LGPL compliance = the tree is public, keep LICENSE files in the tarball and credit in README/About).
3. Deps via brew (winecx-dist list): `bison ccache gettext mingw-w64 pkgconfig freetype gnutls libpcap sdl2 molten-vk`; ccache action for warm rebuilds.
4. Configure (adapted from winecx-dist / Gcenx flags):
   `--prefix= --disable-tests --disable-winedbg --enable-win64 --enable-archs=i386,x86_64 --with-mingw --with-vulkan --with-coreaudio --with-cups --with-freetype --with-gettext --with-gnutls --with-pcap --with-pthread --with-sdl --with-unwind --without-gstreamer --without-opengl --without-x` etc., `MACOSX_DEPLOYMENT_TARGET=10.15`, `CROSSCFLAGS=-O2`, rpath `@loader_path/../../` + brew lib dir.
5. `make -j`, `make install-lib DESTDIR=…` → prune docs/includes; copy `libMoltenVK.dylib` into `lib/` (DXVK d3d9.dll's Vulkan backend); no wine-mono/wine-gecko.
6. `codesign --force --deep --sign -` (plain ad-hoc, no hardened runtime → debugger attach works; users never run codesign).
7. Package `wowsilicon-wine-<n>-osx64.tar.xz` (layout: `wine/{bin,lib,share}`) + `.sha256`; publish as GitHub release `runtime-v<n>`.

Expected size: ~140–160 MB compressed, ~400 MB unpacked (no mono/gecko/gstreamer).

Smoke test in the workflow: `bin/wine --version` under Rosetta and a `wineboot -u` into a scratch prefix with `WINEDLLOVERRIDES=mscoree=d;mshtml=d`.

### 2. App bundle assembly (Makefile)

- New pinned vars: `RUNTIME_VERSION`, `RUNTIME_SHA256`, `RUNTIME_URL` (GitHub release asset).
- New target `fetch-runtime`: download to `.build/runtime-cache/` (skip if cached + checksum OK), verify sha256, extract.
- `bundle` gains: copy runtime into `$(APP_BUNDLE)/Contents/SharedSupport/wine/` **before** the codesign step (so the ad-hoc `--deep` seal covers it).
- DMG/appcast/CI release flow otherwise unchanged. Sparkle: every app update re-ships the full DMG (~150–170 MB) — accepted trade-off of in-app bundling.

### 3. rosettax87_jit payload

- Replace `Resources/Patching/rosettax87/{rosettax87,libRuntimeRosettax87}` with the 2026-07-24 jit release binaries. Keep vendoring them in git (they are ~600 KB total; same policy as today). The loader keeps the historical name `rosettax87` (it's `runtime_loader` renamed — same as today's vendoring and the Discord procedure).
- No extra staging: these resources already land inside the app via the SPM resource bundle (`Contents/Resources/WoWSilicon-swift_WoWSiliconSwift.bundle/Patching/rosettax87/`), executable bits preserved. `ROSETTA_X87_PATH` points at that in-bundle path, resolved through the existing resource-lookup machinery (`libRuntimeRosettax87` sits next to the loader in the same directory, as the loader requires).
- Game patch no longer creates `<game>/rosettax87/`; apply/remove both delete a leftover `<game>/rosettax87/` from v2.

### 4. App code changes

New:
- `Services/WineRuntime.swift` — single authority for runtime paths: `wineBinaryURL` (`…/SharedSupport/wine/bin/wine`), `rosettaLoaderURL` (the bundled `Patching/rosettax87/rosettax87` resource), `runtimeVersion` (from a `VERSION` file stamped by the runtime pipeline), and a `validate()` returning typed errors (missing/not-executable → "reinstall the app" guidance). All other services consume this.

Changed:
- `LaunchService`: single launch shape — `cd <game> && ROSETTA_X87_PATH=<loader> <env> "<wine>" "<exe>"` for game, installer, and third-party launcher paths. Delete `detectCrossOverVersion` branching, `wineloader2` checks, pre-v26 wrapper mode. `forceQuitWine` pkill patterns target the bundle's `bin/wine`/`wineserver` (plus the existing `.exe` and `rosettax87` patterns).
- `PatchService`: delete `applyCrossOverPatch`/`removeCrossOverPatch`/`detectCrossOverVersion`/signature helpers (`removeSignature`, `isSigned`, `isSignedByCodeWeavers`) and the `Patching/winerosetta/ntdll.so` resource. Game patch: stop copying rosettax87 into the game folder; remove leftover `<game>/rosettax87/` on apply and remove; DivxDecoder rundll32 step uses `WineRuntime.wineBinaryURL`.
- `PatchingStatusChecker`: delete `evaluateCrossOverPatch`; drop game-folder rosettax87 expectations from `resourceExpectations`/required-files; add a lightweight runtime validation surfaced on the dashboard only when broken.
- `WineRegistrySupport`, `DependencyService`, `OptionAsAltService`, `RetinaModeService`, `VanillaTweaksService`, `TroubleshootingService`: replace wineloader2 resolution + the 4 duplicated `/Applications/CrossOver.app` fallbacks with `WineRuntime`. `~/.wine` prefix handling unchanged.
- `MainDashboardViewModel` / `MainDashboardView`: remove CrossOver path row + `selectCrossOverPath`, CrossOver patch row + patch/unpatch actions, and CrossOver gating (`canLaunch` = game path set + game patch applied + runtime valid). Onboarding copy updated.
- `TroubleshootingViewModel` / `TroubleshootingView`: replace "CrossOver version" with bundled runtime version + rosettax87 build; keep "Delete Wine Prefixes"; add **"Restore CrossOver modifications"** (best-effort: restore `ntdll.so.bak` → `ntdll.so`, `wine.bak` → `wine`, delete `wineloader2` at a user-chosen CrossOver path; silent no-op per missing piece). Debug log prints runtime info instead of CrossOver info.
- `Models/GameVersion.swift`: keep decoding `crossover_path` for backward compatibility, stop using it (retain the stored value on disk; do not surface in UI). `ModelCompatibilityTests` extended to prove old `versions.json` files still decode.

### 5. Migration (v2.5.x → 3.0.0 via Sparkle)

- Game folders remain valid: `d3d9.dll`, `mods/winerosetta.dll`, `dlls.txt`, DivxDecoder `.bak` state untouched. Only delta: obsolete `<game>/rosettax87/` (cleaned up as above). Status checker no longer requires it, so existing patched folders show "Applied" without user action.
- `~/.wine` prefix: same Wine 11.0 family → registry, VC++ runtime, Retina/OptionAsAlt settings survive.
- The user's patched CrossOver install is left as-is; the Troubleshooting restore button lets them revert it. Release notes explain CrossOver is no longer needed.

### 6. Version bump & docs

- `3.0.0` via `tools/release/set_version.sh` (build number 30000); `docs/releases/3.0.0.md` covering: no more CrossOver, bundled runtime, macOS 27 support, the one-time debugging-authorization prompt, and larger download size.
- README: rewrite Requirements (drop CrossOver), Installation, and add an LGPL/source-availability note for the bundled Wine (link WineAndAqua/wine + pinned SHA) and credits (Lifeisawful/rosettax87_jit, WineAndAqua, Gcenx/winerosetta).
- `AGENTS.md`/`CLAUDE.md`: update project overview + repository layout for the runtime pipeline.

## Testing

- **Milestone 0 (spike, before any app code change):** run the runtime workflow once (or the build script locally), hand-assemble a bundle, and boot a real client (vanilla 1.12 + one of TBC/WotLK) on this Mac: game launches, DXVK d3d9 renders (check `d3d9=n,b` actually loads native), DivxDecoder rundll32 patching works with the new wine, Retina/OptionAsAlt registry writes apply, macOS 27 beta if available. Only proceed when the spike passes.
- Unit tests (XCTest, real-filesystem style per repo convention): `WineRuntime` resolution against a fake bundle layout in a temp dir; `LaunchService` shell-command construction (single shape, env var ordering, quoting); `PatchService` game patch without rosettax87 + leftover cleanup; `PatchingStatusChecker` new expectations; `ModelCompatibilityTests` for `crossover_path`.
- CI: `swift test` continues to gate releases; runtime workflow has its own smoke test.
- Manual matrix before tagging: fresh install on macOS 15/26/27-beta; v2.5.5 → 3.0.0 Sparkle upgrade on at least one machine with an existing prefix + patched game folder.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| From-source runtime behaves differently than CrossOver 26 proper (wined3d/macdrv deltas) | Build from the CX-derived WineAndAqua tree (closest public match to today's binaries); milestone-0 spike gates everything |
| `--without-gstreamer` breaks some media path | WoW-era clients use DivxDecoder (already patched) + native audio; verify cinematics in spike; can add gstreamer later if needed |
| Debugger-attach blocked by future macOS hardening | jit project actively tracks betas (Golden Gate fixes landed within days); runtime + jit binaries are updatable independently of Wine |
| `macos-15-intel` runner retirement (~Aug 2027) | Documented fallback: arm64 runner + Rosetta x86_64 Homebrew (runner-images #9676/#9760 pattern); not needed for v3.0.0 |
| Sparkle full-download weight (~150–170 MB per update) | Accepted (bundling decision); revisit delta updates or runtime-out-of-band later if it hurts |
| LGPL compliance | Public pinned source tree linked in README/About; LICENSE files shipped in the runtime tarball |

## Out of scope

- `d9vk/d3d9.dll`, `winerosetta.dll`, `libDllLdr.dll`, `libSiliconPatch.dll`, `vanilla-tweaks.exe` payloads (unchanged).
- Addon manager, mod manager, realmlist, telemetry, updater plumbing.
- Wine version upgrades beyond 11.0-macos (the pipeline makes them cheap later).
- Notarization / Developer ID signing (app stays ad-hoc signed, as today).
