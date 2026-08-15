<p align="center">
  <img src="Sources/WoWSiliconSwift/Resources/Icons/turtlesilicon_icon.png" alt="WoWSilicon icon" width="96" height="96">
</p>

<h1 align="center">WoWSilicon</h1>

<p align="center">
  <a href="https://github.com/WoWSilicon/WoWSilicon/actions/workflows/release.yml">
    <img src="https://github.com/WoWSilicon/WoWSilicon/actions/workflows/release.yml/badge.svg" alt="Release workflow status">
  </a>
  <a href="https://github.com/WoWSilicon/WoWSilicon/stargazers">
    <img src="https://img.shields.io/github/stars/WoWSilicon/WoWSilicon?style=flat&label=stars" alt="GitHub stars">
  </a>
  <a href="https://github.com/WoWSilicon/WoWSilicon/releases">
    <img src="https://img.shields.io/github/downloads/WoWSilicon/WoWSilicon/total?style=flat&label=downloads" alt="GitHub release downloads">
  </a>
  <a href="https://github.com/WoWSilicon/WoWSilicon/releases">
    <img src="https://img.shields.io/github/v/release/WoWSilicon/WoWSilicon?style=flat&label=latest" alt="Latest release">
  </a>
  <a href="https://discord.gg/pwZD5zBwfD">
    <img src="https://img.shields.io/badge/discord-join-5865F2?style=flat&logo=discord&logoColor=white" alt="Join the Discord">
  </a>
</p>

WoWSilicon is a macOS launcher for older World of Warcraft clients on Apple Silicon Macs.

It bundles a pre-patched Wine runtime, the x87sidecar floating-point JIT, Metal-native DX9 translation (mtld3d), and runtime patching so clients from the 2006-2010 era can run more efficiently on modern macOS hardware.

<p align="center">
  <img src="docs/assets/launcher-preview.png" alt="WoWSilicon launcher preview" width="760">
</p>

## Supported Clients

- Vanilla 1.12.1
- The Burning Crusade 2.4.3
- Wrath of the Lich King 3.3.5a
- Custom profiles based on the supported client families

## Features

- Version profiles for separate client folders
- Bundled, pre-patched Wine runtime (built from WineAndAqua/wine, wine-11.14-macos)
- Game-folder patching for required runtime files
- libSiliconPatch mod (reducing x87-heavy runtime paths)
- Addon manager with Git URL installs, updates, bulk import, and bulk export
- Mod manager for DLL-style mods
- Realmlist editor
- Graphics options, Retina mode, cursor scaling, Option-as-Alt, environment variables, and Metal HUD support
- Built-in update checks through the macOS app menu and Options window

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- A legally acquired local World of Warcraft client folder
- Permission to modify the selected game folder

No debugger authorization is needed: the bundled x87sidecar attaches to the 32-bit client cooperatively (the game process hands over its ports voluntarily), so macOS shows no attach-for-debugging prompt.

## Installation

Download the latest release from:

https://wowsilicon.github.io/

Move `WoWSilicon.app` to `/Applications`.

If macOS blocks the app because the build is unsigned, remove the quarantine attribute after moving it:

```sh
xattr -cr /Applications/WoWSilicon.app
```

Then open WoWSilicon, select the game folder, apply the game patch, and launch the selected client profile.

## Portable by design

WoWSilicon keeps everything it needs in a `WoWSilicon Data` folder right next
to `WoWSilicon.app` — your settings and its own private Wine environment.

- **Move or copy your whole setup** by moving the app and the `WoWSilicon
  Data` folder together (another folder, an external drive, a new Mac).
- **Do not delete `WoWSilicon Data`** unless you want a factory reset — that
  folder *is* your WoWSilicon installation.
- If the app runs from a read-only location (for example directly from the
  DMG), it temporarily keeps its data in `~/Library/Application
  Support/WoWSilicon` and adopts the portable folder automatically once you
  move the app somewhere writable. The Troubleshooting window shows which
  location is active.

## Bundled components & licenses

WoWSilicon.app ships the following third-party components:

- **Wine** (LGPL-2.1-or-later) — the bundled, pre-patched runtime is built from
  [WineAndAqua/wine](https://github.com/WineAndAqua/wine) (branch `wine-11.15-macos`)
  at the commit pinned in [`tools/runtime/build-wine-runtime.sh`](tools/runtime/build-wine-runtime.sh).
  The app bundles the `runtime-v*` release selected by `RUNTIME_VERSION` in the
  [`Makefile`](Makefile); Wine's LICENSE files ship inside
  `WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/share/licenses/`.
- **mtld3d** (Zlib) — the Metal-native Direct3D 9 implementation and default
  renderer, by [athei](https://github.com/athei/mtld3d).
- **x87sidecar** (MIT) — the out-of-process x87 JIT for Rosetta 2, by
  [athei](https://github.com/athei/x87sidecar) (a fork of
  [Lifeisawful's rosettax87_jit](https://github.com/Lifeisawful/rosettax87_jit)).
  Bundled inside the runtime tarball; wine attaches to it cooperatively.
- **winerosetta** — game-folder DLL payload, from the
  [Gcenx mirror](https://github.com/Gcenx/winerosetta).
- **DXVK / d9vk** (zlib) — the `d3d9.dll` DirectX 9→Vulkan translation layer
  behind the legacy d9vk renderer.
- **vanilla-tweaks** (MIT) — client tweaking tool used by the vanilla-tweaks patch step.

## Development

Build and test:

```sh
swift build
swift test
```

Build the app bundle:

```sh
make bundle
```

Build a DMG:

```sh
make dmg
```

Run the bundled app:

```sh
make run
```

## Releases

Release automation is handled through GitHub Actions. A version tag such as `v2.6.0` builds the DMG, creates or updates the GitHub Release, generates the signed update feed, and publishes `appcast.xml` to the Pages repository.

See [docs/releasing.md](docs/releasing.md) for the release flow and required repository secrets.

## Disclaimer

WoWSilicon is not affiliated with or endorsed by Blizzard Entertainment.

This project is not advocating the use of any private server. It is intended to help older client binaries run on Apple Silicon hardware in an efficient and performant way. The project maintainers are not liable for how the launcher is used.
