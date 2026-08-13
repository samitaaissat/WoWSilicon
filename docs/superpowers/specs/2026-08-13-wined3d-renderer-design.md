# wined3d Renderer Support (Wine built-in D3D9 → Vulkan → MoltenVK) — Design

Date: 2026-08-13
Status: Implemented

## Summary

Add **wined3d** — Wine's own built-in Direct3D 9 implementation, driven by its
**Vulkan renderer** through the bundled MoltenVK — as a third opt-in, per-version,
experimental renderer alongside d9vk (default, unchanged) and d9mt (experimental).
Translation pipeline: D3D9 → wined3d (PE DLLs already inside the bundled runtime)
→ win32 vulkan-1 → winevulkan → MoltenVK → Metal.

This is a genuinely distinct backend, not a variant of the existing two: d9vk is
DXVK's D3D9 front-end over Vulkan, d9mt is a DXMT-based D3D9→Metal layer, and
wined3d is the Wine project's independent D3D implementation. Unlike both, it
needs **no payload**: `d3d9.dll` and `wined3d.dll` already ship in the runtime's
`lib/wine/{i386-windows,x86_64-windows}` trees. Enabling it is pure configuration.

## Empirical verification (2026-08-13, Apple M5, runtime wowsilicon-wine-1)

Scratch prefix + minimal D3D9 test PE (CreateDevice + 5×Clear/Present), built with
mingw-w64, run under the shipped runtime:

| Config | Result |
|---|---|
| x86_64, `HKCU\Software\Wine\Direct3D\renderer=vulkan` | PASS — adapter `wined3d.dll / Apple M5` (vendor 0x106b) |
| i686 (the game's arch), same key | PASS — same adapter, WoW64 vulkan thunks work |
| No registry key (wined3d's default `gl` renderer) | no-3D fallback — fake `NVIDIA GeForce 6800` adapter, GDI presentation, no GPU |

Conclusions: the runtime's `--without-opengl` build makes the registry pin
**mandatory**, not tuning; with it, both architectures get real GPU rendering.
`strings` on the shipped `wined3d.dll` confirms the Vulkan adapter is compiled in
and handles `VK_KHR_portability_subset` (MoltenVK awareness).

## Architecture

### Model (`GameVersion.swift`)
- `RendererBackend` gains `case wined3d`. Default stays `.d9vk`; missing keys
  still decode to `.d9vk`, and the decode is now tolerant of unknown raw values
  (String-based, falls back to `.d9vk` — see Accepted risk below).

### Staging (`PatchService`)
- `stageGamePatchFiles`: for `.wined3d`, **delete** `<game>/d3d9.dll` — the
  builtin d3d9 must load, and staging means guaranteeing the file's absence.
  d9vk/d9mt staging is untouched. No patch-time prefix/registry work at all.

### Renderer selection (launch env, no prefix state)
The renderer choice is **per-version** but a registry pin would live in the
**shared prefix** — patch-time registry writes would let patching a d9vk
version silently break an already-patched wined3d version, and a prefix rebuild
would strand the pin until re-patch. Instead the launch env carries
`WINE_D3D_CONFIG="renderer=vulkan"`: wined3d_main.c parses it with precedence
over both the global Direct3D key and AppDefaults, so no prefix state exists at
all. Self-healing by construction; d9vk/d9mt launches don't set it. Verified in
the shipped `wined3d.dll` (string present) and on hardware with the byte-exact
generated command — wine logs `err:winediag:wined3d_dll_init Using the Vulkan
renderer.` at device init, which is the smoke-test marker for troubleshooting.

### Status (`PatchingStatusChecker`)
- For `.wined3d` the d3d9.dll expectation inverts across both patching tiers:
  the file must be **absent**; presence reports "Leftover d3d9.dll" (warning,
  actionable). The checksum expectation for d3d9.dll is dropped (no payload to
  be outdated against).

### Launch env (`LaunchService.makeShellCommand`)
- The d3d9 DLL override is now derived from the renderer, not the call site:
  d9vk/d9mt → `d3d9=n,b` (byte-identical to before), wined3d → `d3d9=b`
  (a stray native DLL must never shadow the builtin). The `dllOverrides`
  parameter carries only the non-d3d9 tail (`mscoree`/`mshtml`).
- `.wined3d` renderer env: `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1` kept
  (MoltenVK is still the presentation path — same rationale as d9vk);
  `DXVK_ASYNC` dropped (DXVK-specific); no `D9MT_*`.

### UI
- Third picker entry "wined3d (Wine built-in, experimental)" with its own
  caption. No CLT gate (nothing is compiled at runtime, unlike d9mt); the
  existing `rendererBinding` set-path persists and re-stages via `patchGame()`.

### Telemetry
- `settings.renderer.rawValue` flows as-is; the new case reports `"wined3d"`.

## Error handling
- No renderer-specific failure paths exist: selection is pure env. If wined3d
  hits an in-game rendering bug (upstream labels the Vulkan renderer below
  GL-renderer parity as of Wine 11.x), the user switches the picker back —
  same contract as d9mt.

## Accepted risk: rollback to pre-wined3d builds
Older builds decode `renderer` with a throwing `decodeIfPresent(RendererBackend.self)`,
so a versions.json carrying `"wined3d"` makes their whole decode fail and
`VersionStore` falls back to defaults (game paths/settings reset, with a
warning). Unfixable from this tree; only users who opted into wined3d and then
roll back are exposed. This build switches to a tolerant String-based decode
(unknown renderer → `.d9vk`, tested), so rollbacks TO this build can never hit
it again for future renderer additions.

## Testing (all in `swift test`, 129 pass / 5 skip)
- `ModelCompatibilityTests`: `.wined3d` round-trip; legacy decode default pinned.
- `LaunchCommandTests`: full-string wined3d command (WINE_D3D_CONFIG in the env
  block, exactly as verified on hardware), `d3d9=b` override, MVK var kept, no
  `DXVK_ASYNC`/`D9MT_*`, launcher variant, negative test that d9vk/d9mt commands
  never set WINE_D3D_CONFIG, and the existing byte-exact d9vk baselines.
- `PatchServiceGamePatchTests`: wined3d staging deletes d3d9.dll; switching back
  to d9vk restores the payload.
- `PatchingStatusCheckerTests`: absent d3d9.dll = Applied under wined3d;
  leftover d3d9.dll = warning.
- `TelemetryRendererTests`: reports `"wined3d"`.
- Hardware verification: the byte-exact generated command (registry confirmed
  clean first) rendered on Apple M5 via MoltenVK 1.4.2 (i686 test PE), with the
  `Using the Vulkan renderer.` winediag marker; without WINE_D3D_CONFIG the
  same command degrades to the no-3D fallback, proving the env var is
  load-bearing.

## Research notes (2026-08-13)
- wined3d's Vulkan renderer became viable for D3D9 only recently: vkd3d 1.11/1.12
  (2024) added SM1-3 → SPIR-V, Wine 10.0 added the HLSL fixed-function pipeline
  for it, Wine 11.0 filled in legacy D3D9 features (point sprites, vertex
  blending, color keying, alpha test, user clip planes, SM1 pixel shaders);
  Wine ≥11.10 bundles vkd3d 2.0. The bundled 11.14 clears the bar.
- The `shader_backend` / `ffp_hlsl` registry values are GL-renderer-only; the
  Vulkan adapter hard-wires its SPIR-V backend — do not set them.
- MoltenVK ≥1.2.5 required (wined3d emits VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN
  directly; MoltenVK emulates it since 1.2.5). Bundled: 1.4.2.
- No public reports of WoW-era D3D9 games on wined3d-vulkan exist on any
  platform — this app's users are the field test; hence the Experimental label.
- Possible future tuning (not implemented, YAGNI): `VideoPciVendorID`/
  `VideoPciDeviceID` spoofing (2005-era games don't recognize Apple's 0x106b),
  `VideoMemorySize`, `MaxShaderModelVS/PS` caps for triaging SM3 glitches —
  all settable through the same WINE_D3D_CONFIG env var or user env field.

## Alternatives considered
- **wined3d GL renderer** — impossible: the runtime is built `--without-opengl`.
- **dgVoodoo2 → D3D11 → DXMT chain** (the setup praised in dxmt#4) — rejected:
  dgVoodoo2 is closed-source freeware whose readme explicitly forbids bundling
  it "inside launchers or frameworks", its author auto-closes Wine bug reports,
  only old pinned versions (~2.79.3) work under Wine at all, and a 32-bit WoW
  client would traverse three translation hops through the chain's least-tested
  configuration (no WoW success report exists). Remains a valid user-side
  experiment; unshippable as a product default.
- **Gallium Nine** — requires Mesa Gallium drivers; none exist on macOS.
- **Valve ToGL** — source library, incomplete SM3, no drop-in DLL, abandoned.

## Explicitly out of scope (YAGNI)
- Per-renderer wined3d tuning keys (`csmt`, `shader_backend`, …).
- Automatic fallback to d9vk on crash.
- Changes to DXVKConfigService (`dxvk.conf` cursor option is inert under
  wined3d, exactly as it is under d9mt).
