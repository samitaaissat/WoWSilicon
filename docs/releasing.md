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
becomes `Contents/MacOS` (plus the rosettax87 loader pair), `lib/` and `share/`
sit beside it, and a generated Info.plist declares the games category and Game
Mode keys — before codesigning. That geometry is what lets macOS Game Mode
recognise the game process; keep executables directly in `Contents/MacOS`. To
move the app to a new runtime, update all three pins in the same commit and
rebuild.
