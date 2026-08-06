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

It bundles a pre-patched Wine runtime, RosettaX87, DX9 translation, and runtime patching so clients from the 2006-2010 era can run more efficiently on modern macOS hardware.

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

On first launch, macOS shows a one-time prompt asking to allow WoWSilicon to attach to other processes for debugging. The bundled RosettaX87 loader needs this authorization to run the 32-bit client; approve it once and macOS will not ask again.

## Installation

Download the latest release from:

https://wowsilicon.github.io/

Move `WoWSilicon.app` to `/Applications`.

If macOS blocks the app because the build is unsigned, remove the quarantine attribute after moving it:

```sh
xattr -cr /Applications/WoWSilicon.app
```

Then open WoWSilicon, select the game folder, apply the game patch, and launch the selected client profile.

## Bundled components & licenses

WoWSilicon.app ships the following third-party components:

- **Wine** (LGPL-2.1-or-later) — the bundled, pre-patched runtime is built from
  [WineAndAqua/wine](https://github.com/WineAndAqua/wine) (branch `wine-11.14-macos`)
  at the commit pinned in [`tools/runtime/build-wine-runtime.sh`](tools/runtime/build-wine-runtime.sh).
  The app bundles the `runtime-v*` release selected by `RUNTIME_VERSION` in the
  [`Makefile`](Makefile); Wine's LICENSE files ship inside
  `WoWSilicon.app/Contents/SharedSupport/wine/`.
- **rosettax87_jit** (MIT) — the RosettaX87 loader, by
  [Lifeisawful](https://github.com/Lifeisawful/rosettax87_jit).
- **winerosetta** — game-folder DLL payload, from the
  [Gcenx mirror](https://github.com/Gcenx/winerosetta).
- **DXVK / d9vk** (zlib) — the native `d3d9.dll` DirectX 9 translation layer.
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
