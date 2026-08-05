# WoWSilicon v3.0.0 — Bundled Wine Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CrossOver dependency with a bundled, pre-patched Wine runtime and update rosettax87_jit for macOS 27 support.

**Architecture:** A CI pipeline builds Wine from `WineAndAqua/wine` @ `wine-11.0-macos` (the tree with `ROSETTA_X87_PATH` already integrated) and publishes `runtime-v*` GitHub releases; `make bundle` embeds the checksum-verified runtime at `Contents/SharedSupport/wine`. In the app, a new `WineRuntime` service becomes the single path authority; CrossOver patching and UI code are deleted in consumer-first order so every task leaves the tree compiling and tested.

**Tech Stack:** Swift 6 (SwiftUI/AppKit, SwiftPM, XCTest), GNU Make, GitHub Actions (`macos-15-intel`), Wine 11.0 (WineAndAqua tree), rosettax87_jit, Bash.

## Global Constraints

- Spec (source of truth): `docs/superpowers/specs/2026-08-05-v3-bundled-wine-design.md`.
- App: arm64, macOS 15+. Wine runtime: x86_64, runs under Rosetta 2.
- Wine source: `WineAndAqua/wine`, branch `wine-11.0-macos`, pinned SHA recorded in the Task 2 workflow.
- Runtime artifact: tar.xz containing top-level `wine/{bin,lib,share,VERSION}`; release tag `runtime-v1`; assets `wowsilicon-wine-1-osx64.tar.xz` + `.sha256`; bundle destination `$(APP_BUNDLE)/Contents/SharedSupport/wine`.
- `WINEPREFIX` stays `~/.wine`. `GameVersion.crossOverPath` property + Codable handling stay exactly as-is (backward compat with on-disk `versions.json`).
- Launch env (single shape everywhere): `cd "<game>" && ROSETTA_X87_PATH="<loader>" <customEnv> WINEDLLOVERRIDES="d3d9=n,b;mscoree=d;mshtml=d" MTL_HUD_ENABLED=<0|1> MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 DXVK_ASYNC=1 "<wine>" "<exe>" [args]`.
- Every task leaves `swift test` green and the package compiling. One commit per task minimum, message trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Task order is load-bearing: 4 → 5 → 6 → 7 → 8 → 9 → 10 (consumers stop calling CrossOver APIs before those APIs are deleted). Tasks 1–3 are independent of 4–10; **Task 3 (spike) must PASS before Task 11 and before any release tagging**.
- Repo: `github.com/samitaaissat/WoWSilicon` (origin). Branch: `v3-bundled-wine-runtime`.

---


### Task 1: Update vendored rosettax87_jit binaries

**Files:**
- Modify (binary replacement): `Sources/WoWSiliconSwift/Resources/Patching/rosettax87/rosettax87`
- Modify (binary replacement): `Sources/WoWSiliconSwift/Resources/Patching/rosettax87/libRuntimeRosettax87`

**Interfaces:**
- Consumes: existing SPM resource layout `Resources/Patching/rosettax87/` (looked up today via `PatchService.resourceURL(name:subdirectory:)`; no checksums are hardcoded in Swift — `PatchingStatusChecker` hashes the bundled files at runtime, so replacing the binaries cannot break `swift test`).
- Produces: updated bundled loader pair `Patching/rosettax87/{rosettax87,libRuntimeRosettax87}` (2026-07-24 jit release with macOS 27 debugger-detach fixes). Task 4's `WineRuntime.rosettaLoaderURL` and Task 5's `ROSETTA_X87_PATH` point at exactly these resources.

- [ ] **Step 1: Record the old checksums (baseline to prove the replacement happened)**
```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon
shasum -a 256 \
  Sources/WoWSiliconSwift/Resources/Patching/rosettax87/rosettax87 \
  Sources/WoWSiliconSwift/Resources/Patching/rosettax87/libRuntimeRosettax87
```
Expected output (the OLD hashes — these MUST change by Step 5):
```
77a74f87c407b0f9e04d839be1075885bd9d45ea38b5b44f18676298b7d8426b  .../rosettax87
c9ec19b55d80bdc942fd5076a22933f4cb90e9ece61194068106133cbade5b8b  .../libRuntimeRosettax87
```

- [ ] **Step 2: Download and extract the latest jit rolling release**
```bash
TMP="$(mktemp -d)"
curl -fL --retry 3 -o "$TMP/rosettax87-jit-macos-arm64.tar.gz" \
  https://github.com/Lifeisawful/rosettax87_jit/releases/download/latest/rosettax87-jit-macos-arm64.tar.gz
tar -xzf "$TMP/rosettax87-jit-macos-arm64.tar.gz" -C "$TMP"
find "$TMP" -type f -not -name '*.tar.gz' | sort
```
Expected: the archive is ~181 KB and contains `runtime_loader` and `libRuntimeRosettax87` (possibly inside a subdirectory — the `find` shows where).

- [ ] **Step 3: Rename loader, set permissions, replace the vendored files**
```bash
LOADER="$(find "$TMP" -type f -name runtime_loader | head -n1)"
LIB="$(find "$TMP" -type f -name libRuntimeRosettax87 | head -n1)"
test -n "$LOADER" && test -n "$LIB"
mv "$LOADER" "$TMP/rosettax87"
chmod 755 "$TMP/rosettax87" "$LIB"
cp "$TMP/rosettax87" Sources/WoWSiliconSwift/Resources/Patching/rosettax87/rosettax87
cp "$LIB" Sources/WoWSiliconSwift/Resources/Patching/rosettax87/libRuntimeRosettax87
ls -l Sources/WoWSiliconSwift/Resources/Patching/rosettax87/
```
Expected: both files present with `-rwxr-xr-x` permissions.

- [ ] **Step 4: Verify architecture and debugger entitlement**
```bash
file Sources/WoWSiliconSwift/Resources/Patching/rosettax87/rosettax87 \
     Sources/WoWSiliconSwift/Resources/Patching/rosettax87/libRuntimeRosettax87
codesign -d --entitlements - Sources/WoWSiliconSwift/Resources/Patching/rosettax87/rosettax87
```
Expected: `rosettax87` is `Mach-O 64-bit executable arm64`; `libRuntimeRosettax87` is a `Mach-O 64-bit dynamically linked shared library arm64`; the entitlements dump contains `com.apple.security.cs.debugger`. STOP if the entitlement is missing — the loader cannot attach to Rosetta processes without it.

- [ ] **Step 5: Verify the checksums changed and record the new values**
```bash
shasum -a 256 \
  Sources/WoWSiliconSwift/Resources/Patching/rosettax87/rosettax87 \
  Sources/WoWSiliconSwift/Resources/Patching/rosettax87/libRuntimeRosettax87
```
Expected: two hashes that DIFFER from `77a74f87c4…` and `c9ec19b55d…`. Record both new hashes in the commit message body (Step 7).

- [ ] **Step 6: Confirm the package still builds and tests pass**
```bash
swift build
swift test
```
Expected: build succeeds; full suite green (no Swift code references these binaries by hash, so nothing else changes).

- [ ] **Step 7: Commit**
```bash
git add Sources/WoWSiliconSwift/Resources/Patching/rosettax87/rosettax87 \
        Sources/WoWSiliconSwift/Resources/Patching/rosettax87/libRuntimeRosettax87
git commit -m "chore: update vendored rosettax87_jit to 2026-07-24 release

Rolling-release jit build with the macOS 27 (Golden Gate) debugger-detach
fixes. runtime_loader renamed to rosettax87 as before.
New SHA-256:
  rosettax87:           <hash from Step 5>
  libRuntimeRosettax87: <hash from Step 5>

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 2: Wine runtime build script + GitHub workflow

**Files:**
- Create: `tools/runtime/build-wine-runtime.sh`
- Create: `.github/workflows/runtime.yml`

**Interfaces:**
- Consumes: nothing from the Swift package (fully decoupled from app releases).
- Produces: GitHub release `runtime-v1` with assets `wowsilicon-wine-1-osx64.tar.xz` and `wowsilicon-wine-1-osx64.tar.xz.sha256`; tarball layout: top-level `wine/{bin,lib,share,VERSION}`; `VERSION` contents `wowsilicon-wine 1 (WineAndAqua/wine@<WINE_COMMIT> wine-11.0-macos)`. Task 3 downloads this artifact; Task 11's Makefile `fetch-runtime` pins `RUNTIME_VERSION`/`RUNTIME_SHA256`/`RUNTIME_URL` against it and installs it to `$(APP_BUNDLE)/Contents/SharedSupport/wine`. Script contract: `RUNTIME_BUILD_NUMBER` env (default `1`); outputs land in `.build/wine-runtime/dist/`.

- [ ] **Step 1: Write the build script**
```bash
mkdir -p tools/runtime
```
Create `tools/runtime/build-wine-runtime.sh` with exactly:
```bash
#!/usr/bin/env bash
#
# Builds the WoWSilicon bundled Wine runtime from WineAndAqua/wine
# (branch wine-11.0-macos, pinned commit) on x86_64 (macos-15-intel runner,
# or an Apple Silicon Mac via `arch -x86_64 bash tools/runtime/build-wine-runtime.sh`).
#
# Stages wine/{bin,lib,share,VERSION}, ad-hoc signs every Mach-O (plain
# ad-hoc, no hardened runtime, so debugger attach keeps working), smoke
# tests under Rosetta, and packages:
#   .build/wine-runtime/dist/wowsilicon-wine-<RUNTIME_BUILD_NUMBER>-osx64.tar.xz
#   .build/wine-runtime/dist/wowsilicon-wine-<RUNTIME_BUILD_NUMBER>-osx64.tar.xz.sha256
#
# Env:
#   RUNTIME_BUILD_NUMBER  runtime build number (default: 1)
#   RUNTIME_WORK_DIR      scratch dir (default: <repo>/.build/wine-runtime)
#
# Prereqs (brew): bison ccache gettext mingw-w64 pkgconfig freetype gnutls
#                 libpcap sdl2 molten-vk
set -euo pipefail

RUNTIME_BUILD_NUMBER="${RUNTIME_BUILD_NUMBER:-1}"
WINE_REPO="https://github.com/WineAndAqua/wine"
WINE_BRANCH="wine-11.0-macos"
# Pinned via: git ls-remote https://github.com/WineAndAqua/wine refs/heads/wine-11.0-macos
WINE_COMMIT="UNPINNED"

if [[ ! "$WINE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: WINE_COMMIT is not pinned to a 40-char commit SHA. Edit this script first." >&2
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "error: must run as x86_64 (Intel runner, or: arch -x86_64 bash $0)." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${RUNTIME_WORK_DIR:-$ROOT_DIR/.build/wine-runtime}"
SRC_DIR="$WORK_DIR/src"
BUILD_DIR="$WORK_DIR/build"
STAGING_DIR="$WORK_DIR/staging"
DIST_DIR="$WORK_DIR/dist"
ARTIFACT="wowsilicon-wine-${RUNTIME_BUILD_NUMBER}-osx64.tar.xz"

BREW_PREFIX="$(brew --prefix)"

rm -rf "$BUILD_DIR" "$STAGING_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$STAGING_DIR" "$DIST_DIR"

# --- Sources ------------------------------------------------------------
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --branch "$WINE_BRANCH" --single-branch "$WINE_REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch origin "$WINE_BRANCH"
git -C "$SRC_DIR" checkout --detach "$WINE_COMMIT"

# --- Build environment ----------------------------------------------------
export MACOSX_DEPLOYMENT_TARGET=10.15
export PATH="$BREW_PREFIX/opt/bison/bin:$PATH"
export CC="ccache clang"
export i386_CC="ccache i686-w64-mingw32-gcc"
export x86_64_CC="ccache x86_64-w64-mingw32-gcc"
export CPATH="$BREW_PREFIX/include"
export LIBRARY_PATH="$BREW_PREFIX/lib"
export CFLAGS="-O2 -Wno-deprecated-declarations -Wno-format"
export CROSSCFLAGS="-O2 -Wno-incompatible-pointer-types"
export LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../../ -Wl,-rpath,$BREW_PREFIX/lib"

# --- Configure + make -------------------------------------------------------
cd "$BUILD_DIR"
"$SRC_DIR/configure" \
  --prefix= \
  --disable-tests \
  --disable-winedbg \
  --enable-win64 \
  --enable-archs=i386,x86_64 \
  --with-mingw \
  --with-vulkan \
  --with-coreaudio \
  --with-cups \
  --with-freetype \
  --with-gettext \
  --with-gnutls \
  --with-pcap \
  --with-pthread \
  --with-sdl \
  --with-unwind \
  --without-alsa \
  --without-capi \
  --without-dbus \
  --without-fontconfig \
  --without-gettextpo \
  --without-gphoto \
  --without-gssapi \
  --without-gstreamer \
  --without-inotify \
  --without-krb5 \
  --without-netapi \
  --without-opengl \
  --without-oss \
  --without-pulse \
  --without-sane \
  --without-udev \
  --without-usb \
  --without-v4l2 \
  --without-x

make -j"$(sysctl -n hw.ncpu)"

# --- Stage ----------------------------------------------------------------
# Empty --prefix + DESTDIR=<staging>/wine => staging/wine/{bin,lib,share}
make install-lib DESTDIR="$STAGING_DIR/wine"

# DXVK d3d9.dll's Vulkan backend needs MoltenVK next to Wine's libs.
cp "$BREW_PREFIX/lib/libMoltenVK.dylib" "$STAGING_DIR/wine/lib/"

rm -rf "$STAGING_DIR/wine/include" \
       "$STAGING_DIR/wine/share/man" \
       "$STAGING_DIR/wine/share/applications"

# LGPL compliance: ship the license texts inside the tarball.
mkdir -p "$STAGING_DIR/wine/share/licenses"
cp "$SRC_DIR/LICENSE" "$SRC_DIR/COPYING.LIB" "$STAGING_DIR/wine/share/licenses/"

printf 'wowsilicon-wine %s (WineAndAqua/wine@%s %s)\n' \
  "$RUNTIME_BUILD_NUMBER" "$WINE_COMMIT" "$WINE_BRANCH" > "$STAGING_DIR/wine/VERSION"

# --- Ad-hoc sign every Mach-O in the staging tree ---------------------------
# (codesign cannot --deep a bare directory, so sign file by file.)
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    codesign --force --sign - "$candidate"
  fi
done < <(find "$STAGING_DIR/wine" -type f -print0)

# --- Smoke test under Rosetta ------------------------------------------------
SMOKE_PREFIX="${RUNNER_TEMP:-$WORK_DIR}/testpfx"
rm -rf "$SMOKE_PREFIX"
arch -x86_64 "$STAGING_DIR/wine/bin/wine" --version
WINEPREFIX="$SMOKE_PREFIX" WINEDLLOVERRIDES="mscoree=d;mshtml=d" \
  arch -x86_64 "$STAGING_DIR/wine/bin/wine" wineboot -u
WINEPREFIX="$SMOKE_PREFIX" arch -x86_64 "$STAGING_DIR/wine/bin/wineserver" -w
test -f "$SMOKE_PREFIX/system.reg"

# --- Package -----------------------------------------------------------------
tar -C "$STAGING_DIR" -cJf "$DIST_DIR/$ARTIFACT" wine
(cd "$DIST_DIR" && shasum -a 256 "$ARTIFACT" > "$ARTIFACT.sha256")

echo "Runtime artifacts:"
ls -lh "$DIST_DIR"
```
Then:
```bash
chmod 755 tools/runtime/build-wine-runtime.sh
```

- [ ] **Step 2: Pin the WineAndAqua commit SHA (record the real value)**
```bash
WINE_SHA="$(git ls-remote https://github.com/WineAndAqua/wine refs/heads/wine-11.0-macos | awk '{print $1}')"
echo "Pinned wine-11.0-macos HEAD: $WINE_SHA"
sed -i '' "s/^WINE_COMMIT=\"UNPINNED\"$/WINE_COMMIT=\"$WINE_SHA\"/" tools/runtime/build-wine-runtime.sh
grep -n '^WINE_COMMIT=' tools/runtime/build-wine-runtime.sh
```
Expected: `grep` shows `WINE_COMMIT="<40-hex SHA>"`. Record the SHA — it goes in the Step 6 commit message and later in README credits (Task 12+ scope). STOP if `WINE_SHA` is empty (network issue) — do not commit an `UNPINNED` script.

- [ ] **Step 3: Lint the script locally**
```bash
bash -n tools/runtime/build-wine-runtime.sh
command -v shellcheck >/dev/null || brew install shellcheck
shellcheck tools/runtime/build-wine-runtime.sh
```
Expected: no output, exit 0 from both. Fix any shellcheck finding before continuing (the script above is written to be shellcheck-clean).

- [ ] **Step 4: Write the workflow**
Create `.github/workflows/runtime.yml` with exactly:
```yaml
name: Wine Runtime

on:
  push:
    tags:
      - "runtime-v*"
  workflow_dispatch:
    inputs:
      build_number:
        description: "Runtime build number, for example 1"
        required: true
        type: string

permissions:
  contents: write

jobs:
  runtime:
    runs-on: macos-15-intel

    steps:
      - name: Checkout app repo
        uses: actions/checkout@v4

      - name: Show toolchain
        run: |
          sw_vers
          xcodebuild -version
          uname -m

      - name: Resolve build number
        id: build
        shell: bash
        run: |
          set -euo pipefail
          if [[ "${{ github.event_name }}" == "workflow_dispatch" ]]; then
            build_number="${{ inputs.build_number }}"
          else
            build_number="${GITHUB_REF_NAME#runtime-v}"
          fi
          echo "build_number=$build_number" >> "$GITHUB_OUTPUT"
          echo "tag=runtime-v$build_number" >> "$GITHUB_OUTPUT"

      - name: Install build dependencies
        run: brew install bison ccache gettext mingw-w64 pkgconfig freetype gnutls libpcap sdl2 molten-vk

      - name: Set up ccache
        uses: hendrikmuhs/ccache-action@v1
        with:
          key: wine-runtime-macos-15-intel
          max-size: 2G

      - name: Build runtime
        env:
          RUNTIME_BUILD_NUMBER: ${{ steps.build.outputs.build_number }}
        run: bash tools/runtime/build-wine-runtime.sh

      - name: Create or update GitHub release
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ steps.build.outputs.tag }}
          BUILD_NUMBER: ${{ steps.build.outputs.build_number }}
        run: |
          set -euo pipefail
          dist=".build/wine-runtime/dist"
          tarball="$dist/wowsilicon-wine-$BUILD_NUMBER-osx64.tar.xz"
          checksum="$tarball.sha256"
          wine_commit="$(grep -m1 '^WINE_COMMIT=' tools/runtime/build-wine-runtime.sh | cut -d'"' -f2)"
          notes="Bundled Wine runtime build $BUILD_NUMBER, built from WineAndAqua/wine@$wine_commit (branch wine-11.0-macos). Layout: wine/{bin,lib,share,VERSION}."
          if gh release view "$TAG" >/dev/null 2>&1; then
            gh release upload "$TAG" "$tarball" "$checksum" --clobber
            gh release edit "$TAG" --title "Wine runtime $BUILD_NUMBER" --notes "$notes"
          else
            gh release create "$TAG" "$tarball" "$checksum" \
              --title "Wine runtime $BUILD_NUMBER" \
              --notes "$notes"
          fi
```

- [ ] **Step 5: Validate the workflow YAML parses**
```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/runtime.yml"); puts "YAML OK"'
```
Expected: `YAML OK`.

- [ ] **Step 6: Commit**
```bash
git add tools/runtime/build-wine-runtime.sh .github/workflows/runtime.yml
git commit -m "feat: add bundled Wine runtime build script and CI workflow

Builds WineAndAqua/wine@<SHA from Step 2> (wine-11.0-macos) on
macos-15-intel, stages wine/{bin,lib,share,VERSION}, ad-hoc signs,
smoke tests under Rosetta, and publishes
wowsilicon-wine-<n>-osx64.tar.xz (+ .sha256) to release runtime-v<n>.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
(No Swift files touched; `swift test` remains green by construction.)

### Task 3: Spike gate — validate the runtime against a real client (manual)

**Files:**
- Create: `docs/superpowers/specs/2026-08-05-v3-runtime-spike-results.md` (filled checklist, committed at the end)
- Test (manual): the `runtime-v1` release artifact from Task 2, a locally built `.build/WoWSilicon.app`, real vanilla 1.12 and WotLK 3.3.5a client folders

**Interfaces:**
- Consumes: GitHub release `runtime-v1` assets `wowsilicon-wine-1-osx64.tar.xz` / `.sha256` (Task 2); updated bundled loader `Patching/rosettax87/rosettax87` + `libRuntimeRosettax87` (Task 1); existing `make bundle` target.
- Produces: a recorded GO/NO-GO decision. This is the Milestone-0 gate from the spec: Tasks 4–11 code work may proceed in parallel, but **Task 11 (Makefile runtime bundling) and any 3.0.0 release step MUST NOT start until every item below passes.** If any item fails: STOP, do not proceed to Task 11 or release — record findings in the results doc and report back for a design revisit (e.g. re-adding gstreamer, different pin).

- [ ] **Step 1: Produce the runtime build**
Preferred — CI (also proves the workflow itself):
```bash
git push origin main   # runtime.yml must exist on the default branch
git tag runtime-v1 && git push origin runtime-v1
gh run watch --exit-status
```
Alternative — local build on this Apple Silicon Mac via Rosetta (slow, ~hours cold):
```bash
brew install bison ccache gettext mingw-w64 pkgconfig freetype gnutls libpcap sdl2 molten-vk
RUNTIME_BUILD_NUMBER=1 arch -x86_64 bash tools/runtime/build-wine-runtime.sh
# artifacts land in .build/wine-runtime/dist/
```
Expected: workflow green (release `runtime-v1` exists with both assets), or local `dist/` contains `wowsilicon-wine-1-osx64.tar.xz` + `.sha256`.

- [ ] **Step 2: Download and verify the artifact**
```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon
mkdir -p .build/runtime-spike
gh release download runtime-v1 --pattern 'wowsilicon-wine-1-osx64.tar.xz*' --dir .build/runtime-spike --clobber
(cd .build/runtime-spike && shasum -a 256 -c wowsilicon-wine-1-osx64.tar.xz.sha256)
```
Expected: `wowsilicon-wine-1-osx64.tar.xz: OK`. Note the compressed size — spec expects ~140–160 MB; record the actual number.

- [ ] **Step 3: Build the app bundle and graft the runtime in by hand**
```bash
make bundle
mkdir -p .build/WoWSilicon.app/Contents/SharedSupport
tar -xJf .build/runtime-spike/wowsilicon-wine-1-osx64.tar.xz -C .build/WoWSilicon.app/Contents/SharedSupport
cat .build/WoWSilicon.app/Contents/SharedSupport/wine/VERSION
ls .build/WoWSilicon.app/Contents/SharedSupport/wine/bin
```
Expected: `VERSION` reads `wowsilicon-wine 1 (WineAndAqua/wine@<pinned SHA> wine-11.0-macos)`; `bin/` contains `wine` and `wineserver`. (Grafting after `make bundle` breaks the app's `--deep` seal — irrelevant here because the spike runs `wine` directly from Terminal, never launches the .app. Task 11 fixes the ordering by copying before codesign.)

- [ ] **Step 4: Resolve the wine binary and the bundled rosettax87 loader**
```bash
APP="$PWD/.build/WoWSilicon.app"
WINE="$APP/Contents/SharedSupport/wine/bin/wine"
LOADER="$(find "$APP/Contents/Resources" -type f -name rosettax87 -path '*Patching*' | head -n1)"
echo "LOADER=$LOADER"
test -x "$LOADER" && test -f "$(dirname "$LOADER")/libRuntimeRosettax87" && echo "loader pair OK"
arch -x86_64 "$WINE" --version
```
Checklist: [ ] `wine --version` prints a wine-11.0-family version string under Rosetta, exit 0; [ ] `libRuntimeRosettax87` sits next to the loader (the loader locates it via its executable dir).

- [ ] **Step 5: Prefix boot (existing `~/.wine` kept, per spec)**
```bash
WINEPREFIX="$HOME/.wine" WINEDLLOVERRIDES="mscoree=d;mshtml=d" arch -x86_64 "$WINE" wineboot -u
```
Checklist: [ ] wineboot completes with NO wine-mono / wine-gecko download prompts and no crash dialogs.

- [ ] **Step 6: Boot vanilla 1.12 to the login screen (the launch shape Task 5 will emit)**
```bash
cd "<vanilla 1.12 game folder>" && \
ROSETTA_X87_PATH="$LOADER" \
WINEDLLOVERRIDES="d3d9=n,b;mscoree=d;mshtml=d" \
MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 DXVK_ASYNC=1 \
"$WINE" WoW.exe
```
Checklist: [ ] macOS shows the one-time "authorize debugging" prompt (the loader's `com.apple.security.cs.debugger` entitlement) — accept it; [ ] game reaches the login screen and runs after accepting; [ ] on relaunch the prompt does NOT reappear.

- [ ] **Step 7: Confirm DXVK d3d9 is active**
Re-run the Step 6 command with `MTL_HUD_ENABLED=1` (or add `DXVK_HUD=1`) prepended to the env.
Checklist: [ ] the Metal/DXVK HUD renders in-game, proving native `d3d9=n,b` (DXVK) loaded instead of wined3d.

- [ ] **Step 8: Boot WotLK 3.3.5a**
Same command as Step 6 from the 3.3.5a folder (executable `Wow.exe`).
Checklist: [ ] 3.3.5a reaches the login screen.

- [ ] **Step 9: DivxDecoder rundll32 patching via the new wine (vanilla folder)**
Mirrors `PatchService.patchDivxDecoder` (`rundll32 libDllLdr.dll,PatchDivxDecoder <gamePath>`):
```bash
cd "<vanilla 1.12 game folder>" && \
ROSETTA_X87_PATH="$LOADER" WINEDLLOVERRIDES="mscoree=d;mshtml=d" \
"$WINE" rundll32 "libDllLdr.dll,PatchDivxDecoder" "$PWD"
ls -l DivxDecoder.dll*
```
Checklist: [ ] command exits 0 and the patched `DivxDecoder.dll` / `.bak` state matches what the v2.5.x CrossOver-based flow produces (restore from `.bak` afterwards if you patched a pristine folder).

- [ ] **Step 10: Retina / OptionAsAlt registry writes apply**
```bash
"$WINE" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d Y /f
"$WINE" reg query 'HKCU\Software\Wine\Mac Driver' /v RetinaMode
"$WINE" reg delete 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /f
```
Checklist: [ ] `reg query` shows `RetinaMode REG_SZ Y` (same key `WineRegistrySupport.macDriverRegistryKey` / `LeftOptionIsAlt` writes use).

- [ ] **Step 11: macOS 27 beta pass (only if a Golden Gate machine is available)**
Repeat Steps 3–7 on the macOS 27 beta machine.
Checklist: [ ] same results, in particular the debugger-authorization prompt + successful attach (the entire point of the Task 1 jit update). Mark N/A if no machine is available and note it.

- [ ] **Step 12: Record the gate decision and commit — STOP HERE ON ANY FAILURE**
Create `docs/superpowers/specs/2026-08-05-v3-runtime-spike-results.md`:
```markdown
# v3 runtime spike results (Milestone 0 gate)

Date: <fill>
Runtime: runtime-v1 (wowsilicon-wine-1-osx64.tar.xz, sha256 <fill>, <fill> MB compressed)
Wine pin: WineAndAqua/wine@<fill> (wine-11.0-macos)
Machine(s): <macOS version(s), chip>

| Check | Result |
|---|---|
| wine --version under Rosetta | PASS/FAIL |
| Prefix boots, no mono/gecko prompts | PASS/FAIL |
| Vanilla 1.12 reaches login | PASS/FAIL |
| WotLK 3.3.5a reaches login | PASS/FAIL |
| DXVK d3d9 active (HUD visible) | PASS/FAIL |
| DivxDecoder rundll32 patching | PASS/FAIL |
| Retina/OptionAsAlt registry writes | PASS/FAIL |
| Debug-authorization prompt once, game runs after accept | PASS/FAIL |
| macOS 27 beta repeat | PASS/FAIL/N-A |

Decision: GO / NO-GO for Task 11 + release.
Notes: <anything observed: cinematics, audio, perf, warnings>
```
Then:
```bash
git add docs/superpowers/specs/2026-08-05-v3-runtime-spike-results.md
git commit -m "docs: record v3 runtime spike results (milestone 0 gate)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
**STOP:** if any checklist item is FAIL, the decision is NO-GO — do not proceed to Task 11 or any 3.0.0 release step. Commit the results doc with the failures documented and report findings instead.

---

### Task 4: WineRuntime service

**Files:**
- Create: `Sources/WoWSiliconSwift/Services/WineRuntime.swift`
- Test: `Tests/WoWSiliconSwiftTests/WineRuntimeTests.swift`
- No modifications: `PatchService.resourceURL(named:extension:subdirectory:)` (`Sources/WoWSiliconSwift/Services/PatchService.swift:517`) is a `static func` with no access modifier inside internal `enum PatchService` — already internal, callable from WineRuntime as-is. (`CandidateBundles` is `private` at file scope but is only used through `resourceURL`, so it needs no change.)

**Interfaces:**
- Consumes: `PatchService.resourceURL(named name: String, extension ext: String?, subdirectory: String) -> URL?` (existing, PatchService.swift:517)
- Produces (used by Tasks 5–10):
  - `enum WineRuntimeError: LocalizedError, Equatable` — `.wineBinaryMissing(String)`, `.wineBinaryNotExecutable(String)`, `.rosettaLoaderMissing`
  - `final class WineRuntime: @unchecked Sendable` — `static let shared: WineRuntime`, `init(bundleURL: URL = Bundle.main.bundleURL, rosettaLoaderOverride: URL? = nil)`, `var runtimeRootURL: URL`, `var wineBinaryURL: URL`, `var wineserverBinaryURL: URL`, `var runtimeVersion: String?`, `var rosettaLoaderURL: URL?`, `func validatedWineBinaryURL() throws -> URL`, `func validatedRosettaLoaderURL() throws -> URL`

- [ ] **Step 1: Write the failing test suite**

Create `Tests/WoWSiliconSwiftTests/WineRuntimeTests.swift` with exactly this content (repo test style: real temp dirs per test, cleaned in `tearDownWithError`):

```swift
import XCTest
@testable import WoWSiliconSwift

final class WineRuntimeTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testPathsAreDerivedFromInjectedBundleURL() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/WoWSilicon.app", isDirectory: true)
        let runtime = WineRuntime(bundleURL: bundleURL)

        XCTAssertEqual(runtime.runtimeRootURL.path, "/Applications/WoWSilicon.app/Contents/SharedSupport/wine")
        XCTAssertEqual(runtime.wineBinaryURL.path, "/Applications/WoWSilicon.app/Contents/SharedSupport/wine/bin/wine")
        XCTAssertEqual(runtime.wineserverBinaryURL.path, "/Applications/WoWSilicon.app/Contents/SharedSupport/wine/bin/wineserver")
    }

    func testValidatedWineBinaryURLThrowsWineBinaryMissingWhenAbsent() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())

        XCTAssertThrowsError(try runtime.validatedWineBinaryURL()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .wineBinaryMissing(runtime.wineBinaryURL.path))
        }
    }

    func testValidatedWineBinaryURLThrowsWineBinaryNotExecutableForMode644() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        try makeFile(at: runtime.wineBinaryURL, posixPermissions: 0o644)

        XCTAssertThrowsError(try runtime.validatedWineBinaryURL()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .wineBinaryNotExecutable(runtime.wineBinaryURL.path))
        }
    }

    func testValidatedWineBinaryURLReturnsURLWhenExecutable() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        try makeFile(at: runtime.wineBinaryURL, posixPermissions: 0o755)

        XCTAssertEqual(try runtime.validatedWineBinaryURL(), runtime.wineBinaryURL)
    }

    func testRuntimeVersionReadsAndTrimsVersionFile() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        try FileManager.default.createDirectory(at: runtime.runtimeRootURL, withIntermediateDirectories: true)
        try "  1\n".write(to: runtime.runtimeRootURL.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        XCTAssertEqual(runtime.runtimeVersion, "1")
    }

    func testRuntimeVersionIsNilWhenVersionFileAbsent() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())

        XCTAssertNil(runtime.runtimeVersion)
    }

    func testValidatedRosettaLoaderURLReturnsExecutableOverride() throws {
        let loaderURL = try makeTemporaryDirectory().appendingPathComponent("rosettax87")
        try makeFile(at: loaderURL, posixPermissions: 0o755)
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory(), rosettaLoaderOverride: loaderURL)

        XCTAssertEqual(runtime.rosettaLoaderURL, loaderURL)
        XCTAssertEqual(try runtime.validatedRosettaLoaderURL(), loaderURL)
    }

    func testValidatedRosettaLoaderURLThrowsRosettaLoaderMissingWhenOverrideAbsent() throws {
        let loaderURL = try makeTemporaryDirectory().appendingPathComponent("rosettax87")
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory(), rosettaLoaderOverride: loaderURL)

        XCTAssertThrowsError(try runtime.validatedRosettaLoaderURL()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .rosettaLoaderMissing)
        }
    }

    private func makeFile(at url: URL, posixPermissions: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: posixPermissions], ofItemAtPath: url.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail to compile**

```bash
swift test --filter WineRuntimeTests
```

Expected failure: the test target does not build — `error: cannot find 'WineRuntime' in scope` (and `cannot find type 'WineRuntimeError' in scope`) in `Tests/WoWSiliconSwiftTests/WineRuntimeTests.swift`. Do not proceed until you see this exact class of failure.

- [ ] **Step 3: Implement WineRuntime**

Create `Sources/WoWSiliconSwift/Services/WineRuntime.swift` with exactly this content:

```swift
import Foundation

enum WineRuntimeError: LocalizedError, Equatable {
    case wineBinaryMissing(String)
    case wineBinaryNotExecutable(String)
    case rosettaLoaderMissing

    var errorDescription: String? {
        switch self {
        case .wineBinaryMissing(let path):
            return "Bundled Wine runtime not found at \(path). Please reinstall WoWSilicon."
        case .wineBinaryNotExecutable(let path):
            return "Bundled Wine runtime at \(path) is not executable. Please reinstall WoWSilicon."
        case .rosettaLoaderMissing:
            return "Bundled rosettax87 loader not found. Please reinstall WoWSilicon."
        }
    }
}

/// Single authority for the bundled Wine runtime and rosettax87 loader paths.
/// The runtime lives at <WoWSilicon.app>/Contents/SharedSupport/wine (staged by
/// the Makefile `bundle` target); the loader is the SPM-vendored resource
/// Patching/rosettax87/rosettax87.
final class WineRuntime: @unchecked Sendable {
    static let shared = WineRuntime()

    private let bundleURL: URL
    private let rosettaLoaderOverride: URL?
    private let fileManager = FileManager.default

    init(bundleURL: URL = Bundle.main.bundleURL, rosettaLoaderOverride: URL? = nil) {
        self.bundleURL = bundleURL
        self.rosettaLoaderOverride = rosettaLoaderOverride
    }

    var runtimeRootURL: URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("SharedSupport", isDirectory: true)
            .appendingPathComponent("wine", isDirectory: true)
    }

    var wineBinaryURL: URL {
        runtimeRootURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("wine")
    }

    var wineserverBinaryURL: URL {
        runtimeRootURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("wineserver")
    }

    var runtimeVersion: String? {
        let versionURL = runtimeRootURL.appendingPathComponent("VERSION")
        guard let contents = try? String(contentsOf: versionURL, encoding: .utf8) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var rosettaLoaderURL: URL? {
        if let rosettaLoaderOverride {
            return rosettaLoaderOverride
        }
        return PatchService.resourceURL(named: "rosettax87", extension: nil, subdirectory: "Patching/rosettax87")
    }

    func validatedWineBinaryURL() throws -> URL {
        let url = wineBinaryURL
        guard fileManager.fileExists(atPath: url.path) else {
            throw WineRuntimeError.wineBinaryMissing(url.path)
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw WineRuntimeError.wineBinaryNotExecutable(url.path)
        }
        return url
    }

    func validatedRosettaLoaderURL() throws -> URL {
        guard let url = rosettaLoaderURL, fileManager.isExecutableFile(atPath: url.path) else {
            throw WineRuntimeError.rosettaLoaderMissing
        }
        return url
    }
}
```

- [ ] **Step 4: Run the new tests green**

```bash
swift test --filter WineRuntimeTests
```

Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

```bash
swift test
```

Expected: all existing tests plus the 8 new `WineRuntimeTests` pass; the package compiles with no warnings introduced by the new file.

- [ ] **Step 6: Commit**

```bash
git add Sources/WoWSiliconSwift/Services/WineRuntime.swift Tests/WoWSiliconSwiftTests/WineRuntimeTests.swift && git commit -m "feat: add WineRuntime service as single authority for bundled runtime paths

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: LaunchService single launch shape

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/LaunchService.swift` (error enum lines 4–43; `LaunchConfiguration` + `prepareLaunchArtifacts` lines 81–160; `makeShellCommand`/`doubleQuote` lines 247–270; `launchInstaller` lines 272–316; `launchThirdPartyLauncher` lines 318–399; `forceQuitWine` lines 520–544)
- Modify: `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift` (`forceQuitWine` lines 213–220)
- Test: Create `Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift`

**Interfaces:**
- Consumes (Task 4, `Sources/WoWSiliconSwift/Services/WineRuntime.swift`): `WineRuntime.shared`, `func validatedWineBinaryURL() throws -> URL`, `func validatedRosettaLoaderURL() throws -> URL`, `var rosettaLoaderURL: URL?`, `var wineBinaryURL: URL`, `var wineserverBinaryURL: URL`. Existing (kept until Task 9): `PatchingStatusChecker.evaluateGamePatch(for:) -> PatchStatusDescriptor` (`.applied`). Existing model: `VersionSettings` memberwise init (all params defaulted).
- Produces: `LaunchService.makeShellCommand(gamePath: String, executablePath: String, wineBinaryPath: String, rosettaLoaderPath: String?, settings: VersionSettings, extraArguments: [String] = []) -> String` (internal static, pure — used by `LaunchCommandTests`). `static func forceQuitWine()` — **SIGNATURE CHANGE for Task 8**: the old `forceQuitWine(crossOverPath: String?)` is gone; `MainDashboardViewModel.forceQuitWine()` is minimally updated in this task to call the zero-arg version, and Task 8's dashboard rework must not reintroduce a `crossOverPath` argument. `LaunchServiceError` no longer has `.wineMissing` / `.wineloader2Missing`; `.rosettaMissing(String)` message is now "Bundled rosettax87 loader not found. Please reinstall WoWSilicon."

- [ ] **Step 1: Write failing tests for the pure command builder**

Create `Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class LaunchCommandTests: XCTestCase {
    private let winePath = "/Applications/WoWSilicon.app/Contents/SharedSupport/wine/bin/wine"
    private let loaderPath = "/Applications/WoWSilicon.app/Contents/Resources/Patching/rosettax87/rosettax87"

    func testFullCommandWithLoaderAndDefaultSettings() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW Classic",
            executablePath: "/Games/WoW Classic/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            settings: VersionSettings()
        )

        XCTAssertEqual(
            command,
            "cd \"/Games/WoW Classic\" && " +
            "ROSETTA_X87_PATH=\"\(loaderPath)\" " +
            "WINEDLLOVERRIDES=\"d3d9=n,b;mscoree=d;mshtml=d\" MTL_HUD_ENABLED=0 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 DXVK_ASYNC=1 " +
            "\"\(winePath)\" \"/Games/WoW Classic/WoW.exe\""
        )
    }

    func testNilLoaderOmitsRosettaX87Path() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW Classic",
            executablePath: "/Games/WoW Classic/Installer.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: nil,
            settings: VersionSettings()
        )

        XCTAssertFalse(command.contains("ROSETTA_X87_PATH"))
        XCTAssertTrue(command.hasPrefix("cd \"/Games/WoW Classic\" && WINEDLLOVERRIDES=\"d3d9=n,b;mscoree=d;mshtml=d\" "))
    }

    func testCustomEnvironmentVariablesAreFlattenedBeforeBaseEnv() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            settings: VersionSettings(environmentVariables: "A=1\nB=2")
        )

        XCTAssertTrue(command.contains("ROSETTA_X87_PATH=\"\(loaderPath)\" A=1 B=2 WINEDLLOVERRIDES="))
    }

    func testMetalHudTogglesEnvironmentValue() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            settings: VersionSettings(enableMetalHud: true)
        )

        XCTAssertTrue(command.contains("MTL_HUD_ENABLED=1"))
        XCTAssertFalse(command.contains("MTL_HUD_ENABLED=0"))
    }

    func testExtraArgumentsAreAppendedQuotedAfterExecutable() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/Launcher",
            executablePath: "/Games/Launcher/Launcher.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            settings: VersionSettings(),
            extraArguments: ["--disable-gpu", "--in-process-gpu"]
        )

        XCTAssertTrue(command.hasSuffix("\"/Games/Launcher/Launcher.exe\" \"--disable-gpu\" \"--in-process-gpu\""))
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail to compile**

```bash
swift test --filter LaunchCommandTests
```

Expected failure: compile error in `LaunchCommandTests.swift` — `instance member 'makeShellCommand' cannot be used on type 'LaunchService'` (the only `makeShellCommand` today is the private instance method with CrossOver parameters).

- [ ] **Step 3: Add the internal static pure `makeShellCommand`**

In `Sources/WoWSiliconSwift/Services/LaunchService.swift`, insert directly after the closing brace of the existing private instance `makeShellCommand` (line 266), leaving the old instance method and instance `doubleQuote` in place for now (a static and an instance method may share the name):

```swift
    static func makeShellCommand(
        gamePath: String,
        executablePath: String,
        wineBinaryPath: String,
        rosettaLoaderPath: String?,
        settings: VersionSettings,
        extraArguments: [String] = []
    ) -> String {
        let mtlValue = settings.enableMetalHud ? "1" : "0"
        let baseEnv = "WINEDLLOVERRIDES=\"d3d9=n,b;mscoree=d;mshtml=d\" MTL_HUD_ENABLED=\(mtlValue) MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 DXVK_ASYNC=1"
        let custom = settings.environmentVariables
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ";", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var envParts: [String] = []
        if let rosettaLoaderPath {
            envParts.append("ROSETTA_X87_PATH=\(doubleQuote(rosettaLoaderPath))")
        }
        if !custom.isEmpty {
            envParts.append(custom)
        }
        envParts.append(baseEnv)

        var command = "cd \(doubleQuote(gamePath)) && \(envParts.joined(separator: " ")) \(doubleQuote(wineBinaryPath)) \(doubleQuote(executablePath))"
        for argument in extraArguments {
            command += " \(doubleQuote(argument))"
        }
        return command
    }

    private static func doubleQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
```

- [ ] **Step 4: Run the new tests green**

```bash
swift test --filter LaunchCommandTests
```

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Rework `prepareLaunchArtifacts` onto WineRuntime (single shape for the game path)**

Replace the `LaunchConfiguration` struct (lines 81–88) with:

```swift
    private struct LaunchConfiguration {
        let version: GameVersion
        let gameURL: URL
        let wowExecutableURL: URL
        let shellCommand: String
    }
```

Replace `prepareLaunchArtifacts` (lines 90–160) with:

```swift
    private func prepareLaunchArtifacts(for version: GameVersion) throws -> LaunchConfiguration {
        let trimmedGame = version.gamePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGame.isEmpty else { throw LaunchServiceError.gamePathMissing }

        let gameURL = URL(fileURLWithPath: trimmedGame, isDirectory: true)

        let wineBinaryURL = try WineRuntime.shared.validatedWineBinaryURL()
        let rosettaLoaderURL: URL
        do {
            rosettaLoaderURL = try WineRuntime.shared.validatedRosettaLoaderURL()
        } catch {
            throw LaunchServiceError.rosettaMissing(WineRuntime.shared.rosettaLoaderURL?.path ?? "app bundle resources")
        }

        let wowExecutableURL: URL
        if version.settings.enableVanillaTweaks {
            let tweakedURL = gameURL.appendingPathComponent("WoW_tweaked.exe")
            if fileManager.fileExists(atPath: tweakedURL.path) {
                wowExecutableURL = tweakedURL
            } else {
                throw LaunchServiceError.vanillaTweaksMissing
            }
        } else {
            let wowExe = gameURL.appendingPathComponent("WoW.exe")
            let ascensionExe = gameURL.appendingPathComponent("Ascension.exe")
            if fileManager.fileExists(atPath: wowExe.path) {
                wowExecutableURL = wowExe
            } else if fileManager.fileExists(atPath: ascensionExe.path) {
                wowExecutableURL = ascensionExe
            } else {
                wowExecutableURL = wowExe
            }
        }

        guard fileManager.fileExists(atPath: wowExecutableURL.path) else {
            throw LaunchServiceError.executableMissing(wowExecutableURL.path)
        }

        if version.settings.autoDeleteWdb {
            deleteWDBDirectories(at: gameURL)
        }

        let shellCommand = LaunchService.makeShellCommand(
            gamePath: gameURL.path,
            executablePath: wowExecutableURL.path,
            wineBinaryPath: wineBinaryURL.path,
            rosettaLoaderPath: rosettaLoaderURL.path,
            settings: version.settings
        )

        return LaunchConfiguration(
            version: version,
            gameURL: gameURL,
            wowExecutableURL: wowExecutableURL,
            shellCommand: shellCommand
        )
    }
```

Note: a thrown `WineRuntimeError` from `validatedWineBinaryURL()` flows through `launch()`'s generic `catch` into `.processLaunchFailed(error.localizedDescription)`, carrying Task 4's "Please reinstall WoWSilicon." message. The `patchNotApplied` gate at lines 61–63 and `patchesAppearValid(for:)` at lines 435–438 already check only `PatchingStatusChecker.evaluateGamePatch(for:).applied` — no CrossOver patch involvement — so they stay byte-for-byte unchanged (Task 9 will revisit the checker itself).

- [ ] **Step 6: Rework `launchInstaller` (loader optional, omit silently)**

Replace `launchInstaller` (lines 272–316) with:

```swift
    func launchInstaller(installerURL: URL, version: GameVersion, completion: @escaping @Sendable (Result<Void, LaunchServiceError>) -> Void) {
        let wineBinaryURL: URL
        do {
            wineBinaryURL = try WineRuntime.shared.validatedWineBinaryURL()
        } catch {
            DispatchQueue.main.async { completion(.failure(.processLaunchFailed(error.localizedDescription))) }
            return
        }

        let rosettaLoaderPath = (try? WineRuntime.shared.validatedRosettaLoaderURL())?.path

        let shellCommand = LaunchService.makeShellCommand(
            gamePath: installerURL.deletingLastPathComponent().path,
            executablePath: installerURL.path,
            wineBinaryPath: wineBinaryURL.path,
            rosettaLoaderPath: rosettaLoaderPath,
            settings: version.settings
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]
        process.environment = ProcessInfo.processInfo.environment

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.untrackProcess(process)
                self.processDidTerminate?()
                completion(.success(()))
            }
        }

        do {
            try process.run()
            trackProcess(process)
        } catch {
            DispatchQueue.main.async { completion(.failure(.processLaunchFailed(error.localizedDescription))) }
        }
    }
```

- [ ] **Step 7: Rework `launchThirdPartyLauncher` (single shape, loader required)**

Replace `launchThirdPartyLauncher` (lines 318–399) with:

```swift
    func launchThirdPartyLauncher(version: GameVersion, completion: @escaping @Sendable (Result<Void, LaunchServiceError>) -> Void) {
        let exePath = version.launcherExePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exePath.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.executableMissing("No launcher configured"))) }
            return
        }

        let wineBinaryURL: URL
        do {
            wineBinaryURL = try WineRuntime.shared.validatedWineBinaryURL()
        } catch {
            DispatchQueue.main.async { completion(.failure(.processLaunchFailed(error.localizedDescription))) }
            return
        }

        let rosettaLoaderURL: URL
        do {
            rosettaLoaderURL = try WineRuntime.shared.validatedRosettaLoaderURL()
        } catch {
            let expected = WineRuntime.shared.rosettaLoaderURL?.path ?? "app bundle resources"
            DispatchQueue.main.async { completion(.failure(.rosettaMissing(expected))) }
            return
        }

        let exeURL = URL(fileURLWithPath: exePath)
        let shellCommand = LaunchService.makeShellCommand(
            gamePath: exeURL.deletingLastPathComponent().path,
            executablePath: exeURL.path,
            wineBinaryPath: wineBinaryURL.path,
            rosettaLoaderPath: rosettaLoaderURL.path,
            settings: version.settings,
            extraArguments: ["--disable-gpu", "--in-process-gpu"]
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.untrackProcess(process)
                self.processDidTerminate?()
            }
        }

        do {
            try process.run()
            trackProcess(process)
            startFocusTimer()
            DispatchQueue.main.async { completion(.success(())) }
        } catch {
            DispatchQueue.main.async { completion(.failure(.processLaunchFailed(error.localizedDescription))) }
        }
    }
```

(This drops the `PatchingStatusChecker.evaluateGamePatch`-gated rosetta branch here — the loader is bundled and always used; the game-launch gate in `launch()` still calls `evaluateGamePatch`.)

- [ ] **Step 8: Delete the CrossOver-era command builder and error cases**

Delete the private instance `makeShellCommand(gameURL:rosettaURL:wowURL:wineloader2Path:crossOverVersion:settings:)` (old lines 247–266) and the private instance `doubleQuote` (old lines 268–270) — the static versions from Step 3 remain. Then replace the `LaunchServiceError` enum (lines 4–43) with:

```swift
enum LaunchServiceError: LocalizedError {
    case alreadyRunning
    case gamePathMissing
    case rosettaMissing(String)
    case executableMissing(String)
    case vanillaTweaksMissing
    case patchNotApplied
    case processLaunchFailed(String)
    case appleScriptFailed(String)
    case versionMismatch(String, String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The game is already running."
        case .gamePathMissing:
            return "Game path is not set. Please configure it before launching."
        case .rosettaMissing:
            return "Bundled rosettax87 loader not found. Please reinstall WoWSilicon."
        case .executableMissing(let path):
            return "WoW executable not found at \(path). Please verify your game installation."
        case .vanillaTweaksMissing:
            return "Vanilla Tweaks is enabled but WoW-tweaked.exe was not found. Disable the option or run the tweaks patch first."
        case .patchNotApplied:
            return "Patches no longer appear to be applied. Re-run the patching steps before launching."
        case .processLaunchFailed(let reason):
            return reason
        case .appleScriptFailed(let reason):
            return "Failed to launch in Terminal: \(reason)"
        case .versionMismatch(let base, let tweaked):
            return "Build mismatch detected.\n\nWoW.exe: \(base)\nWoW_tweaked.exe: \(tweaked)\n\nWoWSilicon can re-generate the tweaked executable for you."
        }
    }
}
```

- [ ] **Step 9: Retarget `forceQuitWine` at the bundled runtime and fix its caller**

Replace `static func forceQuitWine(crossOverPath: String?)` (lines 522–544) with:

```swift
    static func forceQuitWine() {
        func pkill(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
        }

        // Wine processes run with their Windows path as the process name (e.g. "Z:\Volumes\...\WoW.exe").
        // pkill -f matches against the full argument string, so matching ".exe" catches them all.
        pkill(["-9", "-f", ".exe"])

        // Kill the bundled runtime's wine and wineserver by path
        pkill(["-9", "-f", WineRuntime.shared.wineBinaryURL.path])
        pkill(["-9", "-f", WineRuntime.shared.wineserverBinaryURL.path])

        // Kill rosettax87 instances
        pkill(["-9", "-f", "rosettax87"])
    }
```

In `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift`, replace `forceQuitWine` (lines 213–220) with:

```swift
    func forceQuitWine() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            LaunchService.forceQuitWine()
            DispatchQueue.main.async { self?.refreshSnapshot() }
        }
    }
```

(Task 8 removes the remaining CrossOver UI from this view model; it must keep the zero-arg call.)

- [ ] **Step 10: Verify no CrossOver residue in LaunchService, full build and test suite green**

```bash
grep -n "CrossOver\|crossOver\|wineloader\|detectCrossOverVersion" /Users/sami.taaissat/Documents/Perso/WoWSilicon/Sources/WoWSiliconSwift/Services/LaunchService.swift
```

Expected: no output (exit code 1). Then:

```bash
swift build && swift test
```

Expected: build succeeds; all tests pass including the 5 `LaunchCommandTests`.

- [ ] **Step 11: Commit**

```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && git add Sources/WoWSiliconSwift/Services/LaunchService.swift Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift && git commit -m "$(cat <<'EOF'
refactor: single bundled-wine launch shape in LaunchService

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Swap wine-registry services to WineRuntime

**Files:**
- Test (create): `Tests/WoWSiliconSwiftTests/WineRegistrySupportTests.swift`
- Modify: `Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift` (lines 22–29)
- Modify: `Sources/WoWSiliconSwift/Services/OptionAsAltService.swift` (lines 3–18, 24–28, 60–65, 83–93)
- Modify: `Sources/WoWSiliconSwift/Services/RetinaModeService.swift` (lines 3–18, 23–27, 35–40, 69–70)
- Modify: `Sources/WoWSiliconSwift/Services/DependencyService.swift` (lines 26–47, 142–145)
- Modify: `Sources/WoWSiliconSwift/Services/VanillaTweaksService.swift` (lines 3–27, 42–50, 67–73, 127–142)
- Modify: `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift` (lines 487–498, 563–576, 612–625, 1042–1051 — minimal call-site fixes only, so the package keeps compiling; Task 8 does the full ViewModel/UI cleanup)

**Interfaces:**
- Consumes (Task 4): `WineRuntime.shared`, `func validatedWineBinaryURL() throws -> URL`, `enum WineRuntimeError: LocalizedError, Equatable` (case `.wineBinaryMissing(String)`); `var wineBinaryURL: URL`
- Consumes (existing): `ProcessRunner.run(executablePath:arguments:environment:currentDirectory:timeout:)`, `PatchService.resourceURL(named:extension:subdirectory:)`, `WineRegistrySupport.winePrefixURL()`, `WineRegistrySupport.makeWineEnvironment(prefixURL:wineExecutable:)`
- Produces (Task 8 ViewModel rework and later tasks rely on these exact signatures):
  - `WineRegistrySupport.wineBinaryPath() throws -> String`
  - `OptionAsAltService.setOptionAsAlt(enabled: Bool) throws`
  - `OptionAsAltService.isOptionAsAltEnabled() -> Bool`
  - `RetinaModeService.setRetinaMode(enabled: Bool) throws`
  - `RetinaModeService.isRetinaModeEnabled() -> Bool`
  - `DependencyService.installVisualCppRuntime() throws`
  - `VanillaTweaksService.applyTweaks(version: GameVersion) throws` (signature unchanged; no longer reads `version.crossOverPath`)
  - Error enums shrunk: `OptionAsAltServiceError`/`RetinaModeServiceError`/`DependencyServiceError` lose `.wineMissing`; `VanillaTweaksError` loses `.crossOverWineloaderMissing(String)`; missing-runtime failures now propagate `WineRuntimeError`
  - Unchanged and still exported: `WineRegistrySupport.winePrefixURL()`, `userRegURL()`, `isMacDriverSection(_:)`, `makeWineEnvironment(prefixURL:wineExecutable:)`, `OptionAsAltService.isOptionAsAltEnabledFast()`, `RetinaModeService.isRetinaModeEnabledFast()`

- [ ] **Step 1: Write failing test for `wineBinaryPath()` + `makeWineEnvironment` (red)**

Create `Tests/WoWSiliconSwiftTests/WineRegistrySupportTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class WineRegistrySupportTests: XCTestCase {
    func testWineBinaryPathThrowsWineRuntimeErrorWhenBundledRuntimeIsAbsent() {
        // The swift-test runner's Bundle.main carries no Contents/SharedSupport/wine
        // payload, so resolution must surface WineRuntime's typed error.
        let expectedPath = WineRuntime.shared.wineBinaryURL.path
        XCTAssertThrowsError(try WineRegistrySupport.wineBinaryPath()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .wineBinaryMissing(expectedPath))
        }
    }

    func testMakeWineEnvironmentSetsPrefixCompatLayerAndPrependsWineDirectoryToPath() {
        let prefixURL = URL(fileURLWithPath: "/tmp/wowsilicon-test-prefix", isDirectory: true)
        let wineExecutable = "/opt/wowsilicon-test/wine-runtime/bin/wine"

        let environment = WineRegistrySupport.makeWineEnvironment(prefixURL: prefixURL, wineExecutable: wineExecutable)

        XCTAssertEqual(environment["WINEPREFIX"], prefixURL.path)
        XCTAssertEqual(environment["__COMPAT_LAYER"], "RunAsInvoker")

        let pathComponents = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(pathComponents.first, "/opt/wowsilicon-test/wine-runtime/bin")
        XCTAssertEqual(pathComponents.filter { $0 == "/opt/wowsilicon-test/wine-runtime/bin" }.count, 1)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails to compile**

```bash
swift test --filter WineRegistrySupportTests
```

Expected failure:
```
error: type 'WineRegistrySupport' has no member 'wineBinaryPath'
```

- [ ] **Step 3: Implement `wineBinaryPath()` in WineRegistrySupport (green)**

In `Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift`, insert directly above `static func wineloaderPath(from crossOverPath: String?)` (line 22). Do NOT delete `wineloaderPath(from:)` yet — the four other services still call it until Steps 4–7:

```swift
    static func wineBinaryPath() throws -> String {
        try WineRuntime.shared.validatedWineBinaryURL().path
    }
```

Run:
```bash
swift test --filter WineRegistrySupportTests
```
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 4: Migrate OptionAsAltService off crossOverPath (plus its two ViewModel touch points)**

In `Sources/WoWSiliconSwift/Services/OptionAsAltService.swift`, replace the error enum (lines 3–18) with:

```swift
enum OptionAsAltServiceError: LocalizedError {
    case commandFailed(String)
    case registryWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            return output.isEmpty ? "Failed to update Wine registry." : output
        case .registryWriteFailed(let reason):
            return reason
        }
    }
}
```

Replace lines 24–28 (`setOptionAsAlt` head):

```swift
    static func setOptionAsAlt(enabled: Bool) throws {
        let wineExecutable = try WineRegistrySupport.wineBinaryPath()
```

Replace lines 60–65 (`isOptionAsAltEnabled`):

```swift
    static func isOptionAsAltEnabled() -> Bool {
        if let accurate = isOptionAsAltEnabledAccurately() {
            return accurate
        }
        return isOptionAsAltEnabledFast()
    }
```

Replace lines 83–87 (`isOptionAsAltEnabledAccurately` head):

```swift
    private static func isOptionAsAltEnabledAccurately() -> Bool? {
        guard let wineExecutable = try? WineRegistrySupport.wineBinaryPath() else {
            return nil
        }
```

In `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift`, in `setOptionAsAlt(_:)` (lines 563–576): replace `guard let currentVersion = versionManager.currentVersion else { return }` with `guard versionManager.currentVersion != nil else { return }`, delete the line `let crossOverPath = currentVersion.crossOverPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentVersion.crossOverPath`, and change the two calls to:

```swift
                try OptionAsAltService.setOptionAsAlt(enabled: enabled)
                let actual = OptionAsAltService.isOptionAsAltEnabled()
```

In `presentOptionAsAltDebugAlert(error:)` (lines 1044–1051), replace the switch with (the `.wineMissing` case no longer exists):

```swift
        if let optionError = error as? OptionAsAltServiceError {
            switch optionError {
            case .commandFailed(let output),
                 .registryWriteFailed(let output):
                detail = output
            }
        } else {
```

- [ ] **Step 5: Migrate RetinaModeService off crossOverPath (plus its ViewModel touch point)**

In `Sources/WoWSiliconSwift/Services/RetinaModeService.swift`, replace the error enum (lines 3–18) with:

```swift
enum RetinaModeServiceError: LocalizedError {
    case commandFailed(String)
    case registryWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            return output.isEmpty ? "Failed to update Wine registry." : output
        case .registryWriteFailed(let reason):
            return reason
        }
    }
}
```

Replace lines 23–27 (`setRetinaMode` head):

```swift
    static func setRetinaMode(enabled: Bool) throws {
        let wineExecutable = try WineRegistrySupport.wineBinaryPath()
```

Replace lines 35–40 (`isRetinaModeEnabled`):

```swift
    static func isRetinaModeEnabled() -> Bool {
        if let accurate = isRetinaModeEnabledAccurately() {
            return accurate
        }
        return isRetinaModeEnabledFast()
    }
```

Replace lines 69–70 (`isRetinaModeEnabledAccurately` head):

```swift
    private static func isRetinaModeEnabledAccurately() -> Bool? {
        guard let wineExecutable = try? WineRegistrySupport.wineBinaryPath() else { return nil }
```

In `MainDashboardViewModel.swift`, in `setRetinaMode(_:)` (lines 612–625): replace `guard let currentVersion = versionManager.currentVersion else { return }` with `guard versionManager.currentVersion != nil else { return }`, delete the `let crossOverPath = ...` line (line 619), and change the two calls to:

```swift
                try RetinaModeService.setRetinaMode(enabled: enabled)
                let actual = RetinaModeService.isRetinaModeEnabled()
```

- [ ] **Step 6: Migrate DependencyService off crossOverPath (plus its ViewModel touch point)**

In `Sources/WoWSiliconSwift/Services/DependencyService.swift`, replace the error enum (lines 26–47) with:

```swift
enum DependencyServiceError: LocalizedError {
    case downloadFailed(String)
    case installFailed(String)
    case verificationFailed
    case gitInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason):
            return "Failed to download Microsoft Visual C++ Redistributable: \(reason)"
        case .installFailed(let output):
            return output.isEmpty ? "Failed to install Microsoft Visual C++ Redistributable." : output
        case .verificationFailed:
            return "The installer finished, but the Visual C++ Runtime files were not found in the Wine prefix."
        case .gitInstallFailed(let reason):
            return reason
        }
    }
}
```

Replace lines 142–145 (`installVisualCppRuntime` head):

```swift
    static func installVisualCppRuntime() throws {
        let wineExecutable = try WineRegistrySupport.wineBinaryPath()
```

In `MainDashboardViewModel.swift` `installVisualCppRuntime()` (lines 487–498): replace `guard let currentVersion else { return }` with `guard currentVersion != nil else { return }`, delete the line `let crossOverPath = currentVersion.crossOverPath.trimmingCharacters(in: .whitespacesAndNewlines)`, and change the call to:

```swift
                try DependencyService.installVisualCppRuntime()
```

- [ ] **Step 7: Migrate VanillaTweaksService to WineRuntime**

In `Sources/WoWSiliconSwift/Services/VanillaTweaksService.swift`, replace the error enum (lines 3–27) with (drops `crossOverWineloaderMissing`; a missing runtime now propagates `WineRuntimeError` from Task 4):

```swift
enum VanillaTweaksError: LocalizedError {
    case resourcesMissing
    case wowExecutableMissing(String)
    case executionFailed(String)
    case outputMissing(String)
    case invalidParameterFormat(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            return "Could not locate vanilla-tweaks.exe in the app bundle."
        case .wowExecutableMissing(let path):
            return "WoW.exe not found at \(path)."
        case .executionFailed(let message):
            return message
        case .outputMissing(let output):
            return "vanilla-tweaks completed but WoW_tweaked.exe was not created.\n\(output)"
        case .invalidParameterFormat(let parameter):
            return "Invalid vanilla-tweaks parameter: \(parameter).\nUse '--flag' or '--flag value' formats."
        }
    }
}
```

Replace lines 42–50 (the CrossOver fallback block; note lines 42–46 carry trailing spaces — match carefully) with:

```swift
        let wineBinaryPath = try WineRuntime.shared.validatedWineBinaryURL().path
```

In the `ProcessRunner.run` call (lines 67–73), change the two arguments:

```swift
        let result = try ProcessRunner.run(
            executablePath: wineBinaryPath,
            arguments: try makeArguments(for: version.settings),
            environment: makeWineEnvironment(wineBinaryPath: wineBinaryPath),
            currentDirectory: gameURL,
            timeout: 300
        )
```

Replace the private helper head (lines 127–130):

```swift
    private static func makeWineEnvironment(wineBinaryPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        
        let wineDirectory = (wineBinaryPath as NSString).deletingLastPathComponent
```

(Rest of the helper body unchanged. `applyTweaks(version:)` signature is unchanged, so the two `MainDashboardViewModel` call sites at lines 370/411 need no edit.)

- [ ] **Step 8: Delete `WineRegistrySupport.wineloaderPath(from:)`**

In `Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift`, delete the entire function (originally lines 22–29):

```swift
    static func wineloaderPath(from crossOverPath: String?) -> String? {
        let resolvedPath = crossOverPath ?? "/Applications/CrossOver.app"
        let wineloader2Path = resolvedPath + "/Contents/SharedSupport/CrossOver/CrossOver-Hosted Application/wineloader2"
        guard FileManager.default.fileExists(atPath: wineloader2Path) else {
            return nil
        }
        return wineloader2Path
    }
```

- [ ] **Step 9: Verify no CrossOver references remain in the five service files**

```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && grep -rn "crossOverPath\|wineloader\|CrossOver" \
  Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift \
  Sources/WoWSiliconSwift/Services/DependencyService.swift \
  Sources/WoWSiliconSwift/Services/OptionAsAltService.swift \
  Sources/WoWSiliconSwift/Services/RetinaModeService.swift \
  Sources/WoWSiliconSwift/Services/VanillaTweaksService.swift; echo "grep exit: $?"
```

Expected: no matched lines, `grep exit: 1`.

- [ ] **Step 10: Full build and test suite green**

```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && swift build && swift test
```

Expected: build succeeds; all suites pass including the 2 new `WineRegistrySupportTests` tests and the pre-existing suites (`ConfigServiceTests`, `DXVKConfigServiceTests`, `ModelCompatibilityTests`, `ModServiceTests`, `RealmlistServiceTests`, `VersionStoreTests`, plus Task 4/5 suites), `0 failures`.

- [ ] **Step 11: Commit**

```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && git add \
  Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift \
  Sources/WoWSiliconSwift/Services/OptionAsAltService.swift \
  Sources/WoWSiliconSwift/Services/RetinaModeService.swift \
  Sources/WoWSiliconSwift/Services/DependencyService.swift \
  Sources/WoWSiliconSwift/Services/VanillaTweaksService.swift \
  Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift \
  Tests/WoWSiliconSwiftTests/WineRegistrySupportTests.swift \
&& git commit -m "$(cat <<'EOF'
refactor: resolve wine via bundled WineRuntime in registry services

Replaces wineloader2/CrossOver fallback resolution in WineRegistrySupport,
OptionAsAltService, RetinaModeService, DependencyService and
VanillaTweaksService with WineRuntime.shared.validatedWineBinaryURL();
drops the crossOverPath parameters and the CrossOver-specific error cases.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Troubleshooting: runtime info + Restore CrossOver helper

**Files:**
- Test (create): `Tests/WoWSiliconSwiftTests/TroubleshootingServiceTests.swift`
- Modify: `Sources/WoWSiliconSwift/Services/TroubleshootingService.swift` (add `CrossOverRestoreResult` + `restoreCrossOverModifications` after `TroubleshootingContext` at line 24; replace the `=== CrossOver Information ===` block, lines 158–204)
- Modify: `Sources/WoWSiliconSwift/ViewModels/TroubleshootingViewModel.swift` (published props lines 17–18; `refresh()` lines 36–68; delete `getCrossOverVersion` lines 70–88; add `restoreCrossOver()` after `deleteWinePrefixes` line 104)
- Modify: `Sources/WoWSiliconSwift/Views/TroubleshootingView.swift` (section call line 13; `crossoverSection` lines 43–56; `actionsSection` lines 58–72)

**Interfaces:**
- Consumes: `WineRuntime.shared`, `var runtimeVersion: String?`, `var wineBinaryURL: URL`, `var rosettaLoaderURL: URL?` (Task 4); `GameVersion.crossOverPath: String` (existing model property, kept as-is); existing `TroubleshootingService.generateDebugLog(context:hideMacUserName:includeLatestErrorLog:)` and `TroubleshootingViewModel.perform(action:work:)`.
- Produces: `struct CrossOverRestoreResult: Equatable { let restoredNtdll: Bool; let restoredWine: Bool; let removedWineloader2: Bool }`; `static func restoreCrossOverModifications(atCrossOverPath path: String) -> CrossOverRestoreResult` on `TroubleshootingService`; after this task no code outside `PatchService`/`PatchingStatusChecker` calls `PatchService.detectCrossOverVersion` (unblocks Task 10's deletion).

- [ ] **Step 1: Write failing tests for restoreCrossOverModifications**

Create `Tests/WoWSiliconSwiftTests/TroubleshootingServiceTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class TroubleshootingServiceTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testRestoreCrossOverModificationsRestoresEverything() throws {
        let crossOverURL = try makeTemporaryDirectory()
        let hostedAppDir = crossOverURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/CrossOver-Hosted Application", isDirectory: true)
        let unixDir = crossOverURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: hostedAppDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)

        try Data([0x01]).write(to: hostedAppDir.appendingPathComponent("wineloader2"))
        try Data([0x02]).write(to: unixDir.appendingPathComponent("ntdll.so"))     // patched copy
        try Data([0x03]).write(to: unixDir.appendingPathComponent("ntdll.so.bak")) // original
        try Data([0x04]).write(to: unixDir.appendingPathComponent("wine"))         // signature-stripped
        try Data([0x05]).write(to: unixDir.appendingPathComponent("wine.bak"))     // original

        let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverURL.path)

        XCTAssertEqual(result, CrossOverRestoreResult(restoredNtdll: true, restoredWine: true, removedWineloader2: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostedAppDir.appendingPathComponent("wineloader2").path))
        XCTAssertEqual(try Data(contentsOf: unixDir.appendingPathComponent("ntdll.so")), Data([0x03]))
        XCTAssertEqual(try Data(contentsOf: unixDir.appendingPathComponent("wine")), Data([0x05]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("ntdll.so.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("wine.bak").path))
    }

    func testRestoreCrossOverModificationsWithNothingToRestore() throws {
        let crossOverURL = try makeTemporaryDirectory()

        let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverURL.path)

        XCTAssertEqual(result, CrossOverRestoreResult(restoredNtdll: false, restoredWine: false, removedWineloader2: false))
    }

    func testRestoreCrossOverModificationsPartialRestoreNtdllOnly() throws {
        let crossOverURL = try makeTemporaryDirectory()
        let unixDir = crossOverURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try Data([0x02]).write(to: unixDir.appendingPathComponent("ntdll.so"))
        try Data([0x03]).write(to: unixDir.appendingPathComponent("ntdll.so.bak"))

        let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverURL.path)

        XCTAssertEqual(result, CrossOverRestoreResult(restoredNtdll: true, restoredWine: false, removedWineloader2: false))
        XCTAssertEqual(try Data(contentsOf: unixDir.appendingPathComponent("ntdll.so")), Data([0x03]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("ntdll.so.bak").path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
```

- [ ] **Step 2: Run tests, confirm compile failure**

```bash
swift test --filter TroubleshootingServiceTests
```

Expected failure: build error `cannot find 'CrossOverRestoreResult' in scope` and `type 'TroubleshootingService' has no member 'restoreCrossOverModifications'`.

- [ ] **Step 3: Implement CrossOverRestoreResult + restoreCrossOverModifications**

In `Sources/WoWSiliconSwift/Services/TroubleshootingService.swift`, insert after the closing brace of `TroubleshootingContext` (line 24), before `enum TroubleshootingService {`:

```swift
struct CrossOverRestoreResult: Equatable {
    let restoredNtdll: Bool
    let restoredWine: Bool
    let removedWineloader2: Bool
}
```

Then inside `enum TroubleshootingService`, add after `deleteWinePrefixes` (after line 73):

```swift
    /// Best-effort revert of the v2.x CrossOver patch. Never throws; each
    /// missing piece is silently skipped and reported as false in the result.
    static func restoreCrossOverModifications(atCrossOverPath path: String) -> CrossOverRestoreResult {
        let fm = FileManager.default
        let shareDir = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("SharedSupport", isDirectory: true)
            .appendingPathComponent("CrossOver", isDirectory: true)

        var removedWineloader2 = false
        let wineloader2 = shareDir
            .appendingPathComponent("CrossOver-Hosted Application", isDirectory: true)
            .appendingPathComponent("wineloader2", isDirectory: false)
        if fm.fileExists(atPath: wineloader2.path) {
            if (try? fm.removeItem(at: wineloader2)) != nil {
                removedWineloader2 = true
            }
        }

        let unixDir = shareDir
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("wine", isDirectory: true)
            .appendingPathComponent("x86_64-unix", isDirectory: true)

        var restoredNtdll = false
        let ntdllBackup = unixDir.appendingPathComponent("ntdll.so.bak", isDirectory: false)
        let ntdllActive = unixDir.appendingPathComponent("ntdll.so", isDirectory: false)
        if fm.fileExists(atPath: ntdllBackup.path) {
            try? fm.removeItem(at: ntdllActive)
            if (try? fm.moveItem(at: ntdllBackup, to: ntdllActive)) != nil {
                restoredNtdll = true
            }
        }

        var restoredWine = false
        let wineBackup = unixDir.appendingPathComponent("wine.bak", isDirectory: false)
        let wineActive = unixDir.appendingPathComponent("wine", isDirectory: false)
        if fm.fileExists(atPath: wineBackup.path) {
            try? fm.removeItem(at: wineActive)
            if (try? fm.moveItem(at: wineBackup, to: wineActive)) != nil {
                restoredWine = true
            }
        }

        return CrossOverRestoreResult(
            restoredNtdll: restoredNtdll,
            restoredWine: restoredWine,
            removedWineloader2: removedWineloader2
        )
    }
```

- [ ] **Step 4: Run tests green**

```bash
swift test --filter TroubleshootingServiceTests
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Commit the restore helper**

```bash
git add Sources/WoWSiliconSwift/Services/TroubleshootingService.swift Tests/WoWSiliconSwiftTests/TroubleshootingServiceTests.swift && git commit -m "feat: add best-effort CrossOver modification restore to TroubleshootingService

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Replace debug-log CrossOver probing with bundled runtime info**

In `Sources/WoWSiliconSwift/Services/TroubleshootingService.swift`, replace lines 158–204 (from `baseLog = "\n=== CrossOver Information ===\n"` through the closing `}` of its `else` branch — the whole block including the `PatchService.detectCrossOverVersion` call, wineloader2 check, and wine.bak/ntdll.so.bak checks) with:

```swift
        baseLog = "\n=== Bundled Runtime ===\n"
        let runtime = WineRuntime.shared
        baseLog += "Runtime Version: \(runtime.runtimeVersion ?? "missing")\n"
        let winePath = runtime.wineBinaryURL.path
        baseLog += "Wine Binary: \(winePath)\n"
        baseLog += "  Exists: " + (FileManager.default.fileExists(atPath: winePath) ? "✓ Yes\n" : "✗ No\n")
        baseLog += "  Executable: " + (FileManager.default.isExecutableFile(atPath: winePath) ? "✓ Yes\n" : "✗ No\n")
        if let loader = runtime.rosettaLoaderURL {
            baseLog += "rosettax87 Loader: \(loader.path)\n"
        } else {
            baseLog += "rosettax87 Loader: missing\n"
        }
```

- [ ] **Step 7: Verify build and full suite still green**

```bash
swift build && swift test
```

Expected: build succeeds, all tests pass (no test asserts on the old debug-log section).

- [ ] **Step 8: Commit the debug-log rework**

```bash
git add Sources/WoWSiliconSwift/Services/TroubleshootingService.swift && git commit -m "refactor: debug log reports bundled Wine runtime instead of CrossOver

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Rework TroubleshootingViewModel — runtime info + restoreCrossOver()**

In `Sources/WoWSiliconSwift/ViewModels/TroubleshootingViewModel.swift`, replace lines 17–18:

```swift
    @Published var crossoverVersion: String = "Not found"
    @Published var crossoverRecommended = false
```

with:

```swift
    @Published var runtimeVersion: String = "Not found"
    @Published var rosettaStatus: String = "missing"
```

Replace the body of `refresh()` (lines 36–68) with:

```swift
    func refresh() {
        status = .busy("Collecting information…")
        let context = self.context
        Task.detached { [weak self] in
            guard let self else { return }

            let runtime = WineRuntime.shared
            let version = runtime.runtimeVersion ?? "Not found"
            let rosetta = runtime.rosettaLoaderURL != nil ? "ok" : "missing"

            // Capture current toggle states
            let hideName = await self.hideMacUserName
            let includeLog = await self.includeLatestErrorLog

            let result = TroubleshootingService.generateDebugLog(
                context: context,
                hideMacUserName: hideName,
                includeLatestErrorLog: includeLog
            )

            Task { @MainActor in
                self.runtimeVersion = version
                self.rosettaStatus = rosetta
                self.debugLog = result.preview
                self.fullDebugLog = result.full
                self.status = .ready
            }
        }
    }
```

Delete `private nonisolated static func getCrossOverVersion(at:)` entirely (lines 70–88).

Add after `deleteWinePrefixes()` (after line 104):

```swift
    func restoreCrossOver() {
        let customPath = context.currentVersion?.crossOverPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let crossOverPath = customPath.isEmpty ? "/Applications/CrossOver.app" : customPath
        perform(action: "Restoring CrossOver…") {
            let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverPath)
            var lines: [String] = []
            if result.restoredNtdll { lines.append("Restored ntdll.so from backup.") }
            if result.restoredWine { lines.append("Restored wine from backup.") }
            if result.removedWineloader2 { lines.append("Removed wineloader2.") }
            if lines.isEmpty {
                return "No WoWSilicon modifications found at \(crossOverPath)."
            }
            return lines.joined(separator: "\n")
        }
    }
```

- [ ] **Step 10: Rework TroubleshootingView — runtime section + restore button**

In `Sources/WoWSiliconSwift/Views/TroubleshootingView.swift`, add a state var after line 5 (`let onClose: () -> Void`):

```swift
    @State private var showRestoreConfirmation = false
```

Change line 13 from `crossoverSection` to `runtimeSection`. Replace `crossoverSection` (lines 43–56) with:

```swift
    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wine Runtime").font(.headline)
            HStack {
                Text("Wine runtime: \(viewModel.runtimeVersion)")
                Spacer()
                Text("rosettax87: bundled (\(viewModel.rosettaStatus))")
            }
        }
    }
```

In `actionsSection`, insert directly after the `Delete Wine Prefixes` button (after line 64):

```swift
            VStack(alignment: .leading, spacing: 4) {
                Button("Restore CrossOver Modifications") {
                    showRestoreConfirmation = true
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "Restore CrossOver Modifications?",
                    isPresented: $showRestoreConfirmation
                ) {
                    Button("Restore", role: .destructive, action: viewModel.restoreCrossOver)
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This reverts the CrossOver patch applied by WoWSilicon 2.x: restores ntdll.so and wine from their backups and removes wineloader2.")
                }
                Text("Only needed if you patched CrossOver with WoWSilicon 2.x")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 11: Verify build and full suite green**

```bash
swift build && swift test
```

Expected: build succeeds (no remaining references to `crossoverVersion`, `crossoverRecommended`, or `getCrossOverVersion`), all tests pass.

```bash
grep -rn "detectCrossOverVersion\|crossoverVersion\|crossoverRecommended" Sources/WoWSiliconSwift/Services/TroubleshootingService.swift Sources/WoWSiliconSwift/ViewModels/TroubleshootingViewModel.swift Sources/WoWSiliconSwift/Views/TroubleshootingView.swift; echo "exit=$?"
```

Expected: no matches, `exit=1`.

- [ ] **Step 12: Commit the UI rework**

```bash
git add Sources/WoWSiliconSwift/ViewModels/TroubleshootingViewModel.swift Sources/WoWSiliconSwift/Views/TroubleshootingView.swift && git commit -m "feat: troubleshooting shows bundled runtime info and adds Restore CrossOver Modifications

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Remove CrossOver from dashboard UI + view models

**Files:**
- Test: `Tests/WoWSiliconSwiftTests/ModelCompatibilityTests.swift` (add 1 pin-down test)
- Modify: `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift` (lines 12, 17–19, 123, 213–220, 238–254, 315, 481–513, 563–592, 612–639, 836–878, 903–991, 1042–1063)
- Modify: `Sources/WoWSiliconSwift/Views/MainDashboardView.swift` (lines 41–60, 341–421, 636)
- Modify: `Sources/WoWSiliconSwift/Views/OptionsView.swift` (lines 281–286)

**Interfaces:**
- Consumes: `WineRuntime.shared.validatedWineBinaryURL() throws -> URL` (Task 4); `LaunchService.forceQuitWine()` (Task 5, no argument); `DependencyService.installVisualCppRuntime() throws` (Task 6, no crossOverPath); `OptionAsAltService.setOptionAsAlt(enabled: Bool) throws` + `OptionAsAltService.isOptionAsAltEnabled() -> Bool` (Task 6); `RetinaModeService.setRetinaMode(enabled: Bool) throws` + `RetinaModeService.isRetinaModeEnabled() -> Bool` (Task 6); `OptionAsAltServiceError` without `.wineMissing` (Task 6); existing `PatchingStatusChecker.evaluateGamePatch(for:) -> PatchStatusDescriptor`; existing `StatusValue`/`StatusLevel` (`Sources/WoWSiliconSwift/AppSupport/DashboardStatus.swift`)
- Produces: `MainDashboardViewModel.isRuntimeValid: Bool` and `MainDashboardViewModel.runtimeStatus: StatusValue?` (dashboard runtime row, shown only when broken); after this task nothing in the app calls `PatchingStatusChecker.evaluateCrossOverPatch`, `PatchService.applyCrossOverPatch`, `PatchService.removeCrossOverPatch`, or `PatchServiceError.crossOverNotFound` from UI/view-model code — unblocking their deletion in Tasks 9 and 10. `GameVersion.crossOverPath` remains untouched (backward-compat, pinned by the new test).

- [ ] **Step 1: Add pin-down test proving v2 `versions.json` entries with `crossover_path` still decode and round-trip**

In `Tests/WoWSiliconSwiftTests/ModelCompatibilityTests.swift`, add inside `final class ModelCompatibilityTests: XCTestCase`, after `testVersionSettingsDecodesFilesContainingRemovedSaveSudoPasswordKey` (before the closing brace at line 47):

```swift
    func testGameVersionDecodesAndRoundTripsV2CrossOverPath() throws {
        let json = """
        {
          "id": "vanillasilicon",
          "display_name": "VanillaSilicon (1.12.1)",
          "wow_version": "1.12.1",
          "game_path": "/Games/WoW",
          "crossover_path": "/Applications/CrossOver.app",
          "supports_vanilla_tweaks": true,
          "supports_dll_loading": true,
          "uses_rosetta_patching": true,
          "uses_divx_decoder_patch": false,
          "optimization_level": "high"
        }
        """

        let version = try JSONDecoder().decode(GameVersion.self, from: Data(json.utf8))
        XCTAssertEqual(version.crossOverPath, "/Applications/CrossOver.app")
        XCTAssertEqual(version.gamePath, "/Games/WoW")

        // Re-encode: the stored value must survive on disk (backward compat with v2).
        let reencoded = try JSONEncoder().encode(version)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertEqual(object["crossover_path"] as? String, "/Applications/CrossOver.app")

        let roundTripped = try JSONDecoder().decode(GameVersion.self, from: reencoded)
        XCTAssertEqual(roundTripped.crossOverPath, "/Applications/CrossOver.app")
    }
```

- [ ] **Step 2: Run the new test — it must PASS immediately (pin-down: the model is intentionally untouched)**

```bash
swift test --filter ModelCompatibilityTests
```

Expected: `Executed 3 tests, with 0 failures`. If `testGameVersionDecodesAndRoundTripsV2CrossOverPath` fails, STOP — someone changed `GameVersion` Codable behavior, which violates the backward-compat lock; fix that regression before proceeding.

- [ ] **Step 3: Commit the pin-down test**

```bash
git add Tests/WoWSiliconSwiftTests/ModelCompatibilityTests.swift && git commit -m "test: pin GameVersion crossover_path decode/round-trip for v2 compat

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: VM — delete CrossOver published state, add runtime-valid state**

In `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift`, replace lines 11–19:

```swift
    @Published private(set) var gamePathStatus = StatusValue(text: "Not set", level: .error)
    @Published private(set) var crossOverPathStatus = StatusValue(text: "Not set", level: .error)

    @Published private(set) var gamePatchStatus = StatusValue(text: "Not Applied", level: .error)
    @Published private(set) var isGamePatched: Bool = false
    @Published private(set) var isGamePatchActionable: Bool = false
    @Published private(set) var crossOverPatchStatus = StatusValue(text: "Not Applied", level: .error)
    @Published private(set) var isCrossOverPatched: Bool = false
    @Published private(set) var isCrossOverPatchActionable: Bool = false
```

with:

```swift
    @Published private(set) var gamePathStatus = StatusValue(text: "Not set", level: .error)

    @Published private(set) var gamePatchStatus = StatusValue(text: "Not Applied", level: .error)
    @Published private(set) var isGamePatched: Bool = false
    @Published private(set) var isGamePatchActionable: Bool = false
    /// True while the bundled Wine runtime validates. Defaults to true so the error
    /// row never flashes before the first refreshPatchStatuses pass completes.
    @Published private(set) var isRuntimeValid: Bool = true

    /// Surfaced on the dashboard ONLY when the bundled runtime is broken.
    var runtimeStatus: StatusValue? {
        isRuntimeValid ? nil : StatusValue(text: "missing — reinstall WoWSilicon", level: .error)
    }
```

- [ ] **Step 5: VM — delete `selectCrossOverPath`, drop the `addVersion` crossOverPath reset, drop the `forceQuitWine` argument**

Delete the whole `selectCrossOverPath()` method (lines 238–254):

```swift
    func selectCrossOverPath() {
        let panel = NSOpenPanel()
        panel.title = "Select CrossOver Application"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.level = .modalPanel
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let url = panel.url {
            updateCurrentVersion { version in
                version.crossOverPath = url.path
            }
        }
    }
```

In `addVersion` (line 123), delete the single line:

```swift
        newVersion.crossOverPath = ""
```

(the model keeps the property; new profiles simply use its `""` default — no non-model code touches it anymore).

Replace `forceQuitWine()` (lines 213–220) entirely with:

```swift
    func forceQuitWine() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            LaunchService.forceQuitWine()
            DispatchQueue.main.async { self?.refreshSnapshot() }
        }
    }
```

- [ ] **Step 6: VM — rework `refreshSnapshot` and `refreshPatchStatuses` (new `canLaunch` = gamePath set + game patch applied + runtime valid)**

In `refreshSnapshot()`, replace the guard-else body (lines 904–925) with:

```swift
        guard var currentVersion = versionManager.currentVersion else {
            versionDisplayName = "WoWSilicon"
            supportsMods = false
            self.currentVersion = nil
            gamePathStatus = StatusValue(text: "Not set", level: .error)
            gamePatchStatus = StatusValue(text: "Not Applied", level: .error)
            versions = versionManager.orderedVersions()
            currentVersionID = versionManager.currentVersionID
            patchStatusRefreshID += 1
            isGamePatched = false
            isGamePatchActionable = false
            canLaunch = false
            currentVersionHasLauncher = false
            currentVersionWantsLauncher = false
            launcherPathStatus = StatusValue(text: "Not set", level: .error)
            currentVersionLauncherName = "Open Launcher"
            return
        }
```

Replace lines 934–945 (`gamePathStatus = …` through `refreshPatchStatuses(…)`) with:

```swift
        gamePathStatus = makePathStatus(for: currentVersion.gamePath)

        gamePatchStatus = StatusValue(text: "Checking...", level: .info)
        isGamePatched = false
        isGamePatchActionable = false
        canLaunch = false
        refreshPatchStatuses(for: currentVersion)
```

Replace the whole `refreshPatchStatuses(for:crossOverPathSet:)` method (lines 964–991) with:

```swift
    private func refreshPatchStatuses(for version: GameVersion) {
        patchStatusRefreshID += 1
        let refreshID = patchStatusRefreshID

        Task.detached { [version] in
            let gamePatchDescriptor = PatchingStatusChecker.evaluateGamePatch(for: version)
            let runtimeValid = (try? WineRuntime.shared.validatedWineBinaryURL()) != nil

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.patchStatusRefreshID == refreshID else { return }
                guard self.currentVersion?.id == version.id else { return }

                self.gamePatchStatus = StatusValue(text: gamePatchDescriptor.text, level: gamePatchDescriptor.level)
                self.isGamePatched = gamePatchDescriptor.applied
                self.isGamePatchActionable = gamePatchDescriptor.actionable
                self.isRuntimeValid = runtimeValid

                let gamePathReady = !version.gamePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                self.canLaunch = gamePathReady && gamePatchDescriptor.applied && runtimeValid
            }
        }
    }
```

- [ ] **Step 7: VM — delete `patchCrossOver`/`unpatchCrossOver`, update the launch-guard error copy**

Delete both methods entirely (lines 836–878):

```swift
    func patchCrossOver() {
        // … whole method …
    }

    func unpatchCrossOver() {
        // … whole method …
    }
```

(These are the last callers of `PatchService.applyCrossOverPatch` / `removeCrossOverPatch` / `PatchServiceError.crossOverNotFound` in the UI layer — Task 10 deletes the APIs themselves.)

In `launchGame()` replace line 315:

```swift
            patchFeedback = PatchFeedback(title: "Cannot Launch", message: "Ensure the game path is set, Wine is installed, and both patches are applied.", isError: true)
```

with:

```swift
            patchFeedback = PatchFeedback(title: "Cannot Launch", message: "Ensure the game path is set and the game patch is applied.", isError: true)
```

- [ ] **Step 8: VM — dependency install gating on runtime + game path, call the no-arg `DependencyService.installVisualCppRuntime()`**

Replace `canInstallDependencies` (lines 481–485) and the top of `installVisualCppRuntime()` (lines 487–498) so they read:

```swift
    var canInstallDependencies: Bool {
        guard let currentVersion else { return false }
        let gamePathSet = !currentVersion.gamePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isRuntimeValid && gamePathSet && !isDependencyInstallInProgress
    }

    func installVisualCppRuntime() {
        guard canInstallDependencies else { return }

        isDependencyInstallInProgress = true
        visualCppRuntimeStatus = .inProgress("Installing...")
        patchFeedback = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try DependencyService.installVisualCppRuntime()
```

(the `guard let currentVersion` + `let crossOverPath = …` lines are removed; the success/failure closures below line 499 are unchanged).

- [ ] **Step 9: VM — drop crossOverPath from Option-as-Alt and Retina calls; remove the dead `.wineMissing` mapping**

In `setOptionAsAlt(_:)` (lines 563–576), replace:

```swift
        guard let currentVersion = versionManager.currentVersion else { return }

        isOptionAsAltBusy = true
        optionAsAltStatus = .inProgress(enabled ? "Enabling…" : "Disabling…")

        let crossOverPath = currentVersion.crossOverPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentVersion.crossOverPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try OptionAsAltService.setOptionAsAlt(enabled: enabled, crossOverPath: crossOverPath)
                let actual = OptionAsAltService.isOptionAsAltEnabled(crossOverPath: crossOverPath)
```

with:

```swift
        guard versionManager.currentVersion != nil else { return }

        isOptionAsAltBusy = true
        optionAsAltStatus = .inProgress(enabled ? "Enabling…" : "Disabling…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try OptionAsAltService.setOptionAsAlt(enabled: enabled)
                let actual = OptionAsAltService.isOptionAsAltEnabled()
```

In `setRetinaMode(_:)` (lines 612–625), apply the identical change:

```swift
        guard versionManager.currentVersion != nil else { return }

        isRetinaModeBusy = true
        retinaModeStatus = .inProgress(enabled ? "Enabling…" : "Disabling…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try RetinaModeService.setRetinaMode(enabled: enabled)
                let actual = RetinaModeService.isRetinaModeEnabled()
```

In `presentOptionAsAltDebugAlert(error:)` (lines 1044–1051), the `.wineMissing` case no longer exists after Task 6 (the compiler will flag it). Replace the switch:

```swift
            switch optionError {
            case .commandFailed(let output),
                 .registryWriteFailed(let output):
                detail = output
            case .wineMissing:
                detail = "Wine is not installed"
            }
```

with:

```swift
            switch optionError {
            case .commandFailed(let output),
                 .registryWriteFailed(let output):
                detail = output
            }
```

- [ ] **Step 10: View — remove CrossOver rows from `MainDashboardView`, add the broken-runtime row, ungate Game Patch, update onboarding copy**

In `Sources/WoWSiliconSwift/Views/MainDashboardView.swift`, replace the `MainContentView(...)` call (lines 41–60) with:

```swift
                MainContentView(
                    gameStatus: viewModel.gamePathStatus,
                    gamePatchStatus: viewModel.gamePatchStatus,
                    runtimeStatus: viewModel.runtimeStatus,
                    onSelectGamePath: viewModel.selectGamePath,
                    isGamePatched: viewModel.isGamePatched,
                    isGamePatchActionable: viewModel.isGamePatchActionable,
                    isGameOperationInProgress: viewModel.isGameOperationInProgress,
                    onPatchGame: viewModel.patchGame,
                    onUnpatchGame: viewModel.unpatchGame,
                    wantsLauncher: viewModel.currentVersionWantsLauncher,
                    launcherPathStatus: viewModel.launcherPathStatus,
                    onSelectLauncherPath: viewModel.selectLauncherPath
                )
```

Replace the `MainContentView` struct's properties and `body` (lines 341–421, up to but not including `.frame(maxWidth: .infinity, alignment: .leading)`) with:

```swift
struct MainContentView: View {
    let gameStatus: StatusValue
    let gamePatchStatus: StatusValue
    let runtimeStatus: StatusValue?
    let onSelectGamePath: () -> Void
    let isGamePatched: Bool
    let isGamePatchActionable: Bool
    let isGameOperationInProgress: Bool
    let onPatchGame: () -> Void
    let onUnpatchGame: () -> Void
    let wantsLauncher: Bool
    let launcherPathStatus: StatusValue
    let onSelectLauncherPath: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

            VStack(alignment: .leading, spacing: 12) {
                if let runtimeStatus {
                    HStack(spacing: 12) {
                        Text("Runtime:")
                            .frame(width: 150, alignment: .leading)
                        StatusLabel(value: runtimeStatus)
                    }
                }
                if wantsLauncher {
                    PathRow(
                        label: "Launcher Path:",
                        status: launcherPathStatus,
                        buttonTitle: "Set/Change",
                        action: onSelectLauncherPath
                    )
                }
                PathRow(
                    label: "Game Path:",
                    status: gameStatus,
                    buttonTitle: "Set/Change",
                    action: onSelectGamePath
                )
            }

            Divider()
                .opacity(0.8)

            VStack(alignment: .leading, spacing: 12) {
                PatchRow(
                    label: "Game Patch:",
                    status: gamePatchStatus,
                    primaryActionTitle: "Patch",
                    secondaryActionTitle: "Unpatch",
                    primaryDisabled: isGameOperationInProgress || !isGamePatchActionable || isGamePatched,
                    secondaryDisabled: isGameOperationInProgress || !isGamePatchActionable || !isGamePatched,
                    primaryAction: onPatchGame,
                    secondaryAction: onUnpatchGame
                )
            }
        }
```

(This removes the `CrossOver:` `PathRow`, the `CrossOver Patch:` `PatchRow`, and the `|| !isCrossOverPatched` gate on the Game Patch button. The runtime row renders red via `StatusLevel.error` and only appears when the runtime is broken.)

In `AddVersionSheet` (line 636), replace:

```swift
                    Text("You can install the launcher after setting up CrossOver.")
```

with:

```swift
                    Text("You can install the launcher once the game patch is applied.")
```

- [ ] **Step 11: OptionsView — re-key `dependenciesHelpText` off the game patch**

In `Sources/WoWSiliconSwift/Views/OptionsView.swift`, replace lines 281–286:

```swift
    private var dependenciesHelpText: String {
        if viewModel.isCrossOverPatched {
            return "Installs Microsoft's x86 Visual C++ Runtime into ~/.wine using the patched CrossOver wineloader."
        }
        return "Set and patch CrossOver before installing dependencies."
    }
```

with:

```swift
    private var dependenciesHelpText: String {
        if viewModel.isGamePatched {
            return "Installs the Microsoft Visual C++ runtime into the Wine prefix using the bundled runtime."
        }
        return "Set the game path and apply the game patch before installing dependencies."
    }
```

- [ ] **Step 12: Verify no CrossOver reference survives in the UI layer, then build**

```bash
grep -rn "crossOver\|CrossOver" Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift Sources/WoWSiliconSwift/Views/MainDashboardView.swift Sources/WoWSiliconSwift/Views/OptionsView.swift; swift build
```

Expected: grep prints nothing (exit code 1); `swift build` finishes with `Build complete!`. If the compiler reports leftover references to `crossOverPathStatus`, `isCrossOverPatched`, `patchCrossOver`, etc., fix those call sites — do not re-add the symbols.

- [ ] **Step 13: Full test suite must stay green**

```bash
swift test
```

Expected: 0 failures, including `ModelCompatibilityTests/testGameVersionDecodesAndRoundTripsV2CrossOverPath` (proves the UI removal did not touch `GameVersion` persistence).

- [ ] **Step 14: Commit**

```bash
git add Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift Sources/WoWSiliconSwift/Views/MainDashboardView.swift Sources/WoWSiliconSwift/Views/OptionsView.swift && git commit -m "refactor: remove CrossOver rows, actions, and gating from dashboard UI

canLaunch is now game path + game patch + bundled runtime validity; a red
Runtime row appears only when the bundled Wine runtime is broken.
GameVersion.crossover_path persistence is intentionally untouched.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: PatchingStatusChecker: drop CrossOver + game-folder rosettax87

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PatchingStatusChecker.swift` (delete lines 118-208 `evaluateCrossOverPatch`; edit lines 37-42 required-files; edit lines 256-286 `resourceExpectations`)
- Create/Test: `Tests/WoWSiliconSwiftTests/PatchingStatusCheckerTests.swift`

**Interfaces:**
- Consumes: `PatchService.resourceURL(named:extension:subdirectory:) -> URL?`, `PatchService.isSupportedGameClient(at:) -> Bool` (both KEPT in Task 10), `GameVersion` init from `Models/GameVersion.swift`, `StatusLevel` (`AppSupport/DashboardStatus.swift`)
- Produces: `PatchingStatusChecker.evaluateGamePatch(for:)` with no game-folder rosettax87 requirement; `evaluateCrossOverPatch` no longer exists (Task 10 relies on `PatchService.isSigned`/`detectCrossOverVersion` having zero remaining callers)

- [ ] **Step 1: Verify Task 8 precondition — no callers of evaluateCrossOverPatch remain**
```bash
grep -rn "evaluateCrossOverPatch" /Users/sami.taaissat/Documents/Perso/WoWSilicon/Sources/ --include="*.swift" | grep -v "Services/PatchingStatusChecker.swift"
```
Expected output: empty (Task 8 removed the `MainDashboardViewModel.swift:970` caller). If anything prints, STOP — Task 8 is incomplete.

- [ ] **Step 2: Write failing tests pinning the new game-patch expectations**

Create `Tests/WoWSiliconSwiftTests/PatchingStatusCheckerTests.swift`:
```swift
import XCTest
@testable import WoWSiliconSwift

final class PatchingStatusCheckerTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    /// Regression pin for the v2 "Play does nothing" failure mode: the checker
    /// must no longer demand <game>/rosettax87/. File-existence tier only —
    /// deliberately independent of bundled-resource checksum resolution.
    func testGamePatchDoesNotRequireGameFolderRosettax87() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try Data([0x01]).write(to: modsURL.appendingPathComponent("winerosetta.dll"))
        try Data([0x02]).write(to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
        // Deliberately NO <game>/rosettax87/ directory.

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertNotEqual(descriptor.text, "Missing rosettax87")
        XCTAssertFalse(
            descriptor.text.contains("rosettax87"),
            "checker must not demand game-folder rosettax87, got: \(descriptor.text)"
        )
    }

    /// Full "Applied" tier: real bundled resource bytes so the checksum
    /// comparison passes. Skipped (not failed) if the SPM resource bundle is
    /// unreachable under swift test — the existence tier above always runs.
    func testGamePatchAppliedWithBundledResourceCopies() throws {
        let winerosettaSource = PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta")
        let d3d9Source = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk")
        try XCTSkipIf(
            winerosettaSource == nil || d3d9Source == nil,
            "Bundled patch resources not resolvable under swift test; existence tier covered by other tests"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: winerosettaSource!, to: modsURL.appendingPathComponent("winerosetta.dll"))
        try FileManager.default.copyItem(at: d3d9Source!, to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
        // Deliberately NO <game>/rosettax87/ directory.

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertTrue(descriptor.applied, "expected Applied, got: \(descriptor.text)")
        XCTAssertEqual(descriptor.text, "Applied")
        XCTAssertEqual(descriptor.level, .success)
    }

    /// The existence tier itself must survive the change.
    func testGamePatchStillReportsMissingWinerosetta() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        try Data([0x02]).write(to: gameURL.appendingPathComponent("d3d9.dll"))

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Missing winerosetta.dll")
        XCTAssertEqual(descriptor.level, .error)
    }

    private func makeVersion(gameURL: URL) -> GameVersion {
        GameVersion(
            id: "test",
            displayName: "Test",
            wowVersion: "2.4.3",
            gamePath: gameURL.path,
            executableName: "WoW.exe",
            supportsVanillaTweaks: false,
            supportsDLLLoading: false,
            usesRosettaPatching: true,
            usesDivxDecoderPatch: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
```
(Note: `wowVersion: "2.4.3"` keeps `libSiliconPatchSubdirectory` nil and `supportsDLLLoading: false` keeps libDllLdr/DivxDecoder.dll.bak out of scope — the tests isolate exactly the rosettax87 requirement being removed.)

- [ ] **Step 3: Run tests — confirm RED**
```bash
swift test --filter PatchingStatusCheckerTests
```
Expected: `testGamePatchDoesNotRequireGameFolderRosettax87` FAILS with `XCTAssertNotEqual failed: ("Missing rosettax87") is equal to ("Missing rosettax87")` (checker line 40 still requires `rosettax87/rosettax87`); `testGamePatchAppliedWithBundledResourceCopies` FAILS with `expected Applied, got: Missing rosettax87` (or is skipped if resources unreachable); `testGamePatchStillReportsMissingWinerosetta` PASSES.

- [ ] **Step 4: Remove rosettax87 from the required-files list**

In `Sources/WoWSiliconSwift/Services/PatchingStatusChecker.swift`, replace lines 37-42:
```swift
            var requiredFiles = [
                gamePath.appendingPathComponent("mods/winerosetta.dll"),
                gamePath.appendingPathComponent("d3d9.dll"),
                gamePath.appendingPathComponent("rosettax87/rosettax87"),
                gamePath.appendingPathComponent("rosettax87/libRuntimeRosettax87")
            ]
```
with:
```swift
            var requiredFiles = [
                gamePath.appendingPathComponent("mods/winerosetta.dll"),
                gamePath.appendingPathComponent("d3d9.dll")
            ]
```

- [ ] **Step 5: Remove rosettax87 from resourceExpectations**

Replace the array literal at lines 257-286 (`private static func resourceExpectations`):
```swift
        var expectations: [ResourceExpectation] = [
            ResourceExpectation(
                relativePath: "mods/winerosetta.dll",
                resourceName: "winerosetta",
                resourceExtension: "dll",
                resourceSubdirectory: "Patching/winerosetta",
                displayName: "winerosetta.dll"
            ),
            ResourceExpectation(
                relativePath: "d3d9.dll",
                resourceName: "d3d9",
                resourceExtension: "dll",
                resourceSubdirectory: "Patching/d9vk",
                displayName: "d3d9.dll"
            )
        ]
```
(The two `ResourceExpectation` entries for `rosettax87/rosettax87` and `rosettax87/libRuntimeRosettax87` are deleted; the `libDllLdr.dll` and `libSiliconPatch.dll` conditional appends at lines 288-310 stay untouched.)

- [ ] **Step 6: Delete evaluateCrossOverPatch entirely**

Delete lines 118-208 — the whole `static func evaluateCrossOverPatch(crossOverPath: String? = nil) -> PatchStatusDescriptor { ... }` including the blank line after it, so line 116's closing `}` of `evaluateGamePatch` is followed directly by the `// MARK: - Helpers` comment. This removes the file's only references to `PatchService.detectCrossOverVersion`, `PatchService.isSigned`, and the `Patching/winerosetta` ntdll resource (all deleted in Task 10).

- [ ] **Step 7: Run tests — confirm GREEN**
```bash
swift test --filter PatchingStatusCheckerTests
```
Expected: all 3 tests pass (or 2 pass + 1 skip if resources unreachable). Then confirm the whole package:
```bash
swift test
```
Expected: 0 failures.

- [ ] **Step 8: Commit**
```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && git add Sources/WoWSiliconSwift/Services/PatchingStatusChecker.swift Tests/WoWSiliconSwiftTests/PatchingStatusCheckerTests.swift && git commit -m "refactor: drop CrossOver and game-folder rosettax87 checks from PatchingStatusChecker

rosettax87 now ships inside the app bundle (v3 bundled runtime); the
checker no longer blocks launch on <game>/rosettax87/ contents, and
evaluateCrossOverPatch is deleted along with the CrossOver flow.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 10: PatchService: delete CrossOver patching, relocate DivxDecoder wine, stop game-folder rosettax87

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PatchService.swift` (error enum 5-35; delete `CrossOverVersion`+`detectCrossOverVersion` 38-71; refactor `applyGamePatch` 73-127; `patchDivxDecoder` 129-161; delete `resolveWineloaderPath` 177-182; comment `removeGamePatch` line 206; delete `applyCrossOverPatch`/`removeCrossOverPatch` 213-320; delete `removeSignature`/`isSigned`/`isSignedByCodeWeavers` 372-419)
- Delete: `Sources/WoWSiliconSwift/Resources/Patching/winerosetta/ntdll.so` (via `git rm`; no `Package.swift` change — the whole `Patching` dir is one `.copy` resource)
- Test: `Tests/WoWSiliconSwiftTests/PatchServiceGamePatchTests.swift` (new)

**Interfaces:**
- Consumes: `WineRuntime.shared.validatedWineBinaryURL() throws -> URL` (Task 4); `ProcessRunner.run(executablePath:arguments:environment:currentDirectory:timeout:)` (existing); `GameVersion` init (existing)
- Produces: `PatchService.stageGamePatchFiles(for: GameVersion) throws -> URL` (internal, test seam); `PatchService.applyGamePatch(for:)` / `removeGamePatch(for:)` unchanged signatures; KEEPS `PatchService.fileChecksum(at:)`, `PatchService.resourceURL(named:extension:subdirectory:)`, `PatchService.isSupportedGameClient(at:)` (WineRuntime + PatchingStatusChecker depend on them); `PatchServiceError` reduced to `.gamePathMissing/.invalidGamePath/.gameClientNotDetected/.resourceMissing/.fileOperationFailed`

- [ ] **Step 1: Verify Tasks 5-9 precondition — no external callers of the APIs being deleted**
```bash
grep -rn "applyCrossOverPatch\|removeCrossOverPatch\|detectCrossOverVersion\|CrossOverVersion\|removeSignature\|isSignedByCodeWeavers\|PatchService.isSigned\|crossOverNotFound\|unsupportedCrossOverVersion\|PatchServiceError.crossOverWineloaderMissing" /Users/sami.taaissat/Documents/Perso/WoWSilicon/Sources/ --include="*.swift" | grep -v "Services/PatchService.swift"
```
Expected output: empty. (As of v2.5.5 the callers were `MainDashboardViewModel.swift:848,850,870,872` — Task 8; `LaunchService.swift:141,284,336` — Task 5; `TroubleshootingService.swift:166` — Task 7. `VanillaTweaksService` has its own `VanillaTweaksError.crossOverWineloaderMissing` — that is a different enum handled in Task 6, not a blocker here.) If anything prints, STOP — an earlier task is incomplete.

- [ ] **Step 2: Write failing tests against the new stageGamePatchFiles seam**

`applyGamePatch` ends in the DivxDecoder rundll32 step, which spawns Wine — untestable in unit tests. The refactor splits the pure file-staging portion into an internal `stageGamePatchFiles(for:) -> URL` and tests that. Create `Tests/WoWSiliconSwiftTests/PatchServiceGamePatchTests.swift`:
```swift
import XCTest
@testable import WoWSiliconSwift

final class PatchServiceGamePatchTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testStageGamePatchFilesCopiesPayloadAndDeletesStaleRosettax87() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk") == nil,
            "Bundled patch resources not resolvable under swift test"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        // Stale v2 leftover that apply must delete.
        let staleRosettaURL = gameURL.appendingPathComponent("rosettax87", isDirectory: true)
        try FileManager.default.createDirectory(at: staleRosettaURL, withIntermediateDirectories: true)
        try Data([0x00]).write(to: staleRosettaURL.appendingPathComponent("rosettax87"))

        let stagedURL = try PatchService.stageGamePatchFiles(for: makeVersion(gameURL: gameURL))

        XCTAssertEqual(stagedURL.path, gameURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("mods/winerosetta.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("d3d9.dll").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleRosettaURL.path),
            "apply must delete the obsolete <game>/rosettax87/ directory and must not recreate it"
        )
        let dlls = try String(contentsOf: gameURL.appendingPathComponent("dlls.txt"), encoding: .utf8)
        XCTAssertTrue(dlls.contains("mods/winerosetta.dll"))
    }

    func testRemoveGamePatchDeletesRosettax87Leftovers() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let staleRosettaURL = gameURL.appendingPathComponent("rosettax87", isDirectory: true)
        try FileManager.default.createDirectory(at: staleRosettaURL, withIntermediateDirectories: true)
        try Data([0x00]).write(to: staleRosettaURL.appendingPathComponent("libRuntimeRosettax87"))

        try PatchService.removeGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRosettaURL.path))
    }

    private func makeVersion(gameURL: URL) -> GameVersion {
        GameVersion(
            id: "test",
            displayName: "Test",
            wowVersion: "2.4.3",
            gamePath: gameURL.path,
            executableName: "WoW.exe",
            supportsVanillaTweaks: false,
            supportsDLLLoading: false,
            usesRosettaPatching: true,
            usesDivxDecoderPatch: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
```
(`supportsDLLLoading: false` keeps the libDllLdr copy and the rundll32 gate out of the staging path; `wowVersion: "2.4.3"` keeps libSiliconPatch out. `removeGamePatch` never spawns Wine, so it is tested directly.)

- [ ] **Step 3: Run tests — confirm RED (compile failure)**
```bash
swift test --filter PatchServiceGamePatchTests
```
Expected: build FAILS with `error: type 'PatchService' has no member 'stageGamePatchFiles'` at `PatchServiceGamePatchTests.swift` — the seam does not exist yet.

- [ ] **Step 4: Refactor applyGamePatch into stageGamePatchFiles + Wine step; drop rosettax87 copying**

In `Sources/WoWSiliconSwift/Services/PatchService.swift`, replace the whole `applyGamePatch` (lines 73-127) with:
```swift
    static func applyGamePatch(for version: GameVersion) throws {
        let gameURL = try stageGamePatchFiles(for: version)

        if version.usesRosettaPatching && version.supportsDLLLoading {
            try patchDivxDecoder(gameURL: gameURL)
        }

        ensureGxResolution(in: gameURL)
    }

    /// Copies all patch payload files into the game folder and deletes the
    /// obsolete v2 `<game>/rosettax87/` directory (rosettax87 ships inside the
    /// app bundle since v3). Split from `applyGamePatch` so tests can exercise
    /// the file staging without invoking Wine (the DivxDecoder rundll32 step).
    static func stageGamePatchFiles(for version: GameVersion) throws -> URL {
        guard !version.gamePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatchServiceError.gamePathMissing
        }

        let gameURL = URL(fileURLWithPath: version.gamePath, isDirectory: true)
        try ensureDirectoryExists(gameURL, errorOnMissing: .invalidGamePath(version.gamePath))
        guard isSupportedGameClient(at: gameURL) else {
            throw PatchServiceError.gameClientNotDetected
        }

        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)

        try copyResource(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta", to: modsURL.appendingPathComponent("winerosetta.dll"))
        try copyResource(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk", to: gameURL.appendingPathComponent("d3d9.dll"))

        // Remove legacy exe-patching artifacts
        try removeIfExists(gameURL.appendingPathComponent("Wow_patched.exe"))
        try removeIfExists(modsURL.appendingPathComponent("libDllLdr.dll"))

        if version.usesRosettaPatching && version.supportsDLLLoading {
            try copyResource(named: "libDllLdr", extension: "dll", subdirectory: "Patching/winerosetta", to: gameURL.appendingPathComponent("libDllLdr.dll"))
        } else {
            try removeIfExists(gameURL.appendingPathComponent("libDllLdr.dll"))
        }

        if version.settings.enableLibSiliconPatch, let subdir = version.libSiliconPatchSubdirectory {
            try copyResource(named: "libSiliconPatch", extension: "dll", subdirectory: subdir, to: modsURL.appendingPathComponent("libSiliconPatch.dll"))
        } else {
            try removeIfExists(modsURL.appendingPathComponent("libSiliconPatch.dll"))
        }

        // Optional utility used by vanilla tweaks
        if version.supportsVanillaTweaks, let vanillaTweaksURL = resourceURL(named: "vanilla-tweaks", extension: "exe", subdirectory: "Patching/vanilla-tweaks") {
            let destination = gameURL.appendingPathComponent("vanilla-tweaks.exe")
            try copyItem(from: vanillaTweaksURL, to: destination)
        }

        // v3: rosettax87 lives inside the app bundle; delete the obsolete v2 copy.
        try removeIfExists(gameURL.appendingPathComponent("rosettax87", isDirectory: true))

        try updateDllsTxt(in: gameURL, enableLibSiliconPatch: version.settings.enableLibSiliconPatch && version.libSiliconPatchSubdirectory != nil)

        return gameURL
    }
```
This deletes the old lines 112-118 (create `rosettax87/` + copy both binaries) — the only user of `copyResource`'s `makeExecutable:` parameter; the parameter itself stays (harmless default).

- [ ] **Step 5: patchDivxDecoder resolves wine via WineRuntime; delete resolveWineloaderPath**

Replace `patchDivxDecoder` (old lines 129-161) with:
```swift
    private static func patchDivxDecoder(gameURL: URL) throws {
        let wineBinaryURL = try WineRuntime.shared.validatedWineBinaryURL()

        var env = ProcessInfo.processInfo.environment
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree=d;mshtml=d"
        env["WINEDEBUG"] = "-all"

        let patches: [(entry: String, file: String)] = [
            ("PatchDivxDecoder", "DivxDecoder.dll"),
            ("PatchDivxTac",     "DivxTac.dll"),
        ]

        for patch in patches {
            guard FileManager.default.fileExists(atPath: gameURL.appendingPathComponent(patch.file).path) else {
                continue  // this client doesn't have this DLL — skip
            }

            let result = try ProcessRunner.run(
                executablePath: wineBinaryURL.path,
                arguments: ["rundll32", "libDllLdr.dll,\(patch.entry)", gameURL.path],
                environment: env,
                currentDirectory: gameURL,
                timeout: 120
            )

            if result.exitCode != 0 {
                throw PatchServiceError.fileOperationFailed("Failed to run \(patch.entry): \(result.combinedOutput)")
            }
        }
    }
```
The `version:` parameter is dropped (it only existed to resolve the CrossOver path). Also delete `private static func resolveWineloaderPath(for:)` entirely (old lines 177-182).

- [ ] **Step 6: Mark the removeGamePatch rosettax87 cleanup as intentional**

In `removeGamePatch`, replace the line
```swift
        try removeIfExists(gameURL.appendingPathComponent("rosettax87"))
```
with:
```swift
        // Obsolete v2 payload — rosettax87 ships inside the app bundle since v3.
        try removeIfExists(gameURL.appendingPathComponent("rosettax87"))
```

- [ ] **Step 7: Delete all CrossOver code from PatchService**

Delete, in one pass:
- `enum CrossOverVersion { ... }` and `static func detectCrossOverVersion(at:) -> CrossOverVersion` (old lines 38-71)
- `static func applyCrossOverPatch(crossOverPath:)` and `static func removeCrossOverPatch(crossOverPath:)` (old lines 213-320)
- `private static func removeSignature(at:)`, `static func isSigned(at:) -> Bool`, `static func isSignedByCodeWeavers(at:) -> Bool` (old lines 372-419)

Then shrink `PatchServiceError` (old lines 5-35) to exactly:
```swift
enum PatchServiceError: LocalizedError {
    case gamePathMissing
    case invalidGamePath(String)
    case gameClientNotDetected
    case resourceMissing(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .gamePathMissing:
            return "Game path is not set. Please choose your game directory first."
        case .invalidGamePath(let path):
            return "The selected game path is invalid or inaccessible: \(path)"
        case .gameClientNotDetected:
            return "This folder does not look like a World of Warcraft client. Select the folder containing DivxDecoder.dll."
        case .resourceMissing(let name):
            return "Bundled resource \(name) is missing from the application package."
        case .fileOperationFailed(let reason):
            return reason
        }
    }
}
```
KEEP untouched: `isSupportedGameClient`, `fileChecksum`, `resourceURL` + the private `CandidateBundles` enum (WineRuntime resolves the bundled rosettax87 loader through `PatchService.resourceURL`, and PatchingStatusChecker uses it for checksums), plus all remaining private helpers (`ensureDirectoryExists`, `copyResource`, `copyItem`, `removeIfExists`, `revertDivxDecoder`, `ensureGxResolution`, `updateDllsTxt`, `removeDllEntries`).

- [ ] **Step 8: Remove the vendored patched ntdll.so**
```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && git rm Sources/WoWSiliconSwift/Resources/Patching/winerosetta/ntdll.so
```
(No `Package.swift` edit needed — resources are declared as `.copy("WoWSiliconSwift/Resources/Patching")` for the whole directory. `Patching/winerosetta/` still ships `winerosetta.dll` and `libDllLdr.dll`.)

- [ ] **Step 9: Run tests — confirm GREEN**
```bash
swift test --filter PatchServiceGamePatchTests
```
Expected: both tests pass (or `testStageGamePatchFilesCopiesPayloadAndDeletesStaleRosettax87` skips if resources unreachable — `testRemoveGamePatchDeletesRosettax87Leftovers` needs no resources and must pass). Then:
```bash
swift test
```
Expected: full suite green, package compiles with zero references to CrossOver in PatchService:
```bash
grep -n "CrossOver\|crossOver" /Users/sami.taaissat/Documents/Perso/WoWSilicon/Sources/WoWSiliconSwift/Services/PatchService.swift
```
Expected output: empty.

- [ ] **Step 10: Commit**
```bash
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && git add Sources/WoWSiliconSwift/Services/PatchService.swift Tests/WoWSiliconSwiftTests/PatchServiceGamePatchTests.swift && git commit -m "refactor: delete CrossOver patching from PatchService, use bundled Wine for DivxDecoder

- applyGamePatch split into stageGamePatchFiles (testable file staging)
  plus the Wine-invoking DivxDecoder step
- game patch no longer copies rosettax87 into the game folder; apply and
  remove both delete the obsolete v2 <game>/rosettax87/ directory
- patchDivxDecoder resolves wine via WineRuntime.validatedWineBinaryURL
- applyCrossOverPatch/removeCrossOverPatch/detectCrossOverVersion,
  CrossOverVersion, signature helpers, CrossOver error cases and the
  vendored patched ntdll.so are gone

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
(The `git rm` from Step 8 is already staged; this commit includes the ntdll.so deletion.)

---

### Task 11: Makefile runtime fetch + bundle integration

**Files:**
- Modify: `/Users/sami.taaissat/Documents/Perso/WoWSilicon/Makefile` (vars after line 25; `.PHONY` line 27; `bundle` deps line 47; insert runtime copy between lines 66–67; new `fetch-runtime` target after `bundle`)
- Modify: `/Users/sami.taaissat/Documents/Perso/WoWSilicon/.github/workflows/release.yml` (insert cache step before the "Build DMG and appcast" step, currently line 92)

**Interfaces:**
- Consumes: GitHub release `runtime-v1` with assets `wowsilicon-wine-1-osx64.tar.xz` and `wowsilicon-wine-1-osx64.tar.xz.sha256` (published by Task 3; tarball contains top-level `wine/{bin,lib,share,VERSION}`); existing Makefile vars `BUILD_DIR`, `APP_BUNDLE`; existing `bundle` target (stages Resources, then codesigns with `--deep`).
- Produces: Makefile vars `RUNTIME_VERSION`, `RUNTIME_ASSET`, `RUNTIME_URL`, `RUNTIME_SHA256`, `RUNTIME_CACHE`; target `fetch-runtime`; app bundle containing `Contents/SharedSupport/wine/bin/wine` — the exact layout `WineRuntime` (Task 4) resolves via `runtimeRootURL = <bundleURL>/Contents/SharedSupport/wine` and `wineBinaryURL = runtimeRootURL/bin/wine`, with `runtimeVersion` read from `runtimeRootURL/VERSION`.

- [ ] **Step 1: Preflight — assert the runtime-v1 release asset exists (Task 3 output)**
```bash
curl -fsI "https://github.com/samitaaissat/WoWSilicon/releases/download/runtime-v1/wowsilicon-wine-1-osx64.tar.xz" | head -n 1
```
Expected: `HTTP/2 302` (GitHub redirects release assets to object storage; `curl -f` exits non-zero on 404). If this fails, STOP — Task 3 has not published `runtime-v1`; do not proceed.
Note on `<owner>/<repo>`: determined by running `git remote get-url origin` in the repo root, which prints `https://github.com/samitaaissat/WoWSilicon.git` → hardcoded as `samitaaissat/WoWSilicon` (the `?=` on `RUNTIME_URL` keeps it overridable).

- [ ] **Step 2: Fetch the published SHA-256 for the tarball**
```bash
curl -fsSL "https://github.com/samitaaissat/WoWSilicon/releases/download/runtime-v1/wowsilicon-wine-1-osx64.tar.xz.sha256" | awk '{print $1}'
```
Expected: a single 64-character lowercase hex string. Copy it — it is pasted into `RUNTIME_SHA256` in Step 3.

- [ ] **Step 3: Add runtime vars to the Makefile**
In `/Users/sami.taaissat/Documents/Perso/WoWSilicon/Makefile`, insert after line 25 (`RESOURCE_BUNDLE := ...`), before the `.PHONY` line:
```make
# ---------------------------------------------------------------------------
# Bundled Wine runtime (built by .github/workflows/runtime.yml, published as
# GitHub release runtime-v$(RUNTIME_VERSION); tarball layout: wine/{bin,lib,share,VERSION}).
# The cache lives under $(BUILD_DIR), so `make clean` removes it and the next
# `make bundle` (or `make run`) re-downloads the ~150 MB tarball — accepted;
# CI restores $(RUNTIME_CACHE) via actions/cache keyed on runtime-v$(RUNTIME_VERSION)
# (bump the key in .github/workflows/release.yml when bumping RUNTIME_VERSION).
RUNTIME_VERSION ?= 1
RUNTIME_ASSET := wowsilicon-wine-$(RUNTIME_VERSION)-osx64.tar.xz
RUNTIME_URL ?= https://github.com/samitaaissat/WoWSilicon/releases/download/runtime-v$(RUNTIME_VERSION)/$(RUNTIME_ASSET)
RUNTIME_SHA256 ?= PASTE_SHA256_FROM_STEP_2_HERE
RUNTIME_CACHE := $(BUILD_DIR)/runtime-cache
```
Then replace `PASTE_SHA256_FROM_STEP_2_HERE` with the hex string from Step 2, and confirm no placeholder remains:
```bash
grep -n "PASTE_SHA256" Makefile; test $? -eq 1 && echo "placeholder replaced"
grep -n "^RUNTIME_SHA256" Makefile | grep -E '[0-9a-f]{64}' && echo "sha wired"
```

- [ ] **Step 4: Add the fetch-runtime target and mark it .PHONY**
Change line 27 from:
```make
.PHONY: all build debug run bundle dmg appcast clean app_icon
```
to:
```make
.PHONY: all build debug run bundle fetch-runtime dmg appcast clean app_icon
```
Then add this target after the `bundle` target (recipe lines MUST start with a literal tab):
```make
fetch-runtime:
	@if [ -x "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/bin/wine" ] \
		&& [ "$$(cat "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/.sha256" 2>/dev/null)" = "$(RUNTIME_SHA256)" ]; then \
		echo "Wine runtime v$(RUNTIME_VERSION) already cached at $(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
	else \
		echo "Fetching Wine runtime v$(RUNTIME_VERSION) from $(RUNTIME_URL)..."; \
		rm -rf "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
		mkdir -p "$(RUNTIME_CACHE)"; \
		curl -fL --retry 3 -o "$(RUNTIME_CACHE)/$(RUNTIME_ASSET)" "$(RUNTIME_URL)"; \
		echo "$(RUNTIME_SHA256)  $(RUNTIME_CACHE)/$(RUNTIME_ASSET)" | shasum -a 256 -c -; \
		mkdir -p "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
		tar -xJf "$(RUNTIME_CACHE)/$(RUNTIME_ASSET)" -C "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
		test -x "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/bin/wine"; \
		printf '%s' "$(RUNTIME_SHA256)" > "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/.sha256"; \
		echo "Wine runtime v$(RUNTIME_VERSION) extracted to $(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
	fi
```
(The `.sha256` marker file is the "recorded checksum": it is written only after a verified download + successful extraction, so the skip branch is taken iff the cached tree came from a tarball matching the current `RUNTIME_SHA256`. Extraction happens only after `shasum -c` passes, so a failed check never leaves a poisoned extracted tree.)

- [ ] **Step 5: Failing check first — wrong checksum must abort fetch-runtime**
```bash
make fetch-runtime RUNTIME_SHA256=0000000000000000000000000000000000000000000000000000000000000000
```
Expected: the tarball downloads, then:
```
.build/runtime-cache/wowsilicon-wine-1-osx64.tar.xz: FAILED
shasum: WARNING: 1 computed checksum did NOT match
make: *** [fetch-runtime] Error 1
```
and `.build/runtime-cache/1/` does not exist:
```bash
test ! -d .build/runtime-cache/1 && echo "no extracted tree on failure — OK"
```

- [ ] **Step 6: Green — correct checksum fetches and extracts**
```bash
make fetch-runtime
ls .build/runtime-cache/1/wine
```
Expected: checksum line ends `: OK`, then "Wine runtime v1 extracted to ...", and `ls` shows `VERSION bin lib share`. Then verify the skip path is idempotent (re-run must NOT download):
```bash
make fetch-runtime
```
Expected single line: `Wine runtime v1 already cached at .build/runtime-cache/1` (returns in <1s, no curl output).

- [ ] **Step 7: Wire fetch-runtime into bundle and copy the runtime before codesign**
Change line 47 from:
```make
bundle: build
```
to:
```make
bundle: build fetch-runtime
```
Then insert between the icon copy (line 66) and the codesign block (line 67) — i.e. after `@cp "$(APP_ICON)" "$(APP_BUNDLE)/Contents/Resources/turtle.icns"` and before `@if [ -n "$(CODESIGN_IDENTITY)" ]; then \` — so the ad-hoc `codesign --deep` seal covers the runtime:
```make
	@echo "Bundling Wine runtime v$(RUNTIME_VERSION)..."
	@mkdir -p "$(APP_BUNDLE)/Contents/SharedSupport"
	@cp -R "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine" "$(APP_BUNDLE)/Contents/SharedSupport/wine"
```
(No `clean` change needed: line 118 `rm -rf "$(BUILD_DIR)"` nukes the cache along with everything else; the re-download after `make clean` is documented in the Step 3 comment block.)

- [ ] **Step 8: Verify the assembled bundle**
```bash
make bundle
ls -l .build/WoWSilicon.app/Contents/SharedSupport/wine/bin/wine
test -x .build/WoWSilicon.app/Contents/SharedSupport/wine/bin/wine && echo "wine executable — OK"
file .build/WoWSilicon.app/Contents/SharedSupport/wine/bin/wine
cat .build/WoWSilicon.app/Contents/SharedSupport/wine/VERSION
codesign --verify --deep --strict .build/WoWSilicon.app && echo "codesign seal OK"
```
Expected: `file` reports a `Mach-O 64-bit executable x86_64`; `VERSION` prints the runtime pipeline's stamp (this is what `WineRuntime.runtimeVersion` reads); codesign verification passes.

- [ ] **Step 9: Add the runtime cache step to release.yml**
In `/Users/sami.taaissat/Documents/Perso/WoWSilicon/.github/workflows/release.yml`, insert immediately before the `- name: Build DMG and appcast` step (currently line 92):
```yaml
      - name: Cache bundled Wine runtime
        uses: actions/cache@v4
        with:
          path: .build/runtime-cache
          # Keep in sync with RUNTIME_VERSION in the Makefile.
          key: runtime-v1
```
Sanity-check the workflow still parses:
```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); puts "release.yml parses"'
```

- [ ] **Step 10: Confirm the package and tests are untouched and green**
```bash
swift test
```
Expected: all tests pass (this task changes no Swift sources; this guards the "every task leaves swift test green" invariant).

- [ ] **Step 11: Commit**
```bash
git add Makefile .github/workflows/release.yml
git commit -m "build: fetch verified Wine runtime and bundle it into Contents/SharedSupport

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Docs, release notes, agent guidance

**Files:**
- Modify: `/Users/sami.taaissat/Documents/Perso/WoWSilicon/README.md` (lines 27, 43, 52–58, 74; insert new section after line 74)
- Create: `/Users/sami.taaissat/Documents/Perso/WoWSilicon/docs/releases/3.0.0.md`
- Modify: `/Users/sami.taaissat/Documents/Perso/WoWSilicon/AGENTS.md` (lines 7, 17, 20, 24, 26, 70–72, 77)
- Modify: `/Users/sami.taaissat/Documents/Perso/WoWSilicon/CLAUDE.md` (regular file kept byte-identical to `AGENTS.md` — it is NOT a symlink; re-copy after editing `AGENTS.md`)
- Modify: `/Users/sami.taaissat/Documents/Perso/WoWSilicon/docs/releasing.md` (append new `## Runtime Releases` section after line 76)

**Interfaces:**
- Consumes: `Makefile` pins `RUNTIME_VERSION` / `RUNTIME_SHA256` / `RUNTIME_URL` and target `fetch-runtime` (Task 11); `.github/workflows/runtime.yml` + `tools/runtime/` build scripts (Task 2); GitHub release tag `runtime-v1` with assets `wowsilicon-wine-1-osx64.tar.xz` and `wowsilicon-wine-1-osx64.tar.xz.sha256`; bundle destination `$(APP_BUNDLE)/Contents/SharedSupport/wine`; `func restoreCrossOverModifications(atCrossOverPath path: String) -> CrossOverRestoreResult` (Task 7, described in release notes as the Troubleshooting restore button).
- Produces: `docs/releases/3.0.0.md`, which `.github/workflows/release.yml` picks up at `v3.0.0` tag time (GitHub Release body + Sparkle appcast notes). No code interfaces.

**Note:** the version bump itself (`tools/release/set_version.sh 3.0.0`, build number 30000) is deliberately NOT part of this task — it happens at release tagging time per `docs/releasing.md` ("Release Flow"). This task only lands the documentation and release notes.

- [ ] **Step 1: Update the README project-description line (README.md:27)**
```diff
-It is built around CrossOver, RosettaX87, DX9 translation, and runtime patching so clients from the 2006-2010 era can run more efficiently on modern macOS hardware.
+It bundles a pre-patched Wine runtime, RosettaX87, DX9 translation, and runtime patching so clients from the 2006-2010 era can run more efficiently on modern macOS hardware.
```

- [ ] **Step 2: Update the Features bullet (README.md:43)**
```diff
 - Version profiles for separate client folders
-- CrossOver patching for the RosettaX87 launch path
+- Bundled, pre-patched Wine runtime (built from WineAndAqua/wine, wine-11.0-macos)
 - Game-folder patching for required runtime files
```

- [ ] **Step 3: Replace the Requirements section (README.md:52-58)**
```diff
 ## Requirements

 - Apple Silicon Mac
 - macOS 15 or newer
-- CrossOver 26 installed and opened at least once
 - A legally acquired local World of Warcraft client folder
-- Permission to modify the selected game folder and CrossOver app bundle
+- Permission to modify the selected game folder
+
+On first launch, macOS shows a one-time prompt asking to allow WoWSilicon to attach to other processes for debugging. The bundled RosettaX87 loader needs this authorization to run the 32-bit client; approve it once and macOS will not ask again.
```

- [ ] **Step 4: Update the Installation closing sentence (README.md:74)**
```diff
-Then open WoWSilicon, select the game folder and CrossOver app path, apply the required patches, and launch the selected client profile.
+Then open WoWSilicon, select the game folder, apply the game patch, and launch the selected client profile.
```

- [ ] **Step 5: Insert a new "Bundled components & licenses" section after the Installation section (README.md, between line 74 and the `## Development` heading)**
```markdown
## Bundled components & licenses

WoWSilicon.app ships the following third-party components:

- **Wine** (LGPL-2.1-or-later) — the bundled, pre-patched runtime is built from
  [WineAndAqua/wine](https://github.com/WineAndAqua/wine) (branch `wine-11.0-macos`)
  at the commit pinned in [`.github/workflows/runtime.yml`](.github/workflows/runtime.yml).
  The app bundles the `runtime-v*` release selected by `RUNTIME_VERSION` in the
  [`Makefile`](Makefile); Wine's LICENSE files ship inside
  `WoWSilicon.app/Contents/SharedSupport/wine/`.
- **rosettax87_jit** (MIT) — the RosettaX87 loader, by
  [Lifeisawful](https://github.com/Lifeisawful/rosettax87_jit).
- **winerosetta** — game-folder DLL payload, from the
  [Gcenx mirror](https://github.com/Gcenx/winerosetta).
- **DXVK / d9vk** (zlib) — the native `d3d9.dll` DirectX 9 translation layer.
- **vanilla-tweaks** (MIT) — client tweaking tool used by the vanilla-tweaks patch step.
```

- [ ] **Step 6: Create `docs/releases/3.0.0.md` (house format follows `docs/releases/2.5.0.md` — H1 tagline for major releases, `##` component sections, xattr footer, "Supported versions" line)**
````markdown
# WoWSilicon 3.0.0 is here. No CrossOver required.

WoWSilicon now ships its own Wine. Download one app, select your game folder, apply the game patch, and play.

## Bundled Wine runtime

- WoWSilicon.app now contains a pre-patched Wine runtime built from the public `WineAndAqua/wine` tree (`wine-11.0-macos`) — no CrossOver purchase, install, or patching step.
- The CrossOver path selection and the CrossOver patch step are gone from the dashboard.
- Your existing Wine prefix (`~/.wine`) keeps working: registry settings, the VC++ runtime, Retina mode, and Option-as-Alt all survive the upgrade.
- Already-patched game folders stay valid; the obsolete `rosettax87` folder inside the game directory is cleaned up automatically.

## rosettax87_JIT

- Updated to the latest build, with macOS 27 support.
- Now lives inside the app bundle instead of the game folder, so runtime updates can no longer break the Play button.
- On first launch, macOS asks once to authorize debugging. The loader needs this to run the 32-bit client; approve it once and you will not be asked again.

## CrossOver

- Going forward, WoWSilicon never touches a CrossOver install.
- If a 2.x version patched your CrossOver, the new "Restore CrossOver modifications" button in Troubleshooting reverts those changes.

## Download size

- The DMG is now around 170 MB because the Wine runtime ships inside the app.

As always, drag it into your Applications directory and run:

```sh
xattr -cr /Applications/WoWSilicon.app
```

Supported versions: macOS 15, macOS 26, macOS 27
````

- [ ] **Step 7: Update the AGENTS.md project overview (AGENTS.md:7)**
```diff
-WoWSilicon is a native macOS launcher for older World of Warcraft clients (Vanilla 1.12.1, The Burning Crusade 2.4.3, Wrath of the Lich King 3.3.5a) on Apple Silicon Macs. It orchestrates CrossOver, RosettaX87, DX9 translation (d9vk), and runtime patching so 2006–2010 era clients run efficiently on modern macOS. It also ships an addon manager (Git URL installs, bulk import/export), a mod manager for DLL-style mods, a realmlist editor, graphics options, and Sparkle-based auto-updates.
+WoWSilicon is a native macOS launcher for older World of Warcraft clients (Vanilla 1.12.1, The Burning Crusade 2.4.3, Wrath of the Lich King 3.3.5a) on Apple Silicon Macs. It orchestrates a bundled, pre-patched Wine runtime (built from `WineAndAqua/wine`, branch `wine-11.0-macos`, shipped inside the app at `Contents/SharedSupport/wine/`), RosettaX87, DX9 translation (d9vk), and runtime patching so 2006–2010 era clients run efficiently on modern macOS — no CrossOver install required. It also ships an addon manager (Git URL installs, bulk import/export), a mod manager for DLL-style mods, a realmlist editor, graphics options, and Sparkle-based auto-updates.
```

- [ ] **Step 8: Update the AGENTS.md repository layout (AGENTS.md:17, 20, 24, and insert two bullets after line 26)**
```diff
-  - `Services/` — the bulk of the logic: `LaunchService` (launching via CrossOver/wine), `PatchService`, `PatchingStatusChecker`, `ConfigService` (writes `WTF/Config.wtf`), `AddonService`, `ModService`, `RealmlistService`, `RetinaModeService`, `OptionAsAltService`, `VanillaTweaksService`, `DXVKConfigService`, `UpdaterService` (Sparkle), `TelemetryService`, `ProcessRunner`, etc.
+  - `Services/` — the bulk of the logic: `WineRuntime` (single authority for bundled Wine runtime paths, version, and validation), `LaunchService` (launching via the bundled Wine runtime), `PatchService`, `PatchingStatusChecker`, `ConfigService` (writes `WTF/Config.wtf`), `AddonService`, `ModService`, `RealmlistService`, `RetinaModeService`, `OptionAsAltService`, `VanillaTweaksService`, `DXVKConfigService`, `UpdaterService` (Sparkle), `TelemetryService`, `ProcessRunner`, etc.
```
```diff
-  - `Resources/` — binary patching payloads bundled into the app (`Patching/d9vk`, `Patching/libSiliconPatch/{vanilla,wotlk}`, `Patching/rosettax87`, `Patching/winerosetta`, `Patching/vanilla-tweaks`) and the app icon source PNG. Treat these as vendored third-party binaries; do not regenerate them casually.
+  - `Resources/` — binary patching payloads bundled into the app (`Patching/d9vk`, `Patching/libSiliconPatch/{vanilla,wotlk}`, `Patching/rosettax87`, `Patching/winerosetta`, `Patching/vanilla-tweaks`) and the app icon source PNG. Treat these as vendored third-party binaries; do not regenerate them casually. CrossOver patching was removed in 3.0.0: `Patching/winerosetta` now holds only the game-folder DLLs (`winerosetta.dll`, `libDllLdr.dll`) — its former `ntdll.so` payload is gone because the equivalent patches are built into the bundled Wine runtime.
```
```diff
-- `Makefile` — build, bundle, DMG, appcast, and icon-generation targets (see below).
+- `Makefile` — build, bundle, DMG, appcast, runtime-fetch, and icon-generation targets (see below). Pins the bundled Wine runtime via `RUNTIME_VERSION`/`RUNTIME_SHA256`/`RUNTIME_URL`; `fetch-runtime` downloads and verifies it, and `bundle` copies it into `$(APP_BUNDLE)/Contents/SharedSupport/wine` before codesigning.
```
```diff
 - `.github/workflows/release.yml` — tag-triggered (`v*.*.*`) release pipeline.
+- `.github/workflows/runtime.yml` — tag-triggered (`runtime-v*`) pipeline that builds the pre-patched Wine runtime from the pinned `WineAndAqua/wine` commit and publishes `wowsilicon-wine-<n>-osx64.tar.xz` (+ `.sha256`) as a GitHub release.
+- `tools/runtime/` — scripts used by the runtime workflow to build and package the bundled Wine runtime.
 - `tools/release/` — version bump and local Sparkle test scripts.
```

- [ ] **Step 9: Update AGENTS.md "Release and deployment" (insert bullet after AGENTS.md:71, before the "Full details" line)**
```diff
 - Versioning: semantic display version plus numeric build number (`2.5.10` → `20510`), computed by `tools/release/version_to_build_number.sh`. CI secrets: `SPARKLE_PRIVATE_KEY` (EdDSA private key value only) and `PAGES_REPO_TOKEN`.
+- Runtime releases are decoupled from app releases: tag `runtime-v<n>` to run `.github/workflows/runtime.yml` and publish `wowsilicon-wine-<n>-osx64.tar.xz` + `.sha256`. The app selects which runtime it bundles via the `Makefile` pins (`RUNTIME_VERSION`, `RUNTIME_SHA256`, `RUNTIME_URL`); `make fetch-runtime` verifies the checksum before `make bundle` embeds the runtime. Bump all three pins together in one commit (see `docs/releasing.md`, "Runtime Releases").
 - Full details: `docs/releasing.md`.
```

- [ ] **Step 10: Update AGENTS.md "Security considerations" (AGENTS.md:77) — app no longer modifies the CrossOver bundle**
```diff
-- The app modifies user-selected directories outside the repo (the WoW game folder and the CrossOver app bundle) and shells out to processes (`ProcessRunner`, AppleScript terminal launches). Be careful with path handling, quoting, and command construction when touching `LaunchService`, `PatchService`, or `ProcessRunner` — user input (game paths, Git URLs, env variables) flows into these.
+- The app modifies user-selected directories outside the repo (the WoW game folder) and shells out to processes (`ProcessRunner`, AppleScript terminal launches). It no longer modifies the CrossOver bundle or any other application's bundle. Be careful with path handling, quoting, and command construction when touching `LaunchService`, `PatchService`, or `ProcessRunner` — user input (game paths, Git URLs, env variables) flows into these.
```

- [ ] **Step 11: Re-sync CLAUDE.md with AGENTS.md (it is a regular-file copy, not a symlink) and verify they are identical**
```sh
cp /Users/sami.taaissat/Documents/Perso/WoWSilicon/AGENTS.md /Users/sami.taaissat/Documents/Perso/WoWSilicon/CLAUDE.md
diff /Users/sami.taaissat/Documents/Perso/WoWSilicon/AGENTS.md /Users/sami.taaissat/Documents/Perso/WoWSilicon/CLAUDE.md && echo "IN SYNC"
```
Expected output: `IN SYNC` (no diff lines).

- [ ] **Step 12: Append a "Runtime Releases" section to `docs/releasing.md` (after the current last line, 76)**
```markdown
## Runtime Releases

The bundled Wine runtime is released separately from the app, from
`runtime-v<n>` tags (for example `runtime-v1`). Pushing such a tag runs
`.github/workflows/runtime.yml`, which builds Wine from the pinned
`WineAndAqua/wine` commit and attaches two assets to the `runtime-v<n>`
GitHub release:

- `wowsilicon-wine-<n>-osx64.tar.xz` (contains a top-level `wine/{bin,lib,share,VERSION}`)
- `wowsilicon-wine-<n>-osx64.tar.xz.sha256`

Cut a new runtime release (`runtime-v<n+1>`) only when the runtime itself
changes: a Wine source bump (new pinned SHA in the workflow), configure-flag
or dependency changes, or packaging fixes. App-only changes never require a
new runtime release.

The app pins the runtime it bundles in the `Makefile`:

- `RUNTIME_VERSION` — the runtime release number (`1` for `runtime-v1`)
- `RUNTIME_SHA256` — the expected checksum of the tarball (from the `.sha256` asset)
- `RUNTIME_URL` — the GitHub release asset URL

`make fetch-runtime` downloads the tarball to `.build/runtime-cache/` (skipped
when cached with a matching checksum), verifies `RUNTIME_SHA256`, and extracts
it; `make bundle` then copies the runtime into
`WoWSilicon.app/Contents/SharedSupport/wine` before codesigning. To move the
app to a new runtime, update all three pins in the same commit and rebuild.
```

- [ ] **Step 13: Sanity-check links and stale references (markdownlint-style: every relative path referenced by the edited docs must exist)**
```sh
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && ls Makefile .github/workflows/runtime.yml .github/workflows/release.yml docs/releasing.md docs/releases/3.0.0.md docs/assets/launcher-preview.png Sources/WoWSiliconSwift/Resources/Icons/turtlesilicon_icon.png tools/runtime tools/release/set_version.sh && grep -n "CrossOver" README.md docs/releasing.md; grep -c "CrossOver" AGENTS.md CLAUDE.md docs/releases/3.0.0.md
```
Expected: `ls` lists every path with no "No such file" error; the first `grep` prints **nothing** for README.md and docs/releasing.md (zero CrossOver references remain there); the second grep shows identical small counts for AGENTS.md and CLAUDE.md (only the intentional "removed in 3.0.0" / "no longer modifies" / restore-button mentions) and the intentional mentions in 3.0.0.md.

- [ ] **Step 14: Confirm the package still compiles and tests stay green (docs-only change, but the task gate applies)**
```sh
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && swift test
```
Expected: `Test Suite 'All tests' passed`.

- [ ] **Step 15: Commit**
```sh
cd /Users/sami.taaissat/Documents/Perso/WoWSilicon && git add README.md AGENTS.md CLAUDE.md docs/releasing.md docs/releases/3.0.0.md && git commit -m "docs: update README, agent guidance, and releasing docs for bundled Wine runtime; add 3.0.0 release notes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---
