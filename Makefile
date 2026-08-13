APP_NAME := WoWSilicon
BINARY_NAME := WoWSilicon
BUILD_DIR := $(CURDIR)/.build
VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)
BUILD_NUMBER ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)
RELEASE_BIN := $(BUILD_DIR)/arm64-apple-macosx/release/$(BINARY_NAME)
DEBUG_BIN := $(BUILD_DIR)/arm64-apple-macosx/debug/$(BINARY_NAME)
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
SPARKLE_FRAMEWORK := $(BUILD_DIR)/arm64-apple-macosx/release/Sparkle.framework
SPARKLE_ACCOUNT ?= com.wowsilicon.updates
SPARKLE_GENERATE_APPCAST := $(BUILD_DIR)/artifacts/sparkle/Sparkle/bin/generate_appcast
DOWNLOAD_URL_PREFIX ?= https://github.com/WoWSilicon/WoWSilicon/releases/download/v$(VERSION)/
CODESIGN_IDENTITY ?= -
ARCHIVE_DIR := $(BUILD_DIR)/release-archives
DMG_STAGING_DIR := $(BUILD_DIR)/dmg-staging
DMG_PATH := $(ARCHIVE_DIR)/$(APP_NAME)-$(VERSION).dmg
APPCAST_DIR := $(BUILD_DIR)/appcast
APPCAST_PATH := $(APPCAST_DIR)/appcast.xml
ICON_SRC := Sources/WoWSiliconSwift/Resources/Icons/turtlesilicon_icon.png
ICONSET := $(BUILD_DIR)/turtle.iconset
APP_ICON := $(BUILD_DIR)/turtle.icns
ICON_SCRIPT := $(BUILD_DIR)/make_icns.py
SWIFT_ENV := SWIFT_MODULECACHE_PATH="$(BUILD_DIR)/swift-module-cache" CLANG_MODULE_CACHE_PATH="$(BUILD_DIR)/clang-module-cache"
SWIFT_BUILD := $(SWIFT_ENV) swift build --arch arm64 --disable-sandbox --build-path "$(BUILD_DIR)" --cache-path "$(BUILD_DIR)/spm-cache" --manifest-cache none
RESOURCE_BUNDLE := $(BUILD_DIR)/arm64-apple-macosx/release/WoWSilicon-swift_WoWSiliconSwift.bundle

# The Wine runtime is staged as a nested application bundle. macOS Game Mode only
# recognises a process whose real executable path is <X>.app/Contents/MacOS/<name>
# and whose Info.plist declares a games category — verified empirically on macOS 27,
# where both the old .../SharedSupport/wine/bin/wine geometry and a merely nested
# Contents/MacOS/bin/wine yield no LaunchServices bundle record at all.
GAME_APP_NAME := WoWSilicon Game.app
GAME_APP := $(APP_BUNDLE)/Contents/SharedSupport/$(GAME_APP_NAME)
GAME_APP_ID ?= com.wowsilicon.swift.game
ROSETTA_SRC := Sources/WoWSiliconSwift/Resources/Patching/rosettax87

# ---------------------------------------------------------------------------
# Bundled Wine runtime (built by .github/workflows/runtime.yml, published as
# GitHub release runtime-v$(RUNTIME_VERSION); tarball layout: wine/{bin,lib,share,VERSION}).
# The cache lives under $(BUILD_DIR), so `make clean` removes it and the next
# `make bundle` (or `make run`) re-downloads the ~150 MB tarball — accepted;
# CI restores $(RUNTIME_CACHE) via actions/cache keyed on runtime-v$(RUNTIME_VERSION)
# (bump the key in .github/workflows/release.yml when bumping RUNTIME_VERSION).
RUNTIME_VERSION ?= 1
RUNTIME_ASSET := wowsilicon-wine-$(RUNTIME_VERSION)-osx64.tar.xz
RUNTIME_URL ?= https://github.com/samitaaissat/WoWSilicon/releases/download/runtime-v$(RUNTIME_VERSION)/$(RUNTIME_ASSET)
RUNTIME_SHA256 ?= 1ee361ac913301cb3a771f91f159fcc088be7edb2bfd16368feba95bcf37dfed
RUNTIME_CACHE := $(BUILD_DIR)/runtime-cache

# d9mt renderer payload (built by tools/d9mt/build-payload.sh, uploaded to the
# runtime-v$(RUNTIME_VERSION) release page). Bump all three pins together.
D9MT_VERSION ?= 1
D9MT_ASSET := d9mt-$(D9MT_VERSION).tar.gz
D9MT_URL ?= https://github.com/samitaaissat/WoWSilicon/releases/download/runtime-v$(RUNTIME_VERSION)/$(D9MT_ASSET)
D9MT_SHA256 ?= 9ab09e6544b05557e846f56be87b99c34149311793adb17e38c289f8e4e380df
D9MT_CACHE := $(BUILD_DIR)/d9mt-cache
D9MT_RESOURCES := Sources/WoWSiliconSwift/Resources/Patching/d9mt

.PHONY: all build debug run bundle fetch-runtime fetch-d9mt dmg appcast clean app_icon

all: bundle

build:
	@echo "Building release binary..."
	$(SWIFT_BUILD) -c release

debug:
	@echo "Building debug binary..."
	$(SWIFT_BUILD) -c debug

xcode:
	@echo "Opening Xcode project..."
	tuist generate

run: bundle
	@echo "Launching $(APP_NAME).app..."
	open "$(APP_BUNDLE)"

# fetch-d9mt MUST precede build: swift build stages the SwiftPM resource bundle
# from Sources/, so a payload fetched afterwards never enters it — on a fresh
# checkout that shipped an app without Patching/d9mt (v3.2.0 regression). The
# guard below makes any recurrence a hard build error instead of a broken DMG.
bundle: fetch-runtime fetch-d9mt build
	@test -s "$(RESOURCE_BUNDLE)/Patching/d9mt/d3d9.dll" && test -s "$(RESOURCE_BUNDLE)/Patching/d9vk/d3d9.dll" \
		|| (echo "error: $(RESOURCE_BUNDLE) is missing renderer payloads (stale build preceded fetch-d9mt?); run 'swift build' again or 'make clean'" >&2; exit 1)
	@$(MAKE) app_icon
	@echo "Staging $(APP_NAME).app..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp Packaging/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(APP_BUNDLE)/Contents/Info.plist"
	@cp "$(RELEASE_BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@chmod +x "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@cp -R "$(SPARKLE_FRAMEWORK)" "$(APP_BUNDLE)/Contents/Frameworks/"
	@if [ -d "$(RESOURCE_BUNDLE)" ]; then \
		cp -R "$(RESOURCE_BUNDLE)" "$(APP_BUNDLE)/Contents/Resources/"; \
	else \
		echo "warning: resource bundle not found at $(RESOURCE_BUNDLE)"; \
		rsync -a Sources/WoWSiliconSwift/Resources/ "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@cp "$(APP_ICON)" "$(APP_BUNDLE)/Contents/Resources/turtle.icns"
	@echo "Bundling Wine runtime v$(RUNTIME_VERSION) as $(GAME_APP_NAME)..."
	@mkdir -p "$(GAME_APP)/Contents"
	@# ditto (not cp -R): staging must preserve the tarball's file mtimes.
	@# wine stamps prefixes with wine.inf's mtime and re-runs the full prefix
	@# update on any mismatch — cp -R restamps mtimes at build time, which made
	@# every app build (even of the same runtime) force a prefix refresh.
	@# bin/ becomes Contents/MacOS so the game process gets a bundle record;
	@# lib/ and share/ stay siblings of it, which is exactly what wine's own
	@# <bindir>/../lib and <bindir>/../share resolution expects.
	@ditto "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/bin" "$(GAME_APP)/Contents/MacOS"
	@ditto "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/lib" "$(GAME_APP)/Contents/lib"
	@ditto "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/share" "$(GAME_APP)/Contents/share"
	@ditto "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/VERSION" "$(GAME_APP)/Contents/VERSION"
	@# d9mt renderer support: winemetal/d9mtmetal as wine builtins. The .so must
	@# sit next to the PE in the arch dirs for wine's find_builtin_dll pairing.
	@ditto "$(D9MT_RESOURCES)/winemetal/i386-windows/winemetal.dll" "$(GAME_APP)/Contents/lib/wine/i386-windows/winemetal.dll"
	@ditto "$(D9MT_RESOURCES)/winemetal/x86_64-windows/winemetal.dll" "$(GAME_APP)/Contents/lib/wine/x86_64-windows/winemetal.dll"
	@ditto "$(D9MT_RESOURCES)/winemetal/x86_64-unix/winemetal.so" "$(GAME_APP)/Contents/lib/wine/x86_64-unix/winemetal.so"
	@ditto "$(D9MT_RESOURCES)/d9mtmetal/i386-windows/d9mtmetal.dll" "$(GAME_APP)/Contents/lib/wine/i386-windows/d9mtmetal.dll"
	@ditto "$(D9MT_RESOURCES)/d9mtmetal/x86_64-windows/d9mtmetal.dll" "$(GAME_APP)/Contents/lib/wine/x86_64-windows/d9mtmetal.dll"
	@ditto "$(D9MT_RESOURCES)/d9mtmetal/x86_64-unix/d9mtmetal.so" "$(GAME_APP)/Contents/lib/wine/x86_64-unix/d9mtmetal.so"
	@# Wine execs the rosettax87 loader as argv[0] for i386 images
	@# (dlls/ntdll/unix/loader.c). Bundle identity is re-resolved on exec, so the
	@# loader — and the libRuntimeRosettax87 it locates via its own directory —
	@# must sit in the same Contents/MacOS or Game Mode is lost at that hop.
	@ditto "$(ROSETTA_SRC)/rosettax87" "$(GAME_APP)/Contents/MacOS/rosettax87"
	@ditto "$(ROSETTA_SRC)/libRuntimeRosettax87" "$(GAME_APP)/Contents/MacOS/libRuntimeRosettax87"
	@# Game Mode identity survives the loader re-exec only if the FINAL exec
	@# lands on a literal Contents/MacOS path. ntdll re-execs i386 images with
	@# argv[1] = Contents/lib/wine/x86_64-unix/wine, so ROSETTA_X87_PATH points
	@# at wine-rosetta-shim (tools/gamemode-shim/main.c), which rewrites argv[1]
	@# to wine-gamemode — a physical copy of that loader (the only binary with
	@# the WINE_RESERVE segments) — before exec'ing the real rosettax87. The
	@# loader finds ntdll.so in its own directory, hence the ntdll.so symlink.
	@# wine-gamemode must NOT be named "wine": the CFBundleExecutable slot binds
	@# the bundle Info.plist into signature validation, and this binary's
	@# embedded org.winehq.wine __info_plist would mismatch it (SIGKILL on exec).
	@ditto "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/lib/wine/x86_64-unix/wine" "$(GAME_APP)/Contents/MacOS/wine-gamemode"
	@ln -sfh ../lib/wine/x86_64-unix/ntdll.so "$(GAME_APP)/Contents/MacOS/ntdll.so"
	@cc -O2 -arch arm64 tools/gamemode-shim/main.c -o "$(GAME_APP)/Contents/MacOS/wine-rosetta-shim"
	@rm -f "$(GAME_APP)/Contents/Info.plist"
	@plutil -create xml1 "$(GAME_APP)/Contents/Info.plist"
	@# CFBundleExecutable MUST be wine-gamemode: LaunchServices only grants the
	@# game process its bundle identity (and hence Game Mode) when the process
	@# runs the bundle's declared executable — any other file in Contents/MacOS
	@# checks in with a NULL bundle id (verified empirically on macOS 27).
	@/usr/libexec/PlistBuddy \
		-c "Add :CFBundleExecutable string wine-gamemode" \
		-c "Add :CFBundleIdentifier string $(GAME_APP_ID)" \
		-c "Add :CFBundleName string $(APP_NAME) Game" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :CFBundleInfoDictionaryVersion string 6.0" \
		-c "Add :CFBundleShortVersionString string $(VERSION)" \
		-c "Add :CFBundleVersion string $(BUILD_NUMBER)" \
		-c "Add :LSMinimumSystemVersion string 15.0" \
		-c "Add :LSApplicationCategoryType string public.app-category.role-playing-games" \
		-c "Add :LSSupportsGameMode bool true" \
		-c "Add :GCSupportsGameMode bool true" \
		"$(GAME_APP)/Contents/Info.plist" >/dev/null
	@# LSSupportsGameMode is macOS 26+; GCSupportsGameMode covers macOS 14-25,
	@# which is most of this app's supported range (LSMinimumSystemVersion 15.0).
	@# Either key alone is sufficient on macOS 27 — both are set deliberately.
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then \
		echo "Signing $(APP_BUNDLE) with identity $(CODESIGN_IDENTITY)..."; \
		codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(APP_BUNDLE)"; \
	fi
	@echo "Bundle created at $(APP_BUNDLE)"

fetch-runtime:
	@if [ -x "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/bin/wine" ] \
		&& [ "$$(cat "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/.sha256" 2>/dev/null)" = "$(RUNTIME_SHA256)" ]; then \
		echo "Wine runtime v$(RUNTIME_VERSION) already cached at $(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
	else \
		set -e; \
		echo "Fetching Wine runtime v$(RUNTIME_VERSION) from $(RUNTIME_URL)..."; \
		rm -rf "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
		mkdir -p "$(RUNTIME_CACHE)"; \
		curl -fL --retry 3 -o "$(RUNTIME_CACHE)/$(RUNTIME_ASSET)" "$(RUNTIME_URL)"; \
		echo "$(RUNTIME_SHA256)  $(RUNTIME_CACHE)/$(RUNTIME_ASSET)" | shasum -a 256 -c -; \
		mkdir -p "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
		tar -xJf "$(RUNTIME_CACHE)/$(RUNTIME_ASSET)" -C "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
		test -x "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine/bin/wine"; \
		printf '%s' "$(RUNTIME_SHA256)" > "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/.sha256"; \
		echo "Wine runtime v$(RUNTIME_VERSION) extracted to $(RUNTIME_CACHE)/$(RUNTIME_VERSION)"; \
	fi

fetch-d9mt:
	@if [ -f "$(D9MT_RESOURCES)/.sha256" ] \
		&& [ "$$(cat "$(D9MT_RESOURCES)/.sha256")" = "$(D9MT_SHA256)" ]; then \
		echo "d9mt payload v$(D9MT_VERSION) already staged"; \
	else \
		set -e; \
		echo "Fetching d9mt payload v$(D9MT_VERSION) from $(D9MT_URL)..."; \
		mkdir -p "$(D9MT_CACHE)"; \
		curl -fL --retry 3 -o "$(D9MT_CACHE)/$(D9MT_ASSET)" "$(D9MT_URL)"; \
		echo "$(D9MT_SHA256)  $(D9MT_CACHE)/$(D9MT_ASSET)" | shasum -a 256 -c -; \
		rm -rf "$(D9MT_RESOURCES)"; \
		mkdir -p "$(D9MT_RESOURCES)"; \
		tar -xzf "$(D9MT_CACHE)/$(D9MT_ASSET)" -C "$(D9MT_RESOURCES)" --strip-components=1; \
		test -s "$(D9MT_RESOURCES)/d3d9.dll"; \
		printf '%s' "$(D9MT_SHA256)" > "$(D9MT_RESOURCES)/.sha256"; \
		echo "d9mt payload v$(D9MT_VERSION) staged into $(D9MT_RESOURCES)"; \
	fi

dmg: bundle
	@echo "Creating $(DMG_PATH)..."
	@rm -rf "$(DMG_STAGING_DIR)"
	@mkdir -p "$(DMG_STAGING_DIR)"
	@mkdir -p "$(ARCHIVE_DIR)"
	@# ditto (not cp -R): the shipped DMG must carry the runtime's normalized
	@# mtimes (see the bundle target) or wine re-runs a full prefix update.
	@ditto "$(APP_BUNDLE)" "$(DMG_STAGING_DIR)/$(APP_NAME).app"
	@ln -s /Applications "$(DMG_STAGING_DIR)/Applications"
	@rm -f "$(DMG_PATH)"
	@# hdiutil's legacy -srcfolder path is deprecated and fails with
	@# "Resource busy" on macOS 27; prefer the modern replacement when present.
	@if diskutil image create from --help >/dev/null 2>&1; then \
		diskutil image create from --format UDZO --volumeName "$(APP_NAME)" "$(DMG_STAGING_DIR)" "$(DMG_PATH)" >/dev/null; \
	else \
		hdiutil create -volname "$(APP_NAME)" -fs HFS+ -format UDZO -srcfolder "$(DMG_STAGING_DIR)" "$(DMG_PATH)" >/dev/null; \
	fi
	@echo "DMG created at $(DMG_PATH)"

appcast: dmg
	@echo "Generating Sparkle appcast..."
	@test -x "$(SPARKLE_GENERATE_APPCAST)" || (echo "Sparkle generate_appcast not found. Run swift build first." >&2; exit 1)
	@rm -rf "$(APPCAST_DIR)"
	@mkdir -p "$(APPCAST_DIR)"
	@cp "$(DMG_PATH)" "$(APPCAST_DIR)/"
	@if [ -n "$${RELEASE_NOTES_FILE:-}" ] && [ -f "$${RELEASE_NOTES_FILE}" ]; then \
		cp "$${RELEASE_NOTES_FILE}" "$(APPCAST_DIR)/$(APP_NAME)-$(VERSION).md"; \
	else \
		printf '# WoWSilicon %s\n\nSee the GitHub release for changes.\n' "$(VERSION)" > "$(APPCAST_DIR)/$(APP_NAME)-$(VERSION).md"; \
	fi
	@if [ -n "$${EXISTING_APPCAST:-}" ] && [ -f "$${EXISTING_APPCAST}" ]; then \
		cp "$${EXISTING_APPCAST}" "$(APPCAST_PATH)"; \
	fi
	@if [ -n "$${SPARKLE_PRIVATE_KEY:-}" ]; then \
		printf '%s' "$${SPARKLE_PRIVATE_KEY}" | "$(SPARKLE_GENERATE_APPCAST)" \
			--ed-key-file - \
			--embed-release-notes \
			--download-url-prefix "$(DOWNLOAD_URL_PREFIX)" \
			--link "https://wowsilicon.github.io/" \
			"$(APPCAST_DIR)"; \
	else \
		"$(SPARKLE_GENERATE_APPCAST)" \
			--account "$(SPARKLE_ACCOUNT)" \
			--embed-release-notes \
			--download-url-prefix "$(DOWNLOAD_URL_PREFIX)" \
			--link "https://wowsilicon.github.io/" \
			"$(APPCAST_DIR)"; \
	fi
	@echo "Appcast generated at $(APPCAST_PATH)"

clean:
	@echo "Cleaning build artifacts..."
	@swift package clean
	@rm -rf "$(BUILD_DIR)"

app_icon: $(APP_ICON)

$(APP_ICON): $(ICON_SRC)
	@echo "Generating app icon..."
	@rm -rf "$(ICONSET)"
	@mkdir -p "$(ICONSET)"
	@sips -z 16 16 "$<" --out "$(ICONSET)/icon_16x16.png" >/dev/null
	@sips -z 32 32 "$<" --out "$(ICONSET)/icon_16x16@2x.png" >/dev/null
	@sips -z 32 32 "$<" --out "$(ICONSET)/icon_32x32.png" >/dev/null
	@sips -z 64 64 "$<" --out "$(ICONSET)/icon_32x32@2x.png" >/dev/null
	@sips -z 64 64 "$<" --out "$(ICONSET)/icon_64x64.png" >/dev/null
	@sips -z 128 128 "$<" --out "$(ICONSET)/icon_64x64@2x.png" >/dev/null
	@sips -z 128 128 "$<" --out "$(ICONSET)/icon_128x128.png" >/dev/null
	@sips -z 256 256 "$<" --out "$(ICONSET)/icon_128x128@2x.png" >/dev/null
	@sips -z 256 256 "$<" --out "$(ICONSET)/icon_256x256.png" >/dev/null
	@sips -z 512 512 "$<" --out "$(ICONSET)/icon_256x256@2x.png" >/dev/null
	@sips -z 512 512 "$<" --out "$(ICONSET)/icon_512x512.png" >/dev/null
	@sips -z 1024 1024 "$<" --out "$(ICONSET)/icon_512x512@2x.png" >/dev/null
	@printf '{\n  "images" : [\n    { "idiom" : "mac", "size" : "16x16", "filename" : "icon_16x16.png", "scale" : "1x" },\n    { "idiom" : "mac", "size" : "16x16", "filename" : "icon_16x16@2x.png", "scale" : "2x" },\n    { "idiom" : "mac", "size" : "32x32", "filename" : "icon_32x32.png", "scale" : "1x" },\n    { "idiom" : "mac", "size" : "32x32", "filename" : "icon_32x32@2x.png", "scale" : "2x" },\n    { "idiom" : "mac", "size" : "64x64", "filename" : "icon_64x64.png", "scale" : "1x" },\n    { "idiom" : "mac", "size" : "64x64", "filename" : "icon_64x64@2x.png", "scale" : "2x" },\n    { "idiom" : "mac", "size" : "128x128", "filename" : "icon_128x128.png", "scale" : "1x" },\n    { "idiom" : "mac", "size" : "128x128", "filename" : "icon_128x128@2x.png", "scale" : "2x" },\n    { "idiom" : "mac", "size" : "256x256", "filename" : "icon_256x256.png", "scale" : "1x" },\n    { "idiom" : "mac", "size" : "256x256", "filename" : "icon_256x256@2x.png", "scale" : "2x" },\n    { "idiom" : "mac", "size" : "512x512", "filename" : "icon_512x512.png", "scale" : "1x" },\n    { "idiom" : "mac", "size" : "512x512", "filename" : "icon_512x512@2x.png", "scale" : "2x" }\n  ],\n  "info" : { "version" : 1, "author" : "xcode" }\n}\n' > "$(ICONSET)/Contents.json"
	@printf '%s\n' \
	'import struct' \
	'from pathlib import Path' \
	'' \
	'iconset = Path("$(ICONSET)")' \
	'entries = [' \
	'    ("icp4", "icon_16x16.png"),' \
	'    ("icp5", "icon_32x32.png"),' \
	'    ("icp6", "icon_64x64.png"),' \
	'    ("ic07", "icon_128x128.png"),' \
	'    ("ic11", "icon_32x32@2x.png"),' \
	'    ("ic12", "icon_64x64@2x.png"),' \
	'    ("ic08", "icon_256x256.png"),' \
	'    ("ic13", "icon_256x256@2x.png"),' \
	'    ("ic09", "icon_512x512.png"),' \
	'    ("ic10", "icon_512x512@2x.png"),' \
	'    ("ic14", "icon_512x512@2x.png"),' \
	']' \
	'' \
	'chunks = []' \
	'total = 8' \
	'for typ, name in entries:' \
	'    data = (iconset / name).read_bytes()' \
	'    chunk = typ.encode("ascii") + struct.pack(">I", len(data) + 8) + data' \
	'    chunks.append(chunk)' \
	'    total += len(chunk)' \
	'' \
	'Path("$(APP_ICON)").write_bytes(' \
	'    b"icns" + struct.pack(">I", total) + b"".join(chunks)' \
	')' \
	> "$(ICON_SCRIPT)"
	@python3 "$(ICON_SCRIPT)"
	@rm -f "$(ICON_SCRIPT)"
	@rm -rf "$(ICONSET)"
