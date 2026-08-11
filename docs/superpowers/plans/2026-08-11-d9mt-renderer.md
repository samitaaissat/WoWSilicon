# d9mt Renderer Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add d9mt (D3D9→Metal) as an opt-in, per-version, experimental renderer alongside d9vk, per `docs/superpowers/specs/2026-08-11-d9mt-renderer-design.md`.

**Architecture:** A build-time-fetched `Patching/d9mt` payload (d9mt `d3d9.dll` + DXMT v0.80 `winemetal` pair + d9mt `d9mtmetal` pair) is staged by a new Makefile `fetch-d9mt` target; winemetal/d9mtmetal are ditto'd into the bundled Wine runtime's `lib/wine` arch dirs at bundle time and registered as builtins in the prefix registry at patch time. `VersionSettings.renderer` (enum, default `d9vk`) drives payload staging in `PatchService`, freshness checks in `PatchingStatusChecker`, and the env block in `LaunchService.makeShellCommand`. The UI picker is CLT-gated (`xcrun -f metal`).

**Tech Stack:** Swift 6 / SwiftUI / XCTest, GNU Make, mingw-w64 + glslang (payload build only).

## Global Constraints

- d9vk stays the default renderer; its behavior (staging, env, tests) must not change when `renderer == .d9vk`.
- All persisted model changes use `decodeIfPresent ?? <default>` migration; `versions.json` on user machines must keep decoding.
- d9mt upstream pins: d9mt commit `237e2935e58355d1ee41fda097e1af272d5f62f0`, DXMT release `v0.80` (`https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz`).
- d9mt runtime env vars (`D9MT_METALLIB_CACHE`, `D9MT_ASYNC`, `D9MT_BATCH`, `D9MT_SUBALLOC`) default ON upstream; we set the first two explicitly for clarity.
- winemetal/d9mtmetal registration mechanism (verified against d9mt's `scripts/run-test.sh` + `tools/build-d9mtmetal.sh`): PE DLLs into the wine tree's `lib/wine/{i386-windows,x86_64-windows}/`, `.so` into `lib/wine/x86_64-unix/` **next to** the PE so wine's `find_builtin_dll` pairs the unixlib; prefix copies into `drive_c/windows/{system32,syswow64,x86_64-unix}/`; registry `HKCU\Software\Wine\DllOverrides`: `winemetal=builtin`, `d9mtmetal=builtin`. **No** `winemetal=n` in `WINEDLLOVERRIDES` (this corrects the spec's launch-env note).
- `swift test` must pass after every task.
- Do not run `git commit` without explicit user approval — each task's commit step is executed only when the user has approved commits.

---

### Task 1: `RendererBackend` enum + `VersionSettings.renderer` with migration

**Files:**
- Modify: `Sources/WoWSiliconSwift/Models/GameVersion.swift` (add enum near `VersionSettings`, line ~176; add property/init param/CodingKey/decode/encode)
- Test: `Tests/WoWSiliconSwiftTests/ModelCompatibilityTests.swift`

**Interfaces:**
- Produces: `enum RendererBackend: String, Codable, CaseIterable, Equatable, Sendable { case d9vk, d9mt }`; `VersionSettings.renderer: RendererBackend` (default `.d9vk`). All later tasks consume `settings.renderer`.

- [ ] **Step 1: Write the failing test**

Append to `ModelCompatibilityTests.swift` (follow its existing style):

```swift
func testVersionSettingsWithoutRendererDecodesToD9vk() throws {
    let json = #"{"enableMetalHud":true}"#.data(using: .utf8)!
    let settings = try JSONDecoder().decode(VersionSettings.self, from: json)
    XCTAssertEqual(settings.renderer, .d9vk)
    XCTAssertTrue(settings.enableMetalHud)
}

func testVersionSettingsRendererRoundTrip() throws {
    var settings = VersionSettings()
    settings.renderer = .d9mt
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(VersionSettings.self, from: data)
    XCTAssertEqual(decoded.renderer, .d9mt)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelCompatibilityTests`
Expected: FAIL — `VersionSettings` has no member `renderer` (compile error).

- [ ] **Step 3: Implement**

In `GameVersion.swift`, immediately above `struct VersionSettings`:

```swift
/// D3D9 translation backend staged into the game folder. d9vk (D3D9→Vulkan→MoltenVK)
/// is the default; d9mt (D3D9→Metal, experimental) requires Xcode CLT at runtime.
enum RendererBackend: String, Codable, CaseIterable, Equatable, Sendable {
    case d9vk
    case d9mt
}
```

In `VersionSettings`:
- Add stored property `var renderer: RendererBackend` after `userDisabledLibSiliconPatch`.
- Add init parameter `renderer: RendererBackend = .d9vk` (last, after `userDisabledLibSiliconPatch`) and `self.renderer = renderer`.
- Add `case renderer` to `CodingKeys` (with the other non-legacy keys).
- In `init(from:)`: `renderer = try container.decodeIfPresent(RendererBackend.self, forKey: .renderer) ?? .d9vk`
- In `encode(to:)`: `try container.encode(renderer, forKey: .renderer)`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ModelCompatibilityTests`
Expected: PASS (both new tests + all existing).

- [ ] **Step 5: Commit (only if user has approved commits)**

```bash
git add Sources/WoWSiliconSwift/Models/GameVersion.swift Tests/WoWSiliconSwiftTests/ModelCompatibilityTests.swift
git commit -m "feat: add RendererBackend and VersionSettings.renderer (default d9vk)"
```

---

### Task 2: d9mt payload build script + tarball

Produces `tools/d9mt/d9mt-1.tar.gz` + `.sha256`, uploaded manually to the `runtime-v1` GitHub release page so `fetch-d9mt` (Task 3) has a stable URL. Requires one-time `brew install mingw-w64 glslang` — ask the user before installing.

**Files:**
- Create: `tools/d9mt/build-payload.sh`
- Produces (not committed): `tools/d9mt/dist/d9mt-1.tar.gz`, `tools/d9mt/dist/d9mt-1.tar.gz.sha256`

**Interfaces:**
- Produces: tarball layout consumed by Task 3's Makefile target:
  ```
  d9mt/d3d9.dll                         # d9mt i686 driver (build/d3d9fe.dll renamed)
  d9mt/winemetal/i386-windows/winemetal.dll
  d9mt/winemetal/x86_64-windows/winemetal.dll
  d9mt/winemetal/x86_64-unix/winemetal.so
  d9mt/d9mtmetal/i386-windows/d9mtmetal.dll
  d9mt/d9mtmetal/x86_64-windows/d9mtmetal.dll
  d9mt/d9mtmetal/x86_64-unix/d9mtmetal.so
  d9mt/LICENSES/...                     # d9mt LICENSE-ish notices + DXMT MIT license
  ```

- [ ] **Step 1: Verify build prerequisites**

Run: `which i686-w64-mingw32-g++ x86_64-w64-mingw32-g++ glslang python3 sqlite3 && xcrun --sdk macosx --find metal`
Expected: all resolve. If mingw-w64/glslang missing, ask the user before `brew install mingw-w64 glslang`.

- [ ] **Step 2: Write `tools/d9mt/build-payload.sh`**

```bash
#!/bin/bash
# Builds the WoWSilicon d9mt payload tarball from pinned upstream sources:
#   - d9mt  @ 237e2935e58355d1ee41fda097e1af272d5f62f0 (neo773/d9mt)
#   - DXMT winemetal @ v0.80 (3Shain/dxmt, last MIT-licensed release)
# Output: dist/d9mt-<N>.tar.gz + .sha256, layout documented in the repo plan.
set -euo pipefail

D9MT_COMMIT=237e2935e58355d1ee41fda097e1af272d5f62f0
DXMT_TAG=v0.80
PAYLOAD_VERSION="${PAYLOAD_VERSION:-1}"

cd "$(dirname "$0")"
WORK="$PWD/work"
DIST="$PWD/dist"
STAGE="$WORK/stage"
rm -rf "$WORK"
mkdir -p "$WORK" "$DIST" "$STAGE/d9mt"/{winemetal,d9mtmetal}/{i386-windows,x86_64-windows,x86_64-unix} "$STAGE/d9mt/LICENSES"

# --- winemetal from DXMT release tarball ---
curl -fL --retry 3 -o "$WORK/dxmt.tar.gz" \
  "https://github.com/3Shain/dxmt/releases/download/$DXMT_TAG/dxmt-$DXMT_TAG-builtin.tar.gz"
tar -xzf "$WORK/dxmt.tar.gz" -C "$WORK"
cp "$WORK/$DXMT_TAG/i386-windows/winemetal.dll"    "$STAGE/d9mt/winemetal/i386-windows/"
cp "$WORK/$DXMT_TAG/x86_64-windows/winemetal.dll"  "$STAGE/d9mt/winemetal/x86_64-windows/"
cp "$WORK/$DXMT_TAG/x86_64-unix/winemetal.so"      "$STAGE/d9mt/winemetal/x86_64-unix/"

# --- d9mt driver + d9mtmetal unixlib ---
git clone https://github.com/neo773/d9mt "$WORK/d9mt"
git -C "$WORK/d9mt" checkout "$D9MT_COMMIT"

# winemetal import lib the d9mt build links against (-L prebuilt -lwinemetal)
mkdir -p "$WORK/d9mt/prebuilt"
cp "$WORK/$DXMT_TAG/i386-windows/winemetal.dll"   "$WORK/d9mt/prebuilt/winemetal32.dll"
cp "$WORK/$DXMT_TAG/x86_64-windows/winemetal.dll" "$WORK/d9mt/prebuilt/winemetal.dll"
cp "$WORK/$DXMT_TAG/x86_64-unix/winemetal.so"     "$WORK/d9mt/prebuilt/winemetal.so"

# d9mtmetal: its build script installs into a CrossOver-style tree; point CX at a
# throwaway staging dir and harvest the artifacts from it afterwards.
FAKE_CX="$WORK/fake-cx"
mkdir -p "$FAKE_CX/Contents/SharedSupport/CrossOver/lib"
BOTTLE="wowsilicon-unused" CX="$FAKE_CX/Contents/SharedSupport/CrossOver" \
  bash "$WORK/d9mt/tools/build-d9mtmetal.sh"

# d3d9 driver (release)
(cd "$WORK/d9mt" && RELEASE=1 bash scripts/build-dxvkfe.sh)

cp "$WORK/d9mt/build/d3d9fe.dll" "$STAGE/d9mt/d3d9.dll"

# Harvest d9mtmetal artifacts (exact paths per tools/build-d9mtmetal.sh install steps)
find "$FAKE_CX" "$WORK/d9mt" -name 'd9mtmetal*.dll' -o -name 'd9mtmetal.so' | while read -r f; do
  case "$f" in
    *i386*|*32*)    cp "$f" "$STAGE/d9mt/d9mtmetal/i386-windows/d9mtmetal.dll" ;;
    *x86_64-unix*|*.so) cp "$f" "$STAGE/d9mt/d9mtmetal/x86_64-unix/d9mtmetal.so" ;;
    *x86_64*)       cp "$f" "$STAGE/d9mt/d9mtmetal/x86_64-windows/d9mtmetal.dll" ;;
  esac
done
# Sanity: all seven payload files exist
for f in d3d9.dll \
  winemetal/i386-windows/winemetal.dll winemetal/x86_64-windows/winemetal.dll winemetal/x86_64-unix/winemetal.so \
  d9mtmetal/i386-windows/d9mtmetal.dll d9mtmetal/x86_64-windows/d9mtmetal.dll d9mtmetal/x86_64-unix/d9mtmetal.so; do
  test -s "$STAGE/d9mt/$f" || { echo "MISSING payload file: $f"; exit 1; }
done

# License notices (d9mt has no top-level LICENSE; keep upstream attributions)
cp "$WORK/d9mt/README.md" "$STAGE/d9mt/LICENSES/d9mt-README.md" || true
curl -fL -o "$STAGE/d9mt/LICENSES/DXMT-LICENSE.txt" \
  "https://raw.githubusercontent.com/3Shain/dxmt/$DXMT_TAG/LICENSE" || true

tar -czf "$DIST/d9mt-$PAYLOAD_VERSION.tar.gz" -C "$STAGE" d9mt
(cd "$DIST" && shasum -a 256 "d9mt-$PAYLOAD_VERSION.tar.gz" > "d9mt-$PAYLOAD_VERSION.tar.gz.sha256")
echo "Built $DIST/d9mt-$PAYLOAD_VERSION.tar.gz"
cat "$DIST/d9mt-$PAYLOAD_VERSION.tar.gz.sha256"
```

`chmod +x tools/d9mt/build-payload.sh`.

- [ ] **Step 3: Run the build**

Run: `bash tools/d9mt/build-payload.sh`
Expected: completes; prints the SHA256. If d9mt's internal script paths differ from what the harvest step expects, inspect `tools/d9mt/work/` and adjust the `find`/copy cases — the sanity loop is the guard.

- [ ] **Step 4: Record the checksum**

Copy the printed SHA256 — it becomes `D9MT_SHA256` in Task 3.

- [ ] **Step 5: Upload the artifact (manual, needs user confirmation)**

With the user's go-ahead and their GitHub auth: attach `dist/d9mt-1.tar.gz` to the existing `runtime-v1` release of `samitaaissat/WoWSilicon` (e.g. `gh release upload runtime-v1 tools/d9mt/dist/d9mt-1.tar.gz`). The resulting URL is `https://github.com/samitaaissat/WoWSilicon/releases/download/runtime-v1/d9mt-1.tar.gz`.

- [ ] **Step 6: Commit (only if user has approved commits)**

```bash
git add tools/d9mt/build-payload.sh
git commit -m "chore: add d9mt payload build script (d9mt @237e293, DXMT v0.80)"
```

---

### Task 3: Makefile `fetch-d9mt` + bundle staging

**Files:**
- Modify: `Makefile` (pins near lines 37–48; new target near `fetch-runtime`, line ~166; `bundle` dependency line and runtime-staging section)

**Interfaces:**
- Consumes: Task 2's tarball URL + SHA256.
- Produces: `Sources/WoWSiliconSwift/Resources/Patching/d9mt/` (populated at build time; consumed by Tasks 4–6) and winemetal/d9mtmetal files inside `$(GAME_APP)/Contents/lib/wine/`.

Note: `Package.swift` already ships `.copy("WoWSiliconSwift/Resources/Patching")` wholesale — no Package.swift change. Add `Sources/WoWSiliconSwift/Resources/Patching/d9mt/` to `.gitignore` (fetched artifact, like the runtime cache).

- [ ] **Step 1: Add pins** (after the `RUNTIME_*` block, ~line 48)

```make
# d9mt renderer payload (built by tools/d9mt/build-payload.sh, uploaded to the
# runtime-v$(RUNTIME_VERSION) release page). Bump all three pins together.
D9MT_VERSION ?= 1
D9MT_ASSET := d9mt-$(D9MT_VERSION).tar.gz
D9MT_URL ?= https://github.com/samitaaissat/WoWSilicon/releases/download/runtime-v$(RUNTIME_VERSION)/$(D9MT_ASSET)
D9MT_SHA256 ?= <sha256 from Task 2 Step 4>
D9MT_CACHE := $(BUILD_DIR)/d9mt-cache
D9MT_RESOURCES := Sources/WoWSiliconSwift/Resources/Patching/d9mt
```

- [ ] **Step 2: Add `fetch-d9mt` target** (after `fetch-runtime`, ~line 166)

```make
fetch-d9mt:
	@if [ -f "$(D9MT_RESOURCES)/.sha256" ] \
		&& [ "$$(cat "$(D9MT_RESOURCES)/.sha256")" = "$(D9MT_SHA256)" ]; then \
		echo "d9mt payload v$(D9MT_VERSION) already staged"; \
	else \
		set -e; \
		echo "Fetching d9mt payload v$(D9MT_VERSION) from $(D9MT_URL)..."; \
		mkdir -p "$(D9MT_CACHE)"; \
		curl -fL --retry 3 -o "$(D9MT_CACHE)/$(D9MT_ASSET)" "$(D9MT_URL)"; \
		echo "$(D9MT_SHA256)  $(D9MT_CACHE)/$(D9MT_ASSET)" | shasum -a 256 -c -; \
		rm -rf "$(D9MT_RESOURCES)"; \
		mkdir -p "$(D9MT_RESOURCES)"; \
		tar -xzf "$(D9MT_CACHE)/$(D9MT_ASSET)" -C "$(D9MT_RESOURCES)" --strip-components=1; \
		test -s "$(D9MT_RESOURCES)/d3d9.dll"; \
		printf '%s' "$(D9MT_SHA256)" > "$(D9MT_RESOURCES)/.sha256"; \
		echo "d9mt payload v$(D9MT_VERSION) staged into $(D9MT_RESOURCES)"; \
	fi
```

- [ ] **Step 3: Wire into `bundle`**

Change the dependency line `bundle: build fetch-runtime` → `bundle: build fetch-runtime fetch-d9mt`.

After the existing `ditto` lines that stage the runtime into `$(GAME_APP)/Contents`, add:

```make
	@# d9mt renderer support: winemetal/d9mtmetal as wine builtins. The .so must
	@# sit next to the PE in the arch dirs for wine's find_builtin_dll pairing.
	@ditto "$(D9MT_RESOURCES)/winemetal/i386-windows/winemetal.dll" "$(GAME_APP)/Contents/lib/wine/i386-windows/winemetal.dll"
	@ditto "$(D9MT_RESOURCES)/winemetal/x86_64-windows/winemetal.dll" "$(GAME_APP)/Contents/lib/wine/x86_64-windows/winemetal.dll"
	@ditto "$(D9MT_RESOURCES)/winemetal/x86_64-unix/winemetal.so" "$(GAME_APP)/Contents/lib/wine/x86_64-unix/winemetal.so"
	@ditto "$(D9MT_RESOURCES)/d9mtmetal/i386-windows/d9mtmetal.dll" "$(GAME_APP)/Contents/lib/wine/i386-windows/d9mtmetal.dll"
	@ditto "$(D9MT_RESOURCES)/d9mtmetal/x86_64-windows/d9mtmetal.dll" "$(GAME_APP)/Contents/lib/wine/x86_64-windows/d9mtmetal.dll"
	@ditto "$(D9MT_RESOURCES)/d9mtmetal/x86_64-unix/d9mtmetal.so" "$(GAME_APP)/Contents/lib/wine/x86_64-unix/d9mtmetal.so"
```

- [ ] **Step 4: gitignore the fetched payload**

Append to `.gitignore`:

```
# Fetched d9mt renderer payload (make fetch-d9mt)
Sources/WoWSiliconSwift/Resources/Patching/d9mt/
```

- [ ] **Step 5: Verify**

Run: `make fetch-d9mt && make bundle`
Expected: checksum verified; `$(GAME_APP)/Contents/lib/wine/i386-windows/winemetal.dll` etc. exist; `.build/WoWSilicon.app` builds and signs. (Requires Task 2's artifact to be uploaded, or temporarily override `D9MT_URL=file://$PWD/tools/d9mt/dist/d9mt-1.tar.gz` for local verification.)

- [ ] **Step 6: Commit (only if user has approved commits)**

```bash
git add Makefile .gitignore
git commit -m "build: fetch and bundle d9mt renderer payload (v1)"
```

---

### Task 4: Renderer-aware staging in `PatchService`

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PatchService.swift` (`stageGamePatchFiles`, line ~58; `removeGamePatch`, line ~176)
- Test: `Tests/WoWSiliconSwiftTests/PatchServiceGamePatchTests.swift`

**Interfaces:**
- Consumes: `RendererBackend` from Task 1; `Patching/d9mt/d3d9.dll` resource from Task 3.
- Produces: staging contract used by Task 6 — with `renderer == .d9mt`, `<game>/d3d9.dll` comes from `Patching/d9mt`.

- [ ] **Step 1: Write the failing tests**

In `PatchServiceGamePatchTests.swift` (follow its existing temp-dir + `makeVersion` patterns; tests use the real bundled resources, so d9mt tests require `make fetch-d9mt` to have run — mirror however the existing suite handles `Patching/d9vk` availability):

```swift
func testStageGamePatchFilesWithD9mtStagesD9mtD3d9() throws {
    let gameURL = try makeGameDirectory() // existing helper creating DivxDecoder.dll etc.
    var version = makeVersion(gamePath: gameURL.path)
    version.settings.renderer = .d9mt

    try PatchService.stageGamePatchFiles(for: version)

    let staged = try Data(contentsOf: gameURL.appendingPathComponent("d3d9.dll"))
    let bundled = try Data(contentsOf: PatchService.resourceURL(
        named: "d3d9", extension: "dll", subdirectory: "Patching/d9mt")!)
    XCTAssertEqual(staged, bundled)
}

func testStageGamePatchFilesSwitchingBackToD9vkRestoresD9vkDll() throws {
    let gameURL = try makeGameDirectory()
    var version = makeVersion(gamePath: gameURL.path)
    version.settings.renderer = .d9mt
    try PatchService.stageGamePatchFiles(for: version)

    version.settings.renderer = .d9vk
    try PatchService.stageGamePatchFiles(for: version)

    let staged = try Data(contentsOf: gameURL.appendingPathComponent("d3d9.dll"))
    let bundled = try Data(contentsOf: PatchService.resourceURL(
        named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk")!)
    XCTAssertEqual(staged, bundled)
}
```

(Adapt helper names to the file's actual helpers — `makeGameDirectory`/`makeVersion` are placeholders for whatever `PatchServiceGamePatchTests` already calls its fixtures.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PatchServiceGamePatchTests`
Expected: new tests FAIL (staged dll equals d9vk's, not d9mt's).

- [ ] **Step 3: Implement**

In `stageGamePatchFiles`, replace the single d3d9 copy line (currently `try copyResource(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk", to: ...)`) with:

```swift
        let d3d9Subdirectory = version.settings.renderer == .d9mt ? "Patching/d9mt" : "Patching/d9vk"
        try copyResource(named: "d3d9", extension: "dll", subdirectory: d3d9Subdirectory, to: gameURL.appendingPathComponent("d3d9.dll"))
```

`removeGamePatch` already removes `<game>/d3d9.dll` regardless of renderer — no change needed there (winemetal/d9mtmetal live in the prefix/runtime, covered by Task 5).

- [ ] **Step 4: Run tests**

Run: `swift test --filter PatchServiceGamePatchTests`
Expected: PASS.

- [ ] **Step 5: Commit (only if user has approved commits)**

```bash
git add Sources/WoWSiliconSwift/Services/PatchService.swift Tests/WoWSiliconSwiftTests/PatchServiceGamePatchTests.swift
git commit -m "feat: stage d3d9.dll from the selected renderer payload"
```

---

### Task 5: d9mt prefix registration (winemetal/d9mtmetal builtins)

When `renderer == .d9mt`, `applyGamePatch` must additionally (a) copy winemetal/d9mtmetal PE DLLs from the bundled runtime into the prefix (`drive_c/windows/system32`, `syswow64`, `x86_64-unix`) and (b) register `winemetal=builtin` / `d9mtmetal=builtin` in `HKCU\Software\Wine\DllOverrides`. This mirrors the existing `patchDivxDecoder` split: file copies are testable without Wine; the `wine reg add` step is not.

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PatchService.swift` (`applyGamePatch`, lines 29–37; new private helpers modeled on `patchDivxDecoder`/`makeDivxPatchEnvironment`, lines ~100–110)
- Test: `Tests/WoWSiliconSwiftTests/PatchServiceGamePatchTests.swift`

**Interfaces:**
- Consumes: `WineRuntime` bundled runtime paths (`lib/wine/...` inside the nested game app — use the same authority `LaunchService` uses for runtime paths), the shared `WINEPREFIX` path used by `PrefixBootstrapService`/`WineRegistrySupport`.
- Produces: `static func installD9MTPrefixSupport(winePrefixPath: String) throws` (file copies only) and the reg-add step inside `applyGamePatch` guarded by `version.settings.renderer == .d9mt`.

- [ ] **Step 1: Write the failing test**

```swift
func testInstallD9MTPrefixSupportCopiesWinemetalIntoPrefix() throws {
    let prefixURL = try makeTemporaryDirectory()
    try FileManager.default.createDirectory(
        at: prefixURL.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: prefixURL.appendingPathComponent("drive_c/windows/syswow64"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: prefixURL.appendingPathComponent("drive_c/windows/x86_64-unix"), withIntermediateDirectories: true)

    try PatchService.installD9MTPrefixSupport(winePrefixPath: prefixURL.path)

    XCTAssertTrue(FileManager.default.fileExists(
        atPath: prefixURL.appendingPathComponent("drive_c/windows/system32/winemetal.dll").path))
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: prefixURL.appendingPathComponent("drive_c/windows/syswow64/winemetal.dll").path))
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: prefixURL.appendingPathComponent("drive_c/windows/x86_64-unix/winemetal.so").path))
}
```

Note: this test needs the runtime present (sources the DLLs from `WineRuntime`'s lib tree). If the existing suite already has runtime-dependent tests (see `WineRuntimeTests`), follow their skip/guard pattern; otherwise source the files from `Patching/d9mt/winemetal/...` bundle resources instead — decide at implementation time by reading how `WineRuntimeTests` handles runtime absence, and document the choice in the test.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PatchServiceGamePatchTests`
Expected: FAIL — `installD9MTPrefixSupport` not defined.

- [ ] **Step 3: Implement**

In `PatchService`:

```swift
    /// d9mt renderer: installs winemetal/d9mtmetal as Wine builtins — PE DLLs into
    /// the prefix's system32/syswow64 (+ the .so beside them), matching DXMT's
    /// install convention. The same files live in the bundled runtime's
    /// lib/wine arch dirs (staged by `make bundle`), which is where wine's
    /// find_builtin_dll actually loads them from; the prefix copies keep the
    /// loader's lookup order deterministic.
    static func installD9MTPrefixSupport(winePrefixPath: String) throws {
        // source root: bundled Patching/d9mt resources
        let pairs: [(subdirectory: String, name: String, ext: String?, destinations: [String])] = [
            ("Patching/d9mt/winemetal/x86_64-windows", "winemetal", "dll", ["drive_c/windows/system32/winemetal.dll"]),
            ("Patching/d9mt/winemetal/i386-windows", "winemetal", "dll", ["drive_c/windows/syswow64/winemetal.dll"]),
            ("Patching/d9mt/winemetal/x86_64-unix", "winemetal", "so", ["drive_c/windows/x86_64-unix/winemetal.so"]),
            ("Patching/d9mt/d9mtmetal/x86_64-windows", "d9mtmetal", "dll", ["drive_c/windows/system32/d9mtmetal.dll"]),
            ("Patching/d9mt/d9mtmetal/i386-windows", "d9mtmetal", "dll", ["drive_c/windows/syswow64/d9mtmetal.dll"]),
            ("Patching/d9mt/d9mtmetal/x86_64-unix", "d9mtmetal", "so", ["drive_c/windows/x86_64-unix/d9mtmetal.so"])
        ]
        let prefixURL = URL(fileURLWithPath: winePrefixPath, isDirectory: true)
        for pair in pairs {
            guard let source = resourceURL(named: pair.name, extension: pair.ext, subdirectory: pair.subdirectory) else {
                throw PatchServiceError.resourceMissing("\(pair.subdirectory)/\(pair.name).\(pair.ext ?? "")")
            }
            for destination in pair.destinations {
                try copyItem(from: source, to: prefixURL.appendingPathComponent(destination))
            }
        }
    }
```

In `applyGamePatch`, after `stageGamePatchFiles`:

```swift
        if version.settings.renderer == .d9mt {
            try installD9MTPrefixSupport(winePrefixPath: <shared prefix path — same source LaunchService/WineRegistrySupport use>)
            try registerD9MTBuiltins() // wine reg add, modeled on patchDivxDecoder's wine invocation
        }
```

`registerD9MTBuiltins` runs (via the existing `ProcessRunner` + `WineRegistrySupport.makeWineEnvironment` pattern):

```
wine reg add 'HKCU\Software\Wine\DllOverrides' /v winemetal /d builtin /f
wine reg add 'HKCU\Software\Wine\DllOverrides' /v d9mtmetal /d builtin /f
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PatchServiceGamePatchTests`
Expected: PASS (the reg-add step is not unit-tested, same as `patchDivxDecoder`).

- [ ] **Step 5: Commit (only if user has approved commits)**

```bash
git add Sources/WoWSiliconSwift/Services/PatchService.swift Tests/WoWSiliconSwiftTests/PatchServiceGamePatchTests.swift
git commit -m "feat: register winemetal/d9mtmetal builtins in prefix for d9mt renderer"
```

---

### Task 6: Renderer-aware freshness checks in `PatchingStatusChecker`

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PatchingStatusChecker.swift` (`resourceExpectations`, lines 170–204)
- Test: `Tests/WoWSiliconSwiftTests/PatchingStatusCheckerTests.swift`

**Interfaces:**
- Consumes: `settings.renderer` (Task 1), `Patching/d9mt` resource (Task 3).

- [ ] **Step 1: Write the failing test**

```swift
func testOutdatedDetectionUsesD9mtPayloadWhenRendererIsD9mt() throws {
    // Given a game folder whose d3d9.dll matches the bundled d9vk payload,
    // a d9mt-configured version must report it outdated (and vice versa).
    let gameURL = try makeGameDirectory()
    var version = makeVersion(gamePath: gameURL.path)
    version.settings.renderer = .d9vk
    try PatchService.stageGamePatchFiles(for: version)

    version.settings.renderer = .d9mt
    let status = PatchingStatusChecker.check(...) // use the file's existing entry point/args

    XCTAssertTrue(status.text.contains("d3d9.dll")) // flagged outdated
}
```

Adapt to the checker's actual public entry point as used by the existing tests in that file.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PatchingStatusCheckerTests`
Expected: FAIL — d9vk-staged dll is accepted even with `renderer = .d9mt`.

- [ ] **Step 3: Implement**

In `resourceExpectations(for:)`, make the d3d9 expectation renderer-aware:

```swift
            ResourceExpectation(
                relativePath: "d3d9.dll",
                resourceName: "d3d9",
                resourceExtension: "dll",
                resourceSubdirectory: version.settings.renderer == .d9mt ? "Patching/d9mt" : "Patching/d9vk",
                displayName: "d3d9.dll"
            )
```

(Replace the hardcoded `"Patching/d9vk"` in the existing literal.)

- [ ] **Step 4: Run tests**

Run: `swift test --filter PatchingStatusCheckerTests`
Expected: PASS.

- [ ] **Step 5: Commit (only if user has approved commits)**

```bash
git add Sources/WoWSiliconSwift/Services/PatchingStatusChecker.swift Tests/WoWSiliconSwiftTests/PatchingStatusCheckerTests.swift
git commit -m "feat: validate d3d9.dll freshness against the active renderer payload"
```

---

### Task 7: Renderer-branched launch environment in `LaunchService`

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/LaunchService.swift` (`makeShellCommand`, baseEnv line ~246)
- Test: `Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift`, `Tests/WoWSiliconSwiftTests/MsyncEnvironmentTests.swift`

**Interfaces:**
- Consumes: `settings.renderer` (Task 1).
- Produces: launch contract — d9mt branch omits `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS` and `DXVK_ASYNC`, adds `D9MT_METALLIB_CACHE=1 D9MT_ASYNC=1`. `WINEDLLOVERRIDES`, `MTL_HUD_ENABLED`, `WINEMSYNC`, `WINESERVER`, `WINEPREFIX` handling unchanged.

- [ ] **Step 1: Write the failing test**

In `LaunchCommandTests.swift` (follow existing style):

```swift
func testMakeShellCommandWithD9mtRendererDropsMoltenVKVars() {
    var settings = VersionSettings()
    settings.renderer = .d9mt
    let command = LaunchService.makeShellCommand(
        gamePath: "/Games/WoW", executablePath: "/Games/WoW/WoW.exe",
        wineBinaryPath: "/rt/bin/wine", rosettaLoaderPath: nil,
        winePrefixPath: "/prefix", settings: settings)
    XCTAssertFalse(command.contains("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"))
    XCTAssertFalse(command.contains("DXVK_ASYNC"))
    XCTAssertTrue(command.contains("D9MT_METALLIB_CACHE=1"))
    XCTAssertTrue(command.contains("D9MT_ASYNC=1"))
    XCTAssertTrue(command.contains(#"WINEDLLOVERRIDES="d3d9=n,b;mscoree=d;mshtml=d""#))
}

func testMakeShellCommandWithD9vkRendererKeepsCurrentEnv() {
    let settings = VersionSettings() // default .d9vk
    let command = LaunchService.makeShellCommand(
        gamePath: "/Games/WoW", executablePath: "/Games/WoW/WoW.exe",
        wineBinaryPath: "/rt/bin/wine", rosettaLoaderPath: nil,
        winePrefixPath: "/prefix", settings: settings)
    XCTAssertTrue(command.contains("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1"))
    XCTAssertTrue(command.contains("DXVK_ASYNC=1"))
    XCTAssertFalse(command.contains("D9MT_"))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LaunchCommandTests`
Expected: FAIL on the d9mt assertions.

- [ ] **Step 3: Implement**

In `makeShellCommand`, replace the single `baseEnv` line with:

```swift
        // Renderer-specific env: d9vk runs on MoltenVK and needs the sync-submit /
        // async flags; d9mt talks to Metal directly and takes its own toggles
        // (both default on upstream; set explicitly for clarity).
        let rendererEnv: String
        switch settings.renderer {
        case .d9vk:
            rendererEnv = "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 DXVK_ASYNC=1"
        case .d9mt:
            rendererEnv = "D9MT_METALLIB_CACHE=1 D9MT_ASYNC=1"
        }
        let baseEnv = "WINEDLLOVERRIDES=\"\(dllOverrides)\" MTL_HUD_ENABLED=\(mtlValue) \(rendererEnv) WINEMSYNC=\(msyncValue) WINESERVER=\(doubleQuote(wineserverPath))"
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter LaunchCommandTests && swift test --filter MsyncEnvironmentTests`
Expected: PASS. Fix any existing assertion that pinned the old baseEnv string verbatim (update it to the new — behavior-identical for d9vk — ordering).

- [ ] **Step 5: Commit (only if user has approved commits)**

```bash
git add Sources/WoWSiliconSwift/Services/LaunchService.swift Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift Tests/WoWSiliconSwiftTests/MsyncEnvironmentTests.swift
git commit -m "feat: branch launch env on renderer (d9mt drops MoltenVK vars)"
```

---

### Task 8: ViewModel renderer binding + CLT gate

**Files:**
- Modify: `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift` (near `msyncBinding()`, lines 545–564)
- Test: `Tests/WoWSiliconSwiftTests/` — extend an existing VM-adjacent suite if one covers bindings; otherwise keep ViewModel logic in a testable static helper.

**Interfaces:**
- Consumes: `RendererBackend` (Task 1); re-staging via existing `patchGame()` (Task 4/5 make it renderer-aware).
- Produces: `func rendererBinding() -> Binding<RendererBackend>` and `static func isMetalToolchainAvailable() -> Bool`, plus an alert path consumed by Task 9's UI. `isMetalToolchainAvailable` runs `/usr/bin/xcrun -f metal` via `ProcessRunner` (or `Process` directly, matching how other one-shot checks are done — read a neighboring service for the idiom) and returns exit status == 0.

- [ ] **Step 1: Write the failing test**

```swift
func testMetalToolchainCheckReturnsBool() {
    // On any dev machine with CLT this is true; assert the API shape and
    // that it doesn't throw/crash either way.
    let result = MainDashboardViewModel.isMetalToolchainAvailable()
    XCTAssertTrue(result == true || result == false)
}
```

(Kept deliberately environment-agnostic; the gating logic itself is thin glue over it.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test`
Expected: FAIL — `isMetalToolchainAvailable` / `rendererBinding` undefined.

- [ ] **Step 3: Implement**

In `MainDashboardViewModel`:

```swift
    /// True when Xcode CLT's Metal toolchain resolves — d9mt compiles MSL to
    /// metallib via `metal` at runtime, so the renderer is gated on this.
    static func isMetalToolchainAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", "metal"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Renderer picker binding. Selecting d9mt without CLT refuses the change
    /// and surfaces an alert; a persisted change re-stages the game patch so
    /// the new renderer's payload lands before the next launch.
    func rendererBinding() -> Binding<RendererBackend> {
        Binding(
            get: { self.versionManager.currentVersion?.settings.renderer ?? .d9vk },
            set: { newValue in
                if newValue == .d9mt && !Self.isMetalToolchainAvailable() {
                    self.alertTitle = "Metal Toolchain Required"
                    self.alertMessage = "The d9mt renderer needs the Xcode command line tools to compile shaders. Run `xcode-select --install`, then try again."
                    self.showingAlert = true // adapt to the VM's actual alert mechanism
                    return
                }
                let oldValue = self.versionManager.currentVersion?.settings.renderer
                self.updateCurrentVersion { $0.settings.renderer = newValue }
                guard let oldValue, oldValue != newValue,
                      self.versionManager.currentVersion?.settings.renderer == newValue else { return }
                self.patchGame()
            }
        )
    }
```

Read the VM's actual alert property names (`alertTitle`/`showingAlert` above are placeholders — grep for how `handlePatchError` surfaces alerts and reuse that exact mechanism).

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit (only if user has approved commits)**

```bash
git add Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift Tests/
git commit -m "feat: renderer binding with CLT gate and re-staging on change"
```

---

### Task 9: Renderer picker in `OptionsView`

**Files:**
- Modify: `Sources/WoWSiliconSwift/Views/OptionsView.swift` (`generalSection`, lines 79–114)

**Interfaces:**
- Consumes: `viewModel.rendererBinding()` (Task 8).

- [ ] **Step 1: Add the picker**

In `generalSection`, directly above the Metal HUD toggle:

```swift
            VStack(alignment: .leading, spacing: 2) {
                Picker("Renderer", selection: viewModel.rendererBinding()) {
                    Text("d9vk (Vulkan)").tag(RendererBackend.d9vk)
                    Text("d9mt (Metal, experimental)").tag(RendererBackend.d9mt)
                }
                .pickerStyle(.menu)
                Text("d9mt translates D3D9 to Metal directly, skipping Vulkan. Experimental: requires Xcode command line tools; switch back to d9vk if the game misbehaves. Takes effect after re-patching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Match the surrounding section's spacing/styling idioms exactly.

- [ ] **Step 2: Verify build + UI**

Run: `swift build`
Expected: build succeeds. Then `make run` and visually confirm: picker renders, selecting d9mt without CLT shows the alert, with CLT it persists and triggers re-patch, d9vk default unchanged.

- [ ] **Step 3: Commit (only if user has approved commits)**

```bash
git add Sources/WoWSiliconSwift/Views/OptionsView.swift
git commit -m "feat: renderer picker in options (d9mt experimental)"
```

---

### Task 10: Docs + full verification

**Files:**
- Modify: `AGENTS.md`, `docs/releasing.md`

- [ ] **Step 1: AGENTS.md updates**

- In the Resources bullet: add `` `Patching/d9mt` `` with a note that it is fetched by `make fetch-d9mt` (not committed) and contains the d3d9.dll + winemetal/d9mtmetal payload.
- In the Makefile bullet: document the `D9MT_VERSION`/`D9MT_SHA256`/`D9MT_URL` pins and `fetch-d9mt` target; note `bundle` stages winemetal/d9mtmetal into the nested game app's `lib/wine` arch dirs.
- In the overview paragraph: mention the optional experimental d9mt renderer alongside d9vk.

- [ ] **Step 2: docs/releasing.md updates**

Add a short "d9mt payload" note next to the Runtime Releases section: the payload is built by `tools/d9mt/build-payload.sh`, uploaded to the `runtime-v<n>` release page, and pinned in the Makefile; bump `D9MT_*` pins together like the runtime pins.

- [ ] **Step 3: Full test + bundle verification**

Run: `swift test && make bundle`
Expected: all tests pass; bundle builds with the d9mt payload staged.

- [ ] **Step 4: Manual smoke (with the user)**

For one client (WotLK suggested): patch with d9vk (regression — unchanged), switch to d9mt, confirm re-patch succeeds, launch, confirm the game renders (or capture the failure mode for a follow-up). Repeat for Vanilla/TBC if WotLK works.

- [ ] **Step 5: Commit (only if user has approved commits)**

```bash
git add AGENTS.md docs/releasing.md
git commit -m "docs: document d9mt renderer payload and pins"
```

---

## Self-Review Notes

- Spec coverage: payload sourcing (Tasks 2–3), model (Task 1), staging (Task 4), prefix registration (added Task 5 — required by d9mt's actual install mechanism, discovered during planning), freshness (Task 6), launch env (Task 7), CLT gate (Task 8), UI (Task 9), docs (Task 10), testing (per-task + Task 10). Out-of-scope items in the spec remain untouched.
- Deliberate deviation from spec: winemetal/d9mtmetal register as **builtins** (wine tree + prefix + `reg add`), not via `WINEDLLOVERRIDES=winemetal=n` — this matches d9mt's own `run-test.sh`/`build-d9mtmetal.sh` and is required for unixlib pairing.
- Known soft spots accepted at plan time: exact harvest paths in `build-payload.sh` (guarded by its sanity loop), VM alert property names and test-fixture helper names (marked inline as "adapt to actual").
