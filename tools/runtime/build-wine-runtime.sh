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
WINE_COMMIT="ec3ba59b8d717a2115384f5999c7b1a984bee3bb"

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
