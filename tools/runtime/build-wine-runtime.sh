#!/usr/bin/env bash
#
# Builds the WoWSilicon bundled Wine runtime from WineAndAqua/wine
# (branch wine-11.14-macos, pinned commit) on x86_64 (macos-15-intel runner,
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
# winedbg is deliberately BUILT (do not add --disable-winedbg). The upstream
# branch routes all crash reporting through it: wine.inf sets
# WineDbg\ShowCrashDialog=0, AeDebug\Debugger="winedbg --auto %ld %ld", and the
# CW "dump crash info to stderr" hack makes winedbg print the faulting thread,
# backtrace, module list and registers to the real unix stderr. Without the
# binary, a crashing game only ever emits
#   err:seh:start_debugger Couldn't start debugger L"winedbg --auto ..." (2)
# and dies with no stack — and macOS produces no .ips either, because wine
# handled the signal itself. That combination is what makes crashes here
# unreproducible after the fact.
#
# Prereqs (brew): bison ccache gettext mingw-w64 pkgconfig freetype gnutls
#                 libpcap sdl2 molten-vk
set -euo pipefail

RUNTIME_BUILD_NUMBER="${RUNTIME_BUILD_NUMBER:-1}"
WINE_REPO="https://github.com/WineAndAqua/wine"
WINE_BRANCH="wine-11.14-macos"
# Pinned via: git ls-remote https://github.com/WineAndAqua/wine refs/heads/wine-11.14-macos
WINE_COMMIT="e7c066a82add8a06884e30d9893f978d072f3354"

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
# Fetch the pinned commit by SHA, not the branch: WineAndAqua force-pushes its
# macOS branches, and a moved branch tip makes the old pin unreachable by
# branch fetch (GitHub still serves the orphaned commit object directly).
git -C "$SRC_DIR" fetch origin "$WINE_COMMIT"
git -C "$SRC_DIR" checkout --detach "$WINE_COMMIT"
# checkout --detach onto the commit we are already on leaves earlier patched
# files in place, so a rebuild would stack patches or fail to apply them.
git -C "$SRC_DIR" reset --hard "$WINE_COMMIT"

# --- WoWSilicon patches ---------------------------------------------------
# Applied in filename order on top of the pinned commit. Each must apply
# cleanly: a silently skipped patch would ship a runtime that looks fine and
# is missing a fix, so --check gates before anything is modified.
PATCH_DIR="$ROOT_DIR/tools/runtime/patches"
if [[ -d "$PATCH_DIR" ]]; then
  shopt -s nullglob
  for patch in "$PATCH_DIR"/*.patch; do
    echo "Applying $(basename "$patch")"
    if ! git -C "$SRC_DIR" apply --check "$patch"; then
      echo "error: $(basename "$patch") does not apply to $WINE_COMMIT." >&2
      echo "       Rebase it after bumping WINE_COMMIT." >&2
      exit 1
    fi
    git -C "$SRC_DIR" apply "$patch"
  done
  shopt -u nullglob
fi

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

# --- Bundle the Homebrew dylibs Wine dlopens at runtime ---------------------
# Wine loads MoltenVK (DXVK), freetype and gnutls via dlopen("lib*.dylib");
# dlopen searches the loading image's LC_RPATHs, and the unix .so's carry
# @loader_path/../../ (i.e. wine/lib). Copy the brew dylibs plus their
# transitive brew deps there and rewrite install names so nothing references
# the build host's $BREW_PREFIX at runtime.
bundle_dylib() {
  local src="$1" name dest dep
  name="$(basename "$src")"
  dest="$STAGING_DIR/wine/lib/$name"
  [[ -f "$dest" ]] && return 0
  cp -L "$src" "$dest"
  install_name_tool -id "@rpath/$name" "$dest"
  while IFS= read -r dep; do
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$dest"
    bundle_dylib "$dep"
  done < <(otool -L "$dest" | awk 'NR > 1 && /^\t\/(usr\/local|opt\/homebrew)\// {print $1}')
}

bundle_dylib "$BREW_PREFIX/lib/libMoltenVK.dylib"
bundle_dylib "$BREW_PREFIX/lib/libfreetype.6.dylib"
bundle_dylib "$BREW_PREFIX/lib/libgnutls.30.dylib"

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

# --- Normalize mtimes ---------------------------------------------------------
# wine stamps every prefix with wine.inf's mtime (.update-timestamp) and re-runs
# the full prefix update on ANY mismatch. The mtime must therefore be
# (a) identical across rebuilds of the same runtime version — otherwise every
#     rebuilt tarball forces a spurious multi-minute prefix refresh — and
# (b) different across runtime versions, so a real runtime bump still triggers
#     exactly one legitimate refresh.
# Derivation: fixed 2026-01-01T00:00:00Z base + RUNTIME_BUILD_NUMBER seconds.
# Must run AFTER codesigning (signing rewrites the Mach-O files).
RUNTIME_EPOCH=$((1767225600 + RUNTIME_BUILD_NUMBER))
RUNTIME_TOUCH_STAMP="$(TZ=UTC date -r "$RUNTIME_EPOCH" +%Y%m%d%H%M.%S)"
find "$STAGING_DIR/wine" -exec env TZ=UTC touch -h -t "$RUNTIME_TOUCH_STAMP" {} +

# --- Package -----------------------------------------------------------------
# Package BEFORE the smoke test so the tarball exists (and can be uploaded as
# a workflow artifact) even when the smoke test fails — the Intel CI runner is
# only a build host; the runtime's real environment is Rosetta on Apple Silicon.
tar -C "$STAGING_DIR" -cJf "$DIST_DIR/$ARTIFACT" wine
(cd "$DIST_DIR" && shasum -a 256 "$ARTIFACT" > "$ARTIFACT.sha256")

echo "Runtime artifacts:"
ls -lh "$DIST_DIR"

# --- Smoke test ---------------------------------------------------------------
# The crash reporter must be in the tree (hard gate). AeDebug launches the
# i386 winedbg.exe for the 32-bit game clients; without it every crash is
# reported as "Couldn't start debugger" with no stack. See the note at the top
# of this script.
for arch in i386 x86_64; do
  if [[ ! -f "$STAGING_DIR/wine/lib/wine/${arch}-windows/winedbg.exe" ]]; then
    echo "error: winedbg.exe missing for ${arch} — crashes would be unreportable." >&2
    echo "       Did someone re-add --disable-winedbg to configure?" >&2
    exit 1
  fi
done

# Bundled dylibs must not reference the build host's brew prefix (hard gate).
if otool -L "$STAGING_DIR/wine/lib/"*.dylib | grep -E $'\t/(usr/local|opt/homebrew)/'; then
  echo "error: bundled dylib still references the build host's Homebrew prefix" >&2
  exit 1
fi

# The build host is Intel while the runtime's real environment is Rosetta on
# Apple Silicon; wineboot on macOS-on-Intel fails on this tree (validated
# separately on Apple Silicon), so only `wine --version` gates the build.
SMOKE_PREFIX="${RUNNER_TEMP:-$WORK_DIR}/testpfx"
rm -rf "$SMOKE_PREFIX"
arch -x86_64 "$STAGING_DIR/wine/bin/wine" --version
WINEPREFIX="$SMOKE_PREFIX" WINEDLLOVERRIDES="mscoree=d;mshtml=d" \
  arch -x86_64 "$STAGING_DIR/wine/bin/wine" wineboot -u || \
  echo "warning: wineboot smoke test failed on the Intel build host (expected; validated on Apple Silicon)"
