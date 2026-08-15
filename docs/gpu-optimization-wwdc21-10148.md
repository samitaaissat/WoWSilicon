# Applying WWDC21 "Optimize high-end games for Apple GPUs" to WoWSilicon

Audit of WoWSilicon's rendering stack against every tip in
[WWDC21 session 10148](https://developer.apple.com/videos/play/wwdc2021/10148/),
plus the changes made as a result.

The session is the closest thing Apple has published to a spec for what
WoWSilicon does. Its second case study — Metro Exodus — is *literally* our
situation: a game whose render commands reach Metal through a translation
layer, where the layer, not the game, owned the two biggest wins (shader
compiler flags and redundant bindings). Our translation layer is **d9mt**
(D3D9 → Metal, fork `samitaaissat/d9mt`, branch `wowsilicon`), so that is
where most of these tips land. The launcher itself only owns tip 1.

Two of the seven tips are addressed to the *game's* own renderer and cannot
be applied by a translation layer at all — we do not author WoW's shaders or
its frame graph. Those are marked N/A below with the reason.

## Summary

| # | Tip | Status |
|---|-----|--------|
| 1 | Have a methodology: measure → target → analyse → improve → verify | **Already in place**, and used for these changes |
| 2 | Split over-general shaders into permutations; cut register pressure | **N/A** — shaders come from the game as DXBC |
| 3 | Don't disable lossless compression with needless usage flags | **Fixed** — was disabled on every colour texture |
| 4 | Reorder the frame graph for vertex/fragment/compute overlap | **N/A** — the game owns pass order |
| 5 | On unified memory, skip the blit to private; ring shared buffers | **Already correct** |
| 6 | Check your shader compiler settings — enable fast math | **Already correct** |
| 7 | Cache bindings; don't re-bind what has not changed | **Partly in place; two gaps closed** |

---

## 1. Methodology — already in place

The session's four steps (choose what to measure, set a target, analyse,
improve one thing at a time, verify against the baseline) are already the
fork's working discipline, written down in its `docs/PERF-ROADMAP.md`
("Benchmark discipline"): interleaved A/B runs, medians not means, never
bench against a loaded host, and revalidate with the test suite before
believing a win.

Launcher side, the measurement surface is already wired:

- **Metal Performance HUD** — the `enableMetalHud` setting sets
  `MTL_HUD_ENABLED` on the launch environment
  ([LaunchService.swift:271](../Sources/WoWSiliconSwift/Services/LaunchService.swift:271)).
  This is Apple's own frame-time/bandwidth overlay, and the same surface
  d9mt's optional in-driver HUD draws onto.
- The fork carries `test/bench.c` (`up`/`vb`/`xform`/`part`/`rt` workload
  modes) plus readback correctness suites (`depthbias`, `resettest`,
  `capstest`, `consttest`, `spectest`).

The one part of the session's toolchain we cannot use directly is the Xcode
GPU Timeline / Metal System Trace demo: the game is an i386 Windows binary
running under Wine under Rosetta, and Xcode cannot attach a GPU capture to
that process. Attribution comes from the fork's own trace zones and the
Metal HUD instead. This is a real limitation, not a solved problem.

**Applied to these changes:** every change below was A/B'd against a
baseline build of the same tree, with the correctness suites run on both.

One refinement worth folding back into the fork's discipline: "interleave
A/B runs" is not sufficient on its own. Running BASE→NEW in that order every
rep, on a host whose frame times drifted downward across the session, biases
systematically toward whichever build runs second — it produced an apparent
27% "win" that evaporated under counterbalancing. Alternate the order
(BASE→NEW, then NEW→BASE) so drift cancels, and report the within-build
spread alongside the medians so a delta smaller than the noise is visible as
such.

## 2. Shader permutations and register pressure — N/A

The session's biggest single win (Baldur's Gate 3, −8 ms) came from Larian
splitting one 4,500-instruction über-shader into focused variants, and from
using `half` where `float` was not needed.

We cannot do this. WoW ships compiled D3D9 shader bytecode; d9mt translates
it (DXBC → SPIR-V → MSL). Rewriting a game's shader into permutations is an
authoring decision, and narrowing float precision to `half` in a translated
shader changes results the game may depend on.

That last point is not hypothetical here. The fork's `spectest` exists
because WoW's 3.3.5 terrain sun-specular shader is numerically fussy —
it pins `pow(x,0)==1` and the `N·H == 0` edge under fast-math MSL against a
CPU D3D reference. Silently halving precision in that path is exactly the
kind of change that suite is designed to catch.

Worth noting the session's own framing: this tip is about *your* shaders.
The Metro Exodus half of the talk — the translation-layer half — is the part
addressed to us, and both of its tips are covered below (6 and 7).

## 3. Lossless compression — fixed

**The tip:** Apple GPUs losslessly compress a texture when it is stored from
tile to device memory, but the `shaderWrite`, `pixelFormatView` and `unknown`
usage flags opt a texture out of it. Set them only when genuinely required.
Specifically: *don't* set `pixelFormatView` just to read components in a
different order (pass a swizzle to `newTextureView` instead), and *don't* set
it for a view that only converts between linear and sRGB.

**What we found:** d9mt set `pixelFormatView` on **every** plain colour
texture — including every render target:

```cpp
// before, d9mt_resources.cpp createImageResource
if (!isDepthStencil && !isCompressed && samples <= 1u)
  usage |= WMTTextureUsagePixelFormatView;
```

The comment gave the reason as "sampled views routinely carry component
swizzles, e.g. X8R8G8B8" — which is precisely the mistake the session calls
out. The swizzle already rides its own argument to `MTLTexture_newTextureView`;
it never needed the usage flag. So every colour texture and render target in
the frame was paying uncompressed bandwidth on every store, for nothing.

`shaderWrite` was already correct — gated on `VK_IMAGE_USAGE_STORAGE_BIT`,
which the d3d9 front-end sets only for formats needing a compute conversion
pass.

This was a deliberate decision, not an accident. `METAL-BACKEND-NOTES.md`
decision 3 spells it out — "PixelFormatView for plain color formats (sampled
views routinely carry swizzles, e.g. X8R8G8B8 alpha-one)… **Lossless-
compression perf impact of blanket PixelFormatView accepted for bring-up**"
— and the separate hand-rolled v1 driver sets the flag whenever
`m_fmtInfo.swizzled` (`src/d3d9/d3d9.cpp:606`). So the question is not "did
someone forget", it is "is the bring-up assumption actually true".

**The complication.** Apple's `MTLTextureUsage.pixelFormatView` reference
docs say the flag is needed for "a texture view with a different **component
layout**" — and a swizzle *is* a component layout change — while the session
says the opposite for both swizzles and linear↔sRGB. The sources disagree,
and the disagreement decides essentially every WoW texture. Guess wrong in
the permissive direction and the change does nothing; guess the other way and
views return null — black textures, not a slow frame.

**So we do not guess — we measured, on the target machine.** Standalone
Metal probes were run on this M5 / macOS 27 with **Metal API validation and
GPU validation enabled**:

- A same-format, non-identity-**swizzle** view of a `shaderRead`-only texture
  (no `pixelFormatView`) is created successfully for every format that
  matters here — `R8Unorm` (L8), `RG8Unorm` (A8L8), `A8Unorm`, `ABGR4Unorm`
  (A4R4G4B4), `B5G6R5Unorm`, `BGR5A1Unorm` (X1R5G5B5), `RG8Snorm` (V8U8),
  `BGRA8Unorm` (X8R8G8B8), `RGBA8Unorm` — with no validation diagnostic.
- It is not merely accepted but **honoured**: sampling a `BGRA8Unorm` texel
  `{B=10, G=20, R=30, A=40}` through an unflagged `{R,G,B,One}` view returns
  `{30/255, 20/255, 10/255, 1.0}` — correct.
- A lossless-compression-eligible `shaderRead|renderTarget` texture, cleared
  by a real render pass and then read back through a `(G,B,A,R)` view without
  the flag, returns the correct values — so reinterpreting *compressed*
  contents is fine too.

So the session is right and the bring-up assumption was wrong: swizzle-only
views never needed the flag. `d3d9.cpp:606` is defensive, not required — and
that same driver contradicts it, creating a genuinely cross-format sRGB view
on textures allocated **without** the flag (`d3d9.cpp:3068`, the backbuffer
proxy, and `SrgbGpuId()` at `:639`).

The driver still probes the sRGB case once at first use, with a throwaway
1×1 texture, rather than hard-coding the answer. On this machine it logs:

```
info:  d9mt: sRGB views work without pixelFormatView (lossless compression kept on colour textures)
```

The probe fails **safe** in every direction — no device, texture creation
failure, or view creation failure all yield "flag needed". This mirrors how
the fork already settles other Apple-behaviour questions (the winemetal
raw-handle probe, the Metal 4 availability probe) instead of trusting
documentation.

**Changes:**

- `createImageResource` now sets `pixelFormatView` only when a genuine
  differing-format view is possible: the image must be `MUTABLE_FORMAT`
  *and* its view-format list must contain a format that is not just the
  sRGB counterpart (or the probe must say sRGB needs the flag).
- `DxvkImage::allocateStorageWithUsage` now chains a
  `VkImageFormatListCreateInfo` down to the allocator. It previously dropped
  the list — fine when usage was blanket-permissive, but the allocator now
  needs to know *which* formats are involved, not just that the image is
  mutable.
- `D9MT_PIXELFORMATVIEW=1` restores the old blanket behaviour if a
  narrowing regression ever shows up in the field.
- **Correctness safety net:** `DxvkContext::copyImage` aliases its
  *destination* with the source's format for cross-format copies, which
  needs the flag on that destination. It previously assumed every colour
  texture had it and dropped the copy with an error if the alias failed.
  It now falls back to a scratch texture that does have the flag
  (src → scratch aliased in the source format, then scratch → dst as a
  same-format copy — both raw-bit, so the result is identical). Correctness
  no longer depends on the usage policy at all.

  To be precise about what this is worth: a cross-format `copyImage` is not
  currently reachable from this front-end. `StretchRect`'s fast path is
  gated on `AreFormatsSimilar`, whose four admitted pairs all map to the
  *same* VkFormat (X8R8G8B8 and A8R8G8B8 are both `B8G8R8A8_UNORM`, differing
  only in the alpha swizzle); `blitImageView`'s copy funnel requires equal
  formats; and `ResolveZ` is depth-only and rejected earlier. So this is
  defensive code for a branch that is shut today — it exists so the usage
  policy is not load-bearing for correctness if that ever changes.

**Expected impact — honestly:** probably no frame-rate change on Apple
silicon today. The fork's measurements have this driver firmly CPU-bound,
with GPU time under 1 ms/frame, so bandwidth is not the binding constraint.
The win is memory bandwidth, power, and headroom — it matters on the lowest
Apple silicon tiers, at 5K, and under thermal pressure, and it stops us
carrying a defect Apple explicitly warns about. It was not sold as a
frame-time fix and should not be reported as one.

## 4. Frame-graph reordering for channel overlap — N/A

The session moves a vertex-heavy shadow pass earlier to fill a gap in the
vertex channel (+1 ms). That is a change to the *game's* pass order. WoW
issues its passes in its own order and we execute them; reordering them in a
translation layer would reorder rendering the game asked for.

The adjacent thing we *can* control — the cost of switching between passes —
is already done: payload v4 fuses each encoder transition
(`endEncoding` + release + pool + create + retain, 6–7 winemetal crossings)
into a single `D9MT_FUNC_PASS_TRANSITION` crossing, worth ~15% of frame time
in the render-target round-trip workload that models WoW's shadow blobs.

## 5. Unified memory: no blit to private — already correct

The session's Baldur's Gate 3 fix was to stop blitting constant data from a
shared staging buffer into a private GPU buffer on unified-memory devices,
and to add one extra buffer to the ring so the CPU never waits on the
completion handler.

d9mt already does the right thing, and structurally cannot do the wrong one:
**every** d9mt buffer is created `WMTResourceStorageModeShared`
(`createBufferResource`; textures are `Private`, which is correct). There is
no shared→private constant upload path and no blit encoder in the constant
path — per-draw constants are carved out of a shared ring buffer and bound
directly. The device is always Apple silicon, so the discrete-GPU branch the
session describes never applies.

No change needed.

## 6. Shader compiler settings / fast math — already correct

This is the Metro Exodus finding: the translation layer 4A Games used had
defaulted fast math *off*, and turning it on was worth 21% frame time.

d9mt compiles MSL with fast math on, unconditionally, in both compile paths
(`src/d9mtmetal/unix.m`: `opts.mathMode = MTLMathModeFast` in the live
`newLibraryWithSource` path and the async path, `-ffast-math` in the
metallib path), and the fast-math flag is part of the shader cache key so
the two paths cannot disagree.

The fork has also already paid the debt this tip creates: `spectest`
validates WoW's real terrain sun-specular shader pair against a CPU D3D
reference *under* fast-math MSL, including the `pow(x,0)` and `N·H == 0`
edges. The in-code comment states the policy explicitly — a precision
artifact under fast math is a per-shader translation bug to fix in the
SPIR-V→MSL path, not a reason to slow every game's math down globally.

No change needed.

## 7. Redundant bindings — partly in place, two gaps closed

**The tip:** cache what you have bound and skip the re-bind when it has not
changed. Hundreds or thousands of redundant bindings cost both encoding time
and GPU time (4A Games: −30–50% encode, −15% frame time).

**Already in place.** This is the fork's main line of work, and the encoder
already keeps a dedupe shadow: `lastRenderPso`, `lastRenderDsso`,
`lastSamplerHeap[2]`, a flat `renderResident` residency set, and the payload-v4
`PushBindCache` (per-stage content shadow + `memcmp`, so unchanged push bytes
skip the ring section and the encode entirely). Most dynamic state is
additionally gated behind per-item dirty flags, and `updateDynamicState`
early-outs when none are set.

Note that re-emitting everything *after a render-pass restart* is not
redundant — Metal encoder state does not survive its encoder, so a fresh
encoder genuinely must be re-armed. All the caching below is correctly
scoped to a single encoder.

**Gap 1 — `setViewports` never compared.** Every other dynamic-state setter
in the file compares before dirtying; this one always set
`GpDirtyViewport`. The d3d9 front-end re-binds the viewport whenever its own
dirty bit fires, and that bit is re-armed by things that usually do not move
the rect at all (every `SetRenderTarget`, every scissor toggle) — so each
no-op call emitted a `SetViewport` *and* a `SetScissorRect` into the command
arena. Now compared before dirtying. A pass restart re-dirties the flag
independently, so a fresh encoder can never be left without its viewport.

**Gap 2 — vertex buffers re-bound wholesale.** `updateVertexBufferBindings`
re-emitted *every* binding whenever `GpDirtyVertexBuffers` fired, and that
flag is a whole-layout bit: a `SetStreamSource` on one stream, or an input
layout change that moved nothing, re-bound all of them. There is now a
per-slot `(buffer, offset)` shadow in `CmdListState`, self-invalidating on
`encoderEpoch` so it only ever describes the current encoder. Resource
tracking still runs on the skip path, so residency and lifetime are
unaffected — only the redundant arena command goes away.

---

## Verification

Built `RELEASE=1` and run against the WoWSilicon bundled Wine runtime
(M5, macOS 27, x86_64 under Rosetta 2) in a throwaway prefix:

| Suite | Result |
|---|---|
| `depthbias.exe` | PASS (D3D9 raw-offset depth bias semantics) |
| `resettest.exe` | PASS — output **byte-identical** to baseline (full fullscreen Reset ladder) |
| `capstest.exe` | Output **byte-identical** to baseline — caps and all 15 format probes unchanged |

Byte-identical `capstest` output matters specifically for tip 3: narrowing
texture usage did not change any advertised format capability.

`consttest` and `spectest` could not be run here — they need SM3 bytecode
blobs that are deliberately not committed to the fork (`spectest`'s are
extracted from game files). They should be run on a machine that has them,
along with a real game boot, before the payload ships.

### Adversarial review

The diff was put through a four-lens adversarial review (object lifetime,
dirty-flag state machine, missing-`pixelFormatView` reachability,
concurrency/cache scope), with every finding then independently attacked.
Fourteen candidate defects were raised; none survived. Two of the
refutations were settled by writing and running standalone Metal probes on
this machine rather than by argument — that is where the swizzle evidence
above comes from.

Two genuine warts surfaced along the way and are fixed:

- `copyImage`'s scratch path could return from inside the per-layer loop
  after earlier layers had already encoded blits, skipping the
  `m_cmd->track` calls that sat after the loop. Tracking is now hoisted
  above the loop.
- `d9mtIsSrgbCounterpart` masks off swizzle-marker bits before comparing, so
  two formats differing *only* in those bits would have been taken for an
  sRGB pair. No such value is reachable today (the format-caps table holds
  plain enums only), but it is now rejected explicitly, and it fails the safe
  way — not a pair means the flag is kept.

### Performance

**No measurable frame-time change, and the benchmark cannot show one.**

Counterbalanced interleaved A/B (alternating which build runs first each
rep, so session drift cancels), `up` mode, 16k draws × 200 frames, 6 pairs:
median 33.13 ms baseline vs 31.28 ms, but the spread *within* each build
alone was 11.5 ms and 23.5 ms, and the means are identical (33.60 vs 33.54).
That is noise, not a result, and it is not reported as one.

The benchmark structurally cannot exercise either tip-7 change:
`test/bench.c` calls `SetStreamSource` **once at setup** (`bench.c:170`),
never per draw, so the vertex-bind shadow has nothing to elide; and `rt`
mode's `SetRenderTarget` pairs alternate between a small render target and
the backbuffer, so the viewport genuinely changes every time and the
compare never fires. The redundancy these changes remove is a real-frame
pattern — WoW's UI and world batches re-issuing identical stream sources and
viewports — which is exactly what roadmap candidate #1 (trace-guided WoW
capture) exists to measure. Until that lands, these are justified as
provably-redundant work removed with no regression, not as a measured win.

The same honesty applies to tip 3: with GPU time under 1 ms/frame, restoring
lossless compression should not move frame rate on this class of machine. It
buys bandwidth, power and headroom.

## Shipping this

The renderer changes live in the d9mt fork, not in this repo. To ship them:

1. Land the changes on `samitaaissat/d9mt` branch `wowsilicon`.
2. Update `D9MT_COMMIT` in [tools/d9mt/build-payload.sh](../tools/d9mt/build-payload.sh).
3. `PAYLOAD_VERSION=5 bash tools/d9mt/build-payload.sh`.
4. Publish the tarball on a `runtime-v*` release.
5. Bump `D9MT_VERSION` / `D9MT_SHA256` / `D9MT_URL` in the `Makefile`
   together, in one commit (see [docs/releasing.md](releasing.md)).

Steps 1 and 4 publish to GitHub and are left to a human.
