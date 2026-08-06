# v3 runtime spike results (Milestone 0 gate)

Date: 2026-08-06
Runtime: runtime-v1 (wowsilicon-wine-1-osx64.tar.xz, sha256 1ee361ac913301cb3a771f91f159fcc088be7edb2bfd16368feba95bcf37dfed, 95 MB compressed)
Wine pin: WineAndAqua/wine@e7c066a82add8a06884e30d9893f978d072f3354 (wine-11.14-macos)
Machine(s): macOS 27 (kernel 27.0.0), Apple Silicon

Note: executed out of plan order by user direction — Task 11 (Makefile
fetch-runtime + bundle) landed first and the client boots were performed
with the fully packaged app (`WoWSilicon-2.5.5.dmg`, runtime embedded at
Contents/SharedSupport/wine, codesign seal verified) instead of the
hand-grafted bundle. The CI/Intel smoke-test anomaly and its resolution
are documented in the SDD ledger (Intel runner fails wineboot on this
tree; the identical build passes under Rosetta, the actual target).

| Check | Result |
|---|---|
| wine --version under Rosetta | PASS |
| Prefix boots, no mono/gecko prompts | PASS |
| Vanilla 1.12 reaches login | PASS |
| WotLK 3.3.5a reaches login | PASS |
| DXVK d3d9 active (HUD visible) | PASS |
| DivxDecoder rundll32 patching | PASS (via the app's game-patch flow) |
| Retina/OptionAsAlt registry writes | PASS |
| Debug-authorization prompt once, game runs after accept | PASS |
| macOS 27 beta repeat | PASS (this machine is macOS 27) |

Decision: GO for release.

Notes: runtime dlopen dependencies (freetype, gnutls) were initially not
bundled and warned on machines without an Intel Homebrew; fixed before
publication by bundling the full Homebrew dependency closure into
wine/lib (validated: no warnings remain). Tarball is ~95 MB, smaller
than the spec's 140-160 MB estimate. Upstream force-pushed
wine-11.14-macos during the build window; the build script now fetches
the pinned commit by SHA so history rewrites cannot break it.
