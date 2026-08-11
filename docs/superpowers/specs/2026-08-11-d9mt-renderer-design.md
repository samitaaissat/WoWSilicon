# d9mt Renderer Support — Design

Date: 2026-08-11
Status: Approved (design)

## Summary

Add [d9mt](https://github.com/neo773/d9mt) — a D3D9→Metal translation layer (no Vulkan/MoltenVK hop) — as an opt-in, per-version, experimental renderer alongside the existing d9vk path. d9vk remains the default; nothing changes for users who never touch the toggle.

## Background

WoWSilicon currently ships d9vk's `d3d9.dll` into the game folder (`Sources/WoWSiliconSwift/Resources/Patching/d9vk/`) and launches with `WINEDLLOVERRIDES="d3d9=n,b"` plus MoltenVK tuning env vars. d9mt deploys identically (a replacement `d3d9.dll` + Wine DLL override) but translates DXVK's D3D9 front-end output directly to Metal via spirv-cross and a custom Metal backend, requiring DXMT's `winemetal` pair in the prefix and the Xcode CLT `metal` compiler at runtime for MSL→metallib shader compilation.

Key constraints established during brainstorming:

- d9mt publishes no releases and has no explicit license; we build a tarball once from a pinned upstream commit and host it as an artifact on our own runtime release (alongside `wowsilicon-wine-<n>` tarballs), giving us controlled provenance and checksums.
- The Xcode CLT requirement is handled by detection + gating, not by removing the requirement.
- The option is exposed for all three game versions (Vanilla 1.12.1, TBC 2.4.3, WotLK 3.3.5a), labeled Experimental.
- Integration follows the bundled-payload approach (Approach A): no on-demand downloads, no replacement of d9vk.

## Architecture

### Payload sourcing (build time)

- New Makefile pins: `D9MT_VERSION`, `D9MT_SHA256`, `D9MT_URL`.
- New `fetch-d9mt` target downloads the tarball, verifies SHA256, stages into `Sources/WoWSiliconSwift/Resources/Patching/d9mt/` — mirrors the existing `fetch-runtime` pattern.
- `make bundle` depends on `fetch-d9mt`, so the release CI picks it up automatically.
- Payload contents: d9mt `d3d9.dll` (i686 PE build), DXMT `winemetal` files, upstream license notices.

### Runtime model

d9vk and d9mt are mutually exclusive renderers occupying the same slot: `<game>/d3d9.dll`.

- New `RendererBackend` enum in `Sources/WoWSiliconSwift/Models/GameVersion.swift`: cases `d9vk`, `d9mt`; `Codable` with `String` raw value, `Equatable`, `Sendable`.
- `VersionSettings.renderer: RendererBackend`, default `.d9vk`, decoded with `decodeIfPresent ?? .d9vk` (established migration pattern; `ModelCompatibilityTests` extended).
- `PatchService.stageGamePatchFiles` selects the payload directory (`Patching/d9vk` vs `Patching/d9mt`) from `settings.renderer`. Switching renderers re-stages: overwrite `<game>/d3d9.dll`, add/remove the `winemetal` files. `removeGamePatch` removes d9mt files as well.
- `PatchingStatusChecker.resourceExpectations` SHA256-compares the installed `d3d9.dll` against the active renderer's bundled payload, keeping "outdated" detection correct for both renderers.
- `LaunchService.makeShellCommand` branches its env block on `settings.renderer`:
  - d9vk: today's exact env (unchanged regression baseline).
  - d9mt: drop `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS` and `DXVK_ASYNC`; add `winemetal=n` to `WINEDLLOVERRIDES`; set `D9MT_METALLIB_CACHE=1` and `D9MT_ASYNC=1`. `MTL_HUD_ENABLED` and `WINEMSYNC` remain renderer-agnostic.
- UI: renderer picker in the per-version settings area next to existing toggles; the d9mt option is labeled "Experimental".

### CLT gate

When the user selects d9mt, the ViewModel checks that `xcrun -f metal` resolves (Xcode CLT present). If missing, the selection is refused with an alert explaining the requirement and suggesting `xcode-select --install`.

## Data flow

**Enable d9mt:**

1. User selects "d9mt (Experimental)" in per-version settings → ViewModel runs CLT check → on success persists `settings.renderer = .d9mt` via `VersionStore`.
2. The same settings-change path used by `enableLibSiliconPatch` triggers re-staging: `PatchService.stageGamePatchFiles` replaces `<game>/d3d9.dll` with the d9mt payload and copies `winemetal` files into the game folder; the status checker re-validates.
3. The next launch reads `settings.renderer` and uses the d9mt env branch.

**Switch back to d9vk:** symmetrical — picker back to d9vk, re-stage, launch env returns to the current behavior. No state outside `versions.json`.

## Error handling

- CLT missing → typed `LocalizedError` (`.metalToolchainMissing`) with `errorDescription` directing the user to `xcode-select --install`; the selection is not persisted.
- d9mt payload missing from the app bundle → staging fails with a typed error via the existing `PatchService` missing-payload path; the existing status UI surfaces it.
- Payload SHA mismatch → existing "outdated" status flow, parameterized by active renderer.
- In-game d9mt failure (crash/artifacts) → out of app scope by design; the user switches the picker back, and the Troubleshooting re-apply path remains the recovery hatch.

## Testing

- `ModelCompatibilityTests`: legacy `versions.json` without `renderer` decodes to `.d9vk`; encode/decode round-trip.
- `PatchService` temp-dir tests: staging per renderer copies the right files; switching replaces `d3d9.dll` and adds/removes winemetal files; `removeGamePatch` cleans up both payloads.
- Launch env test: d9mt branch contains `winemetal=n` and `D9MT_*`, and does not contain `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS` / `DXVK_ASYNC`.
- `PatchingStatusChecker` test: expectations follow the active renderer.
- `swift test` must pass before completion.
- Manual smoke: launch each client on d9vk (regression) and d9mt (experimental).

## Explicitly out of scope (YAGNI)

- No d9mt-specific tuning UI (upstream perf env vars default on).
- No automatic fallback to d9vk on crash.
- No changes to the mod system, VanillaTweaks, Config.wtf, or DXVKConfigService (`dxvk.conf` cursor option only applies to d9vk; it is simply inert under d9mt).
- No removal or alteration of the d9vk path.

## Docs bookkeeping

- `AGENTS.md`: add `Patching/d9mt` to the Resources list and `fetch-d9mt` to the Makefile target description.
- `docs/releasing.md`: note the new pin set (`D9MT_VERSION`/`D9MT_SHA256`/`D9MT_URL`) alongside the runtime pins.
