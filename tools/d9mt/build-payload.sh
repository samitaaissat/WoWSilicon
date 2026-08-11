#!/bin/bash
# Builds the WoWSilicon d9mt payload tarball from pinned upstream sources:
#   - d9mt  @ 237e2935e58355d1ee41fda097e1af272d5f62f0 (neo773/d9mt)
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

D9MT_COMMIT=237e2935e58355d1ee41fda097e1af272d5f62f0
DXMT_TAG=v0.80
PAYLOAD_VERSION="${PAYLOAD_VERSION:-1}"

cd "$(dirname "$0")"
WORK="$PWD/work"
DIST="$PWD/dist"
STAGE="$WORK/stage"
rm -rf "$WORK"
mkdir -p "$WORK" "$DIST" "$STAGE/d9mt"/{winemetal,d9mtmetal}/{i386-windows,x86_64-windows,x86_64-unix} "$STAGE/d9mt/LICENSES"

# --- prereqs ---
for tool in i686-w64-mingw32-g++ i686-w64-mingw32-dlltool x86_64-w64-mingw32-dlltool \
            glslang python3 curl git; do
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
git clone https://github.com/neo773/d9mt "$WORK/d9mt"
git -C "$WORK/d9mt" checkout "$D9MT_COMMIT"

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

# Harvest d9mtmetal artifacts (paths per tools/build-d9mtmetal.sh build outputs)
cp "$WORK/d9mt/build/d9mtmetal/i386/d9mtmetal.dll"   "$STAGE/d9mt/d9mtmetal/i386-windows/d9mtmetal.dll"
cp "$WORK/d9mt/build/d9mtmetal/x86_64/d9mtmetal.dll" "$STAGE/d9mt/d9mtmetal/x86_64-windows/d9mtmetal.dll"
cp "$WORK/d9mt/build/d9mtmetal/d9mtmetal.so"         "$STAGE/d9mt/d9mtmetal/x86_64-unix/d9mtmetal.so"

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
