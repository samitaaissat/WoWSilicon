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

.PHONY: all build debug run bundle fetch-runtime dmg appcast clean app_icon

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

bundle: build fetch-runtime
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
	@echo "Bundling Wine runtime v$(RUNTIME_VERSION)..."
	@mkdir -p "$(APP_BUNDLE)/Contents/SharedSupport"
	@# ditto (not cp -R): staging must preserve the tarball's file mtimes.
	@# wine stamps prefixes with wine.inf's mtime and re-runs the full prefix
	@# update on any mismatch — cp -R restamps mtimes at build time, which made
	@# every app build (even of the same runtime) force a prefix refresh.
	@ditto "$(RUNTIME_CACHE)/$(RUNTIME_VERSION)/wine" "$(APP_BUNDLE)/Contents/SharedSupport/wine"
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
