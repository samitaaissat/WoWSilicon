#!/bin/bash
# Builds the WoWSilicon d9mt payload tarball from pinned upstream sources:
#   - d9mt  @ pinned commit below (samitaaissat/d9mt, our fork of
#     neo773/d9mt: upstream 237e2935 + the depth-bias fix (projected
#     textures) + pass-1 bind-path perf + pass-2 fused pass transitions,
#     push-block upload cache, and the d9vk-parity adapter identity, +
#     pass-3 WWDC21-10148 redundant-binding elision (viewports, vertex
#     buffers) kept; the pass-3 pixelFormatView narrowing was REVERTED
#     (payload v6) after a live ground-decal clipping regression report,
#     + pass-3 W1 FF hot/cold constant split (VS WORLD/VIEW transforms
#     move onto the push-constant path, PROJECTION/TEXTUREn/lighting
#     stay in the cold FF UBO; xform submit_avg_ms -48%) and W2 part-mode
#     fast paths (LockBuffer direct-map skip, PrepareDraw texture-mask
#     fast path) — perf/pass-3 branch, FINAL commit 5f7ae4d2 —
#     + the BT.2446-A/ICtCp HDR present pipeline ported from mtld3d
#     (fp16 extended-linear CAMetalLayer, curve peak following live EDR
#     headroom; OFF by default, D9MT_HDR=1 to enable) and, from the same
#     pass, a MEASURED-NEUTRAL pass-descriptor cache that was reverted
#     rather than shipped — see the fork's docs/PERF-ROADMAP.md)
#   - DXMT winemetal @ v0.80 (3Shain/dxmt, last MIT-licensed release)
# Output: dist/d9mt-<N>.tar.gz + .sha256, layout documented in the repo plan:
#   d9mt/d3d9.dll                              (d9mt i686 driver, build/d3d9fe.dll renamed)
#   d9mt/winemetal/{i386-windows,x86_64-windows}/winemetal.dll
#   d9mt/winemetal/x86_64-unix/winemetal.so
#   d9mt/d9mtmetal/{i386-windows,x86_64-windows}/d9mtmetal.dll
#   d9mt/d9mtmetal/x86_64-unix/d9mtmetal.so
#   d9mt/LICENSES/...
#
# One-time prerequisites: brew install mingw-w64 glslang (plus Xcode for
# metal/clang, python3, sqlite3).
set -euo pipefail

D9MT_REPO=https://github.com/samitaaissat/d9mt
D9MT_COMMIT=203baae2ee471ef4f86df1207fa07b82394f8700
DXMT_TAG=v0.80
# NOTE: v8 (the HDR pipeline) is NOT published on the runtime-v1 release, so the
# Makefile's D9MT_VERSION pin deliberately stays at 7. Bumping this default
# rather than leaving it at 7 is intentional: with the new D9MT_COMMIT above, a
# run defaulting to 7 would produce a d9mt-7.tar.gz whose contents differ from
# the published d9mt-7, which is worse than a version that simply is not up yet.
PAYLOAD_VERSION="${PAYLOAD_VERSION:-8}"

cd "$(dirname "$0")"
WORK="$PWD/work"
DIST="$PWD/dist"
STAGE="$WORK/stage"
rm -rf "$WORK"
mkdir -p "$WORK" "$DIST" "$STAGE/d9mt"/{winemetal,d9mtmetal}/{i386-windows,x86_64-windows,x86_64-unix} "$STAGE/d9mt/LICENSES"

# --- prereqs ---
for tool in i686-w64-mingw32-g++ i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc \
            i686-w64-mingw32-dlltool x86_64-w64-mingw32-dlltool i686-w64-mingw32-objdump \
            clang glslang python3 curl git tar shasum file dd; do
  command -v "$tool" >/dev/null || { echo "MISSING prerequisite: $tool (brew install mingw-w64 glslang)"; exit 1; }
done

# --- winemetal from DXMT release tarball ---
curl -fL --retry 3 -o "$WORK/dxmt.tar.gz" \
  "https://github.com/3Shain/dxmt/releases/download/$DXMT_TAG/dxmt-$DXMT_TAG-builtin.tar.gz"
tar -xzf "$WORK/dxmt.tar.gz" -C "$WORK"
cp "$WORK/$DXMT_TAG/i386-windows/winemetal.dll"    "$STAGE/d9mt/winemetal/i386-windows/"
cp "$WORK/$DXMT_TAG/x86_64-windows/winemetal.dll"  "$STAGE/d9mt/winemetal/x86_64-windows/"
cp "$WORK/$DXMT_TAG/x86_64-unix/winemetal.so"      "$STAGE/d9mt/winemetal/x86_64-unix/"

# --- d9mt driver + d9mtmetal unixlib ---
# D9MT_LOCAL_SRC=<path> builds from a local checkout instead of cloning the
# pinned commit, for iterating on an unpushed branch. The resulting tarball is
# for LOCAL INSTALL ONLY and must never be uploaded, because it would not
# correspond to any commit anyone can fetch; the PROVENANCE file written below
# stamps the tree's real HEAD (plus -dirty) so a stray tarball stays traceable.
# Release builds leave this unset and clone the pin.
if [[ -n "${D9MT_LOCAL_SRC:-}" ]]; then
  LOCAL_SRC="$(cd "$D9MT_LOCAL_SRC" && pwd)"
  echo "*** D9MT_LOCAL_SRC=$LOCAL_SRC — LOCAL BUILD, DO NOT UPLOAD ***"
  # Copy rather than build in place: the build writes into prebuilt/ and build/
  # and must not disturb the tree being iterated on.
  mkdir -p "$WORK/d9mt"
  (cd "$LOCAL_SRC" && tar -cf - --exclude=./build --exclude=./prebuilt .) \
    | (cd "$WORK/d9mt" && tar -xf -)
  D9MT_STAMP="$(git -C "$LOCAL_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if ! git -C "$LOCAL_SRC" diff --quiet HEAD 2>/dev/null; then
    D9MT_STAMP="$D9MT_STAMP-dirty"
  fi
  D9MT_STAMP="local-$D9MT_STAMP"
else
  git clone "$D9MT_REPO" "$WORK/d9mt"
  git -C "$WORK/d9mt" checkout "$D9MT_COMMIT"
  D9MT_STAMP="$D9MT_COMMIT"
fi

# winemetal import setup the d9mt build links against (-L prebuilt -lwinemetal).
# Mirrors d9mt's scripts/fetch-winemetal.sh but pinned to $DXMT_TAG: the 32-bit
# import lib libwinemetal.a is REQUIRED (ld's -lwinemetal search order prefers
# it over the 64-bit winemetal.dll, which would be the wrong arch for the
# i686 d3d9fe link).
mkdir -p "$WORK/d9mt/prebuilt"
cp "$WORK/$DXMT_TAG/i386-windows/winemetal.dll"   "$WORK/d9mt/prebuilt/winemetal32.dll"
cp "$WORK/$DXMT_TAG/x86_64-windows/winemetal.dll" "$WORK/d9mt/prebuilt/winemetal.dll"
cp "$WORK/$DXMT_TAG/x86_64-unix/winemetal.so"     "$WORK/d9mt/prebuilt/winemetal.so"
(
  cd "$WORK/d9mt/prebuilt"
  python3 - winemetal32.dll winemetal32.def <<'EOF'
import sys, subprocess, re
dll = sys.argv[1]
def_file = sys.argv[2]
out = subprocess.check_output(["i686-w64-mingw32-objdump", "-p", dll]).decode("utf-8")
start_idx = out.find("[Ordinal/Name Pointer] Table -- Ordinal Base 1")
if start_idx == -1:
    print("Error: Name Pointer Table not found in objdump output")
    sys.exit(1)
names = []
lines = out[start_idx:].splitlines()
for line in lines[1:]:
    if "Base Relocations" in line or "Relocations" in line:
        break
    m = re.search(r'\s+0\w+\s+(\w+)\s*$', line)
    if m:
        names.append(m.group(1))
with open(def_file, 'w') as f:
    f.write("LIBRARY winemetal.dll\nEXPORTS\n")
    for name in names:
        f.write(f"  {name}\n")
EOF
  i686-w64-mingw32-dlltool -d winemetal32.def -l libwinemetal.a \
    --dllname winemetal.dll
)

# d9mtmetal: its build script installs into a CrossOver-style tree; point CX at a
# throwaway staging dir and harvest the artifacts from the repo's build/ output.
# The script also copies into $CX/lib/wine/<arch> (dirs must pre-exist) and into
# a bottle under $HOME, so HOME is redirected to a fake home inside work/ too.
FAKE_CX="$WORK/fake-cx/Contents/SharedSupport/CrossOver"
FAKE_HOME="$WORK/fake-home"
BOTTLE="wowsilicon-unused"
mkdir -p "$FAKE_CX/lib/wine"/{i386-windows,x86_64-windows,x86_64-unix} \
  "$FAKE_HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE/drive_c/windows"/{syswow64,system32}
BOTTLE="$BOTTLE" CX="$FAKE_CX" HOME="$FAKE_HOME" \
  bash "$WORK/d9mt/tools/build-d9mtmetal.sh"

# d3d9 driver (release)
(cd "$WORK/d9mt" && RELEASE=1 bash scripts/build-dxvkfe.sh)

cp "$WORK/d9mt/build/d3d9fe.dll" "$STAGE/d9mt/d3d9.dll"

# Harvest d9mtmetal artifacts (paths per tools/build-d9mtmetal.sh build outputs).
# IMPORTANT: stage the d9mtmetal32/64.dll COPIES, not the per-arch originals —
# make-builtin.py writes the "Wine builtin DLL" marker (offset 0x40) only into
# those copies, and wine skips unmarked builtins (no unixlib pairing).
cp "$WORK/d9mt/build/d9mtmetal/d9mtmetal32.dll" "$STAGE/d9mt/d9mtmetal/i386-windows/d9mtmetal.dll"
cp "$WORK/d9mt/build/d9mtmetal/d9mtmetal64.dll" "$STAGE/d9mt/d9mtmetal/x86_64-windows/d9mtmetal.dll"
cp "$WORK/d9mt/build/d9mtmetal/d9mtmetal.so"    "$STAGE/d9mt/d9mtmetal/x86_64-unix/d9mtmetal.so"

# Sanity: all seven payload files exist
for f in d3d9.dll \
  winemetal/i386-windows/winemetal.dll winemetal/x86_64-windows/winemetal.dll winemetal/x86_64-unix/winemetal.so \
  d9mtmetal/i386-windows/d9mtmetal.dll d9mtmetal/x86_64-windows/d9mtmetal.dll d9mtmetal/x86_64-unix/d9mtmetal.so; do
  test -s "$STAGE/d9mt/$f" || { echo "MISSING payload file: $f"; exit 1; }
done

# Sanity: both staged d9mtmetal PE dlls carry the "Wine builtin DLL" marker
# (16 bytes at offset 0x40, per tools/make-builtin.py)
for f in d9mtmetal/i386-windows/d9mtmetal.dll d9mtmetal/x86_64-windows/d9mtmetal.dll; do
  marker="$(dd if="$STAGE/d9mt/$f" bs=1 skip=64 count=16 2>/dev/null)"
  [ "$marker" = "Wine builtin DLL" ] || { echo "MISSING wine-builtin marker (offset 0x40): $f"; exit 1; }
done

# Sanity: d3d9.dll is a 32-bit PE (i686 driver)
file "$STAGE/d9mt/d3d9.dll" | grep -q "PE32" || { echo "d3d9.dll is not a PE32 binary"; exit 1; }

# License notices (d9mt has no top-level LICENSE; keep upstream attributions).
# Required: a payload without license notices must fail the build, not ship.
cp "$WORK/d9mt/README.md" "$STAGE/d9mt/LICENSES/d9mt-README.md"
# --retry like the tarball fetch above: this is the LAST step of a ~20 minute
# build and a missing licence is deliberately fatal, so a transient rate limit
# here throws the whole build away. Observed in practice: raw.githubusercontent
# returned HTTP 429 after several payload builds in one session, and curl's
# default --retry does not cover 429, hence --retry-all-errors.
curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
  -o "$STAGE/d9mt/LICENSES/DXMT-LICENSE.txt" \
  "https://raw.githubusercontent.com/3Shain/dxmt/$DXMT_TAG/LICENSE"
for f in LICENSES/d9mt-README.md LICENSES/DXMT-LICENSE.txt; do
  test -s "$STAGE/d9mt/$f" || { echo "MISSING license file: $f"; exit 1; }
done

# Provenance stamp travels inside the tarball, so an installed payload can always
# be traced back to a commit (or outed as a local build).
cat > "$STAGE/d9mt/PROVENANCE" <<EOF
payload_version=$PAYLOAD_VERSION
d9mt_source=$D9MT_STAMP
dxmt_tag=$DXMT_TAG
EOF

tar -czf "$DIST/d9mt-$PAYLOAD_VERSION.tar.gz" -C "$STAGE" d9mt
(cd "$DIST" && shasum -a 256 "d9mt-$PAYLOAD_VERSION.tar.gz" > "d9mt-$PAYLOAD_VERSION.tar.gz.sha256")
echo "Built $DIST/d9mt-$PAYLOAD_VERSION.tar.gz  (d9mt source: $D9MT_STAMP)"
cat "$DIST/d9mt-$PAYLOAD_VERSION.tar.gz.sha256"
case "$D9MT_STAMP" in
  local-*) echo "!!! LOCAL BUILD — do NOT upload this to the runtime-v1 release:"
           echo "!!! RuntimeUpdateService auto-adopts the highest d9mt-<N> within 24h." ;;
esac
