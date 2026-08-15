# Releasing

WoWSilicon releases are created from version tags such as `v2.6.0`.

## GitHub Setup

The `WoWSilicon/WoWSilicon` repository needs these Actions secrets:

- `SPARKLE_PRIVATE_KEY`
- `PAGES_REPO_TOKEN`

`SPARKLE_PRIVATE_KEY` must be the Sparkle private EdDSA key value only. Do not
use the public key, XML, or the full `generate_keys` output. The secret should
look like one base64 string; optional surrounding quotes or a
`SPARKLE_PRIVATE_KEY=` prefix are tolerated.

`PAGES_REPO_TOKEN` must have contents write access to `WoWSilicon/wowsilicon.github.io`.

## Versioning

The app uses semantic versions for display and a numeric build number for update ordering.

```text
2.5.0  -> 20500
2.5.1  -> 20501
2.5.10 -> 20510
2.6.0  -> 20600
```

The release workflow computes the build number automatically from the tag.

## Local Builds

```sh
make bundle
make dmg
make appcast
```

For a specific version:

```sh
make dmg VERSION=2.6.0 BUILD_NUMBER=20600
```

To include release notes in the appcast locally, add a markdown file under
`docs/releases/` and pass it to `make appcast`:

```sh
RELEASE_NOTES_FILE=docs/releases/2.6.0.md make appcast VERSION=2.6.0 BUILD_NUMBER=20600
```

## Release Flow

Add release notes for the version:

```sh
docs/releases/2.6.0.md
```

Then update the version, commit it, and create and push a tag:

```sh
tools/release/set_version.sh 2.6.0
git add Packaging/Info.plist Project.swift docs/releases/2.6.0.md
git commit -m "Bump version to 2.6.0"
git tag v2.6.0
git push origin main --tags
```

The GitHub Action uses `docs/releases/<version>.md` when it exists. The same
notes are embedded in the Sparkle appcast and used as the GitHub Release body.
If the file is missing, the release falls back to generated placeholder notes.

The GitHub Action builds the DMG, creates or updates the GitHub Release, generates the signed update feed, and publishes `appcast.xml` to the Pages repository.

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
it; `make bundle` then stages the runtime as the nested
`WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app` — wine's `bin/`
becomes `Contents/MacOS` (including the `x87sidecar` binary the runtime
tarball ships), `lib/` and `share/` sit beside it, and a generated Info.plist
declares the games category and Game Mode keys — before codesigning. That
geometry is what lets macOS Game Mode recognise the game process; keep
executables directly in `Contents/MacOS`. To move the app to a new runtime,
update all three pins in the same commit and rebuild.

Since runtime-v4 the runtime carries the x87sidecar cooperative-attach patch
(`tools/runtime/patches/0002-…`) and bundles the pinned
[athei/x87sidecar](https://github.com/athei/x87sidecar) binary in `bin/` —
wine and the sidecar share a Mach wire protocol (`coop_proto.h`), so they
version as one artifact. The legacy `ROSETTA_X87_PATH`/rosettax87 exec path
is preserved in the patch so older deployed apps that auto-adopt a newer
runtime keep launching unchanged.

### d9mt Payload

The optional d9mt renderer payload (`d9mt-<n>.tar.gz`: `d3d9.dll` plus the
`winemetal`/`d9mtmetal` DLLs and `.so` unixlibs) is built by
`tools/d9mt/build-payload.sh` and uploaded as an extra asset on the
`runtime-v<n>` release page — it has no tag or workflow of its own.

Since payload v2 the d9mt sources come from our fork
[samitaaissat/d9mt](https://github.com/samitaaissat/d9mt) (integration branch
`wowsilicon`), which carries the depth-bias fix for projected textures
clipping into terrain and, since v3, the bind-path performance work (~20%
frame time at high draw counts; see the fork's `docs/PERF-ROADMAP.md`) on top
of the last pinned upstream (neo773/d9mt @ `237e2935`). New upstream work
should be rebased into the fork branch and the `D9MT_COMMIT` pin in
`build-payload.sh` bumped.

The app pins it in the `Makefile` alongside the runtime pins:

- `D9MT_VERSION` — the payload version (`3` for `d9mt-3.tar.gz`)
- `D9MT_SHA256` — the expected checksum of the tarball
- `D9MT_URL` — the GitHub release asset URL

`make fetch-d9mt` downloads the tarball to `.build/d9mt-cache/`, verifies
`D9MT_SHA256`, and extracts it into
`Sources/WoWSiliconSwift/Resources/Patching/d9mt` (gitignored — never commit
it); `make bundle` then stages the `winemetal`/`d9mtmetal` files as Wine
builtins into the nested game app's `lib/wine` arch dirs. Bump all three
`D9MT_*` pins together in one commit, like the runtime pins.

### mtld3d Payload

The mtld3d renderer payload (`mtld3d-<n>.tar.gz`) is a repackaging of the
pinned upstream [athei/mtld3d](https://github.com/athei/mtld3d) release
bundle, produced by `tools/mtld3d/build-payload.sh` (which verifies the
upstream sha and re-roots the bundle under a leading `mtld3d/` component) and
uploaded as an extra asset on the `runtime-v<n>` release page like d9mt. To
adopt a new upstream release: bump `MTLD3D_TAG`/`MTLD3D_SHA256` in
`build-payload.sh`, run it with the next `PAYLOAD_VERSION`, upload
`dist/mtld3d-<n>.tar.gz` + `.sha256`, then bump the Makefile pins.

The app pins it in the `Makefile` alongside the runtime pins
(`MTLD3D_VERSION` / `MTLD3D_SHA256` / `MTLD3D_URL`, bumped together).
`make fetch-mtld3d` downloads and verifies the tarball, extracting it into
`Sources/WoWSiliconSwift/Resources/Patching/mtld3d` (gitignored); from there
`PatchService` stages the native-override `d3d9.dll` + `mtld3d.conf` into the
game folder and the `mtld3d.fake.dll` prefix markers, while `make bundle`
stages the `mtld3d.dll`/`mtld3d.so` builtin pair into the nested game app's
`lib/wine` arch dirs.

### Runtime Self-Updates

Independently of app releases, `RuntimeUpdateService` polls
`samitaaissat/WoWSilicon`'s releases at app startup (debounced to once per 24h;
"Check for Runtime Updates" in Troubleshooting forces an immediate check) for a
wine tarball, d9mt payload, or mtld3d payload newer than what the running app
was built with (`WSBundledRuntimeVersion`/`WSBundledD9MTVersion`/
`WSBundledMTLD3DVersion` in `Packaging/Info.plist`, kept in sync with
`RUNTIME_VERSION`/`D9MT_VERSION`/`MTLD3D_VERSION` by the `bundle` target).
Anything newer is downloaded, checksum-verified against its `.sha256` sidecar
asset, and assembled into an override copy of the nested game bundle under the
portable Data folder (`WoWSilicon Data/RuntimeUpdate/`) — the app never writes
into the signed `.app` bundle itself. `WineRuntime` and `PatchService` prefer
this override whenever it looks structurally valid, and fall back to the
bundled runtime otherwise (including automatically, once a later app release
ships a runtime newer than a stale override).

This means a `.sha256` sidecar asset is required for auto-update to ever pick
up a release asset — already true for every wine tarball the runtime workflow
publishes, but worth remembering when manually uploading a new
`d9mt-<n>.tar.gz` to a `runtime-v<n>` release page: upload the
`d9mt-<n>.tar.gz.sha256` `build-payload.sh` produces alongside it, or
`RuntimeUpdateService` will silently skip that version.
