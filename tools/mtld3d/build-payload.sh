#!/bin/bash
# Repackages the pinned upstream mtld3d release bundle (athei/mtld3d) as the
# WoWSilicon mtld3d payload tarball. No compilation happens here — upstream
# ships prebuilt, and this script only verifies, sanity-checks and re-roots
# the bundle under a leading mtld3d/ component so the Makefile and
# RuntimeUpdateService can treat it exactly like the d9mt payload.
#
# Output: dist/mtld3d-<N>.tar.gz + .sha256, layout (mirrors the upstream
# bundle, see its INSTALL.md):
#   mtld3d/native/{i386-windows,x86_64-windows}/d3d9.dll   (native-override PE)
#   mtld3d/wine/{i386-windows,x86_64-windows}/mtld3d.dll   (builtin pair, PE half)
#   mtld3d/wine/{i386-windows,x86_64-windows}/mtld3d.fake.dll (prefix markers)
#   mtld3d/wine/{i386-windows,x86_64-windows}/d3d9.dll     (builtin route; unused)
#   mtld3d/wine/x86_64-unix/mtld3d.so                      (builtin pair, unix half)
#   mtld3d/mtld3d.conf                                     (sample config)
#   mtld3d/INSTALL.md, mtld3d/LICENSE
#
# Upload dist/mtld3d-<N>.tar.gz + .sha256 to the runtime-v1 release of
# samitaaissat/WoWSilicon (the payload shelf, same as d9mt), then bump the
# MTLD3D_* pins in the Makefile.
set -euo pipefail

MTLD3D_TAG=v0.6.0
MTLD3D_URL="https://github.com/athei/mtld3d/releases/download/$MTLD3D_TAG/mtld3d.tar.xz"
MTLD3D_SHA256=906d7ef476ccd78d7fbbf26f7d5f36b81af6d1b3fb9f61ff1f9f2660c0940e10
PAYLOAD_VERSION="${PAYLOAD_VERSION:-1}"

cd "$(dirname "$0")"
WORK="$PWD/work"
DIST="$PWD/dist"
STAGE="$WORK/stage"
rm -rf "$WORK"
mkdir -p "$WORK" "$DIST" "$STAGE/mtld3d"

curl -fL --retry 3 -o "$WORK/mtld3d.tar.xz" "$MTLD3D_URL"
echo "$MTLD3D_SHA256  $WORK/mtld3d.tar.xz" | shasum -a 256 -c -
tar -xJf "$WORK/mtld3d.tar.xz" -C "$STAGE/mtld3d"

# Sanity: every file the app stages must exist and be non-empty.
for f in native/i386-windows/d3d9.dll native/x86_64-windows/d3d9.dll \
  wine/i386-windows/mtld3d.dll wine/x86_64-windows/mtld3d.dll \
  wine/i386-windows/mtld3d.fake.dll wine/x86_64-windows/mtld3d.fake.dll \
  wine/x86_64-unix/mtld3d.so mtld3d.conf LICENSE; do
  test -s "$STAGE/mtld3d/$f" || { echo "MISSING payload file: $f"; exit 1; }
done

# Sanity: the builtin-pair PEs carry the "Wine builtin DLL" marker (offset
# 0x40) — wine only pairs a PE with its unixlib when the marker is present —
# and the native-override d3d9.dll must NOT carry it (wine never executes a
# builtin-marked PE found outside its builtin search path).
for f in wine/i386-windows/mtld3d.dll wine/x86_64-windows/mtld3d.dll; do
  marker="$(dd if="$STAGE/mtld3d/$f" bs=1 skip=64 count=16 2>/dev/null)"
  [ "$marker" = "Wine builtin DLL" ] || { echo "MISSING wine-builtin marker (offset 0x40): $f"; exit 1; }
done
for f in native/i386-windows/d3d9.dll native/x86_64-windows/d3d9.dll; do
  marker="$(dd if="$STAGE/mtld3d/$f" bs=1 skip=64 count=16 2>/dev/null)"
  [ "$marker" != "Wine builtin DLL" ] || { echo "UNEXPECTED wine-builtin marker on native PE: $f"; exit 1; }
done

# Sanity: the game-folder override is a 32-bit PE (the supported clients are i386).
file "$STAGE/mtld3d/native/i386-windows/d3d9.dll" | grep -q "PE32" \
  || { echo "native/i386-windows/d3d9.dll is not a PE32 binary"; exit 1; }

tar -czf "$DIST/mtld3d-$PAYLOAD_VERSION.tar.gz" -C "$STAGE" mtld3d
(cd "$DIST" && shasum -a 256 "mtld3d-$PAYLOAD_VERSION.tar.gz" > "mtld3d-$PAYLOAD_VERSION.tar.gz.sha256")
echo "Built $DIST/mtld3d-$PAYLOAD_VERSION.tar.gz (upstream $MTLD3D_TAG)"
cat "$DIST/mtld3d-$PAYLOAD_VERSION.tar.gz.sha256"
