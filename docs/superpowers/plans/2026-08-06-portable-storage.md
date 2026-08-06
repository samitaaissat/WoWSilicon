# Portable Storage ("WoWSilicon Data") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** All mutable state (dedicated Wine prefix + versions.json + prefs.json) lives in a `WoWSilicon Data` folder beside `WoWSilicon.app`, with a silent Application Support fallback, so the app is fully portable and stops touching the shared global `~/.wine`.

**Architecture:** A new `PortableStorage` service resolves the storage root positionally at startup (nothing persisted); a new `PrefixBootstrapService` initializes the dedicated prefix explicitly with a sentinel file; `WineRegistrySupport.winePrefixURL()` is the single choke point that retargets all registry/dependency services; `LaunchService`/`PatchService`/`VanillaTweaksService` gain explicit `WINEPREFIX` pinning. Spec: `docs/superpowers/specs/2026-08-06-portable-storage-design.md`.

**Tech Stack:** Swift 6, SwiftPM, XCTest (real filesystem in per-test temp dirs, no mocking), macOS 15 (effective floor).

## Global Constraints

- Data folder name: `WoWSilicon Data` (with space). Prefix subdirectory: `prefix`. About file: `About this folder.txt`. Sentinel file: `.wowsilicon-prefix-ok`. Write-probe file prefix: `.ws-write-probe-`.
- Fallback root: `~/Library/Application Support/WoWSilicon` (the existing directory); fallback prefix at `.../WoWSilicon/prefix`.
- `~/.wine` must never be read, seeded from, or deleted — except by the explicit `deleteLegacyPrefixes` troubleshooting action (Task 11).
- Services: `final class`, `@unchecked Sendable`, injectable `init` with production defaults + `static let shared` (the `WineRuntime` pattern). Errors: typed `LocalizedError` enums with user-facing `errorDescription`.
- Tests: `@testable import WoWSiliconSwift`, per-test temp dirs created in `setUp`/helpers and removed in `tearDownWithError`, **never** resolve against the real home or real Application Support (always inject `bundleURL`/`fallbackSupportRoot`/`configDirectory`). Never use `PortableStorage.shared` in tests.
- Build/test commands: `swift build` and `swift test` (run from the repo root `/Users/sami.taaissat/Documents/Perso/WoWSilicon`).
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Migration latch: `<Data root>/versions.json` exists ⇒ import never runs again. Data wins when both locations have content. Byte-copy only (`FileManager.copyItem`), never decode→re-encode.

---

### Task 1: PortableStorage resolver

**Files:**
- Create: `Sources/WoWSiliconSwift/Services/PortableStorage.swift`
- Test: `Tests/WoWSiliconSwiftTests/PortableStorageResolverTests.swift`

**Interfaces:**
- Consumes: nothing new (Foundation only).
- Produces (later tasks rely on these exact names):
  - `final class PortableStorage: @unchecked Sendable`
  - `init(bundleURL: URL = Bundle.main.bundleURL, fallbackSupportRoot: URL? = nil, fileManager: FileManager = .default)`
  - `static let shared: PortableStorage`
  - `enum Location: Equatable, Sendable { case besideApp(URL); case applicationSupport(URL) }`
  - `enum Reason: String, Sendable { case existingDataFolder, createdBesideApp, translocated, blockedByFile, parentNotWritable, readOnlyVolume, creationFailed }`
  - `let location: Location`, `let reason: Reason`, `let prefixURL: URL`, `let legacySupportDirectory: URL`
  - `var dataRootURL: URL`, `var configDirectory: URL` (== dataRootURL), `var isPortable: Bool`, `var isPrefixSplit: Bool`, `var displayDescription: String`
  - `static func isWritableByProbe(directory: URL, fileManager: FileManager) -> Bool`
  - `static func volumeCanHostPrefix(at directory: URL, fileManager: FileManager) -> Bool`
  - `static let dataFolderName = "WoWSilicon Data"`, `static let aboutFileName = "About this folder.txt"`

- [ ] **Step 1: Write the failing tests**

Create `Tests/WoWSiliconSwiftTests/PortableStorageResolverTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class PortableStorageResolverTests: XCTestCase {
    private var tempURLs: [URL] = []
    private var chmodRestoreURLs: [URL] = []

    override func tearDownWithError() throws {
        // Restore permissions BEFORE removal, or removeItem fails on 0o555 dirs.
        for url in chmodRestoreURLs {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        chmodRestoreURLs.removeAll()
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    /// (parent, bundleURL, fallbackRoot) — the standard fixture.
    private func makeFixture() throws -> (parent: URL, bundleURL: URL, fallback: URL) {
        let parent = try makeTemporaryDirectory()
        let bundleURL = parent.appendingPathComponent("WoWSilicon.app", isDirectory: true)
        let fallback = try makeTemporaryDirectory()
        return (parent, bundleURL, fallback)
    }

    func testCreatesDataFolderBesideAppWhenParentIsWritable() throws {
        let f = try makeFixture()

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        let expectedRoot = f.parent.appendingPathComponent("WoWSilicon Data", isDirectory: true)
        XCTAssertEqual(storage.location, .besideApp(expectedRoot))
        XCTAssertEqual(storage.reason, .createdBesideApp)
        XCTAssertTrue(storage.isPortable)
        XCTAssertEqual(storage.dataRootURL, expectedRoot)
        XCTAssertEqual(storage.configDirectory, expectedRoot)
        XCTAssertEqual(storage.prefixURL, expectedRoot.appendingPathComponent("prefix", isDirectory: true))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedRoot.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        // README is written at creation time.
        let about = expectedRoot.appendingPathComponent("About this folder.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: about.path))
        // No probe litter left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: expectedRoot.path)
            .filter { $0.hasPrefix(".ws-write-probe-") || $0.hasPrefix(".ws-prefix-probe-") }
        XCTAssertEqual(leftovers, [])
    }

    func testExistingDataFolderWins() throws {
        let f = try makeFixture()
        let existing = f.parent.appendingPathComponent("WoWSilicon Data", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("versions.json")
        try "{}".write(to: marker, atomically: true, encoding: .utf8)

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(storage.location, .besideApp(existing))
        XCTAssertEqual(storage.reason, .existingDataFolder)
        // Existing folder contents are untouched (no About file injected).
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "{}")
    }

    func testReadOnlyParentFallsBackToApplicationSupport() throws {
        let f = try makeFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.parent.path)
        chmodRestoreURLs.append(f.parent)
        try XCTSkipIf(geteuid() == 0, "permissions are not enforced for root")

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        let expectedRoot = f.fallback.appendingPathComponent("WoWSilicon", isDirectory: true)
        XCTAssertEqual(storage.location, .applicationSupport(expectedRoot))
        XCTAssertFalse(storage.isPortable)
        XCTAssertEqual(storage.prefixURL, expectedRoot.appendingPathComponent("prefix", isDirectory: true))
        XCTAssertTrue([.creationFailed, .parentNotWritable].contains(storage.reason))
    }

    func testTranslocatedBundleURLFallsBackWithoutTouchingParent() throws {
        let f = try makeFixture()
        // Simulated translocation mount: the stable "AppTranslocation" component is
        // what production paths contain; the parent is deliberately WRITABLE to
        // prove the check short-circuits before any probe/creation.
        let translocated = f.parent
            .appendingPathComponent("AppTranslocation", isDirectory: true)
            .appendingPathComponent("A1B2C3D4-0000-0000-0000-000000000000", isDirectory: true)
            .appendingPathComponent("d", isDirectory: true)
            .appendingPathComponent("WoWSilicon.app", isDirectory: true)
        try FileManager.default.createDirectory(at: translocated.deletingLastPathComponent(), withIntermediateDirectories: true)

        let storage = PortableStorage(bundleURL: translocated, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(storage.reason, .translocated)
        XCTAssertFalse(storage.isPortable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: translocated.deletingLastPathComponent().appendingPathComponent("WoWSilicon Data").path))
    }

    func testPlainFileNamedLikeDataFolderFallsBack() throws {
        let f = try makeFixture()
        let blocker = f.parent.appendingPathComponent("WoWSilicon Data")
        try "not a folder".write(to: blocker, atomically: true, encoding: .utf8)

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(storage.reason, .blockedByFile)
        XCTAssertFalse(storage.isPortable)
        // The blocking file is preserved, not deleted.
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "not a folder")
    }

    func testResolutionIsIdempotentAcrossInstances() throws {
        let f = try makeFixture()

        let first = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)
        let second = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(first.location, second.location)
        XCTAssertEqual(second.reason, .existingDataFolder)
        XCTAssertEqual(first.prefixURL, second.prefixURL)
    }

    func testCloudSyncedDataRootSplitsPrefixToFallback() throws {
        let parent = try makeTemporaryDirectory()
        // Simulate an iCloud Drive location by path shape — the check is on path
        // containment, which is exactly what production uses.
        let cloudParent = parent
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudParent, withIntermediateDirectories: true)
        let bundleURL = cloudParent.appendingPathComponent("WoWSilicon.app", isDirectory: true)
        let fallback = try makeTemporaryDirectory()

        let storage = PortableStorage(bundleURL: bundleURL, fallbackSupportRoot: fallback)

        XCTAssertTrue(storage.isPortable, "config stays portable on a cloud volume")
        XCTAssertTrue(storage.isPrefixSplit)
        XCTAssertEqual(
            storage.prefixURL,
            fallback.appendingPathComponent("WoWSilicon", isDirectory: true)
                .appendingPathComponent("prefix", isDirectory: true)
        )
    }

    func testWriteProbeReportsReadOnlyDirectory() throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        chmodRestoreURLs.append(dir)
        try XCTSkipIf(geteuid() == 0, "permissions are not enforced for root")

        XCTAssertFalse(PortableStorage.isWritableByProbe(directory: dir, fileManager: .default))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertTrue(PortableStorage.isWritableByProbe(directory: dir, fileManager: .default))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PortableStorageResolverTests`
Expected: compile FAILURE — `cannot find 'PortableStorage' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/WoWSiliconSwift/Services/PortableStorage.swift`:

```swift
import Foundation

/// Single authority for where WoWSilicon's mutable state lives: the config
/// files (versions.json / prefs.json) and the dedicated Wine prefix.
///
/// Resolution is positional and runs once per instance — nothing about the
/// location is ever persisted, so moving the app and relaunching self-heals.
/// Portable mode uses a "WoWSilicon Data" folder beside the .app; when the
/// app's location is read-only (DMG, App Translocation, non-admin
/// /Applications) it falls back to ~/Library/Application Support/WoWSilicon,
/// which is a normal steady state, not an error.
final class PortableStorage: @unchecked Sendable {
    enum Location: Equatable, Sendable {
        case besideApp(URL)
        case applicationSupport(URL)
    }

    enum Reason: String, Sendable {
        case existingDataFolder
        case createdBesideApp
        case translocated
        case blockedByFile
        case parentNotWritable
        case readOnlyVolume
        case creationFailed
    }

    static let shared = PortableStorage()

    static let dataFolderName = "WoWSilicon Data"
    static let aboutFileName = "About this folder.txt"
    static let aboutFileContents = """
    This folder holds all of WoWSilicon's data: your settings and the Wine
    environment the game runs in.

    Keep it next to WoWSilicon.app. Copy both together to move your whole
    installation to another folder, disk, or Mac.

    Deleting this folder resets WoWSilicon completely.
    """

    let location: Location
    let reason: Reason
    /// The dedicated Wine prefix. Usually <data root>/prefix; on a volume that
    /// cannot host a prefix (cloud-synced, no symlinks) it splits to the
    /// Application Support root while the config stays portable.
    let prefixURL: URL
    /// ~/Library/Application Support/WoWSilicon (or the injected equivalent) —
    /// the source for first-run import and fallback-prefix adoption.
    let legacySupportDirectory: URL

    private let fileManager: FileManager

    init(bundleURL: URL = Bundle.main.bundleURL,
         fallbackSupportRoot: URL? = nil,
         fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let supportBase = fallbackSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let fallbackRoot = supportBase.appendingPathComponent("WoWSilicon", isDirectory: true)
        self.legacySupportDirectory = fallbackRoot

        let (location, reason) = Self.resolve(
            bundleURL: bundleURL, fallbackRoot: fallbackRoot, fileManager: fileManager)
        self.location = location
        self.reason = reason

        if case .besideApp(let dataRoot) = location,
           !Self.volumeCanHostPrefix(at: dataRoot, fileManager: fileManager) {
            self.prefixURL = fallbackRoot.appendingPathComponent("prefix", isDirectory: true)
        } else {
            let root: URL
            switch location {
            case .besideApp(let url): root = url
            case .applicationSupport(let url): root = url
            }
            self.prefixURL = root.appendingPathComponent("prefix", isDirectory: true)
        }
    }

    var dataRootURL: URL {
        switch location {
        case .besideApp(let url): return url
        case .applicationSupport(let url): return url
        }
    }

    /// Directory holding versions.json / version_manager.json / prefs.json.
    var configDirectory: URL { dataRootURL }

    var isPortable: Bool {
        if case .besideApp = location { return true }
        return false
    }

    /// True when the config is portable but the prefix had to fall back.
    var isPrefixSplit: Bool {
        isPortable && !prefixURL.path.hasPrefix(dataRootURL.path)
    }

    var displayDescription: String {
        switch location {
        case .besideApp(let url):
            var text = "Portable — \(url.path)"
            if isPrefixSplit {
                text += " (Wine prefix in Application Support — this volume can't host one)"
            }
            return text
        case .applicationSupport(let url):
            switch reason {
            case .translocated:
                return "Application Support (fallback — running from a quarantined location; move the app and relaunch) — \(url.path)"
            case .readOnlyVolume:
                return "Application Support (fallback — running from a disk image or read-only volume; drag WoWSilicon to Applications) — \(url.path)"
            case .blockedByFile:
                return "Application Support (fallback — a file named '\(Self.dataFolderName)' sits beside the app) — \(url.path)"
            default:
                return "Application Support (fallback — the app's folder is not writable) — \(url.path)"
            }
        }
    }

    // MARK: - Resolution

    private static func resolve(bundleURL: URL, fallbackRoot: URL,
                                fileManager: FileManager) -> (Location, Reason) {
        let appURL = bundleURL.resolvingSymlinksInPath()

        if appURL.pathComponents.contains("AppTranslocation") {
            return (.applicationSupport(fallbackRoot), .translocated)
        }

        let dataURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(dataFolderName, isDirectory: true)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dataURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return (.applicationSupport(fallbackRoot), .blockedByFile)
            }
            guard isWritableByProbe(directory: dataURL, fileManager: fileManager) else {
                return (.applicationSupport(fallbackRoot), .parentNotWritable)
            }
            return (.besideApp(dataURL), .existingDataFolder)
        }

        do {
            try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: false)
        } catch {
            let nsError = error as NSError
            let posixCode = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? nsError.code
            let isReadOnly = nsError.code == NSFileWriteVolumeReadOnlyError || posixCode == Int(EROFS)
            return (.applicationSupport(fallbackRoot), isReadOnly ? .readOnlyVolume : .creationFailed)
        }
        guard isWritableByProbe(directory: dataURL, fileManager: fileManager) else {
            return (.applicationSupport(fallbackRoot), .parentNotWritable)
        }
        let aboutURL = dataURL.appendingPathComponent(aboutFileName)
        try? aboutFileContents.write(to: aboutURL, atomically: true, encoding: .utf8)
        return (.besideApp(dataURL), .createdBesideApp)
    }

    /// The only trustworthy writability test is a real write.
    /// FileManager.isWritableFile(atPath:) is advisory and lies on ACLs,
    /// network mounts, and TCC-protected folders.
    static func isWritableByProbe(directory: URL, fileManager: FileManager) -> Bool {
        let probeURL = directory.appendingPathComponent(".ws-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probeURL)
            try fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    /// A Wine prefix needs symlinks named like "c:", stable local storage, and
    /// current-user ownership (wineserver refuses foreign-owned prefixes).
    /// Cloud-synced folders pass the syscalls but corrupt prefixes via
    /// eviction, so they are rejected by path shape.
    static func volumeCanHostPrefix(at directory: URL, fileManager: FileManager) -> Bool {
        let path = directory.path
        if path.contains("/Library/Mobile Documents") || path.contains("/Library/CloudStorage") {
            return false
        }
        if let values = try? directory.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey]),
           values.volumeSupportsSymbolicLinks == false {
            return false
        }
        let probeDir = directory.appendingPathComponent(".ws-prefix-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: probeDir) }
        do {
            try fileManager.createDirectory(at: probeDir, withIntermediateDirectories: false)
            let link = probeDir.appendingPathComponent("c:")
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "../drive_c")
            guard try fileManager.destinationOfSymbolicLink(atPath: link.path) == "../drive_c" else {
                return false
            }
            var status = stat()
            guard lstat(probeDir.path, &status) == 0, status.st_uid == getuid() else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PortableStorageResolverTests`
Expected: 8 tests PASS.

- [ ] **Step 5: Run the full suite and commit**

Run: `swift test`
Expected: PASS (no existing behavior touched).

```bash
git add Sources/WoWSiliconSwift/Services/PortableStorage.swift Tests/WoWSiliconSwiftTests/PortableStorageResolverTests.swift
git commit -m "feat: add PortableStorage resolver for beside-the-app data folder

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: UserPrefsStore injection

**Files:**
- Modify: `Sources/WoWSiliconSwift/Stores/UserPrefsStore.swift` (whole file is 53 lines)
- Test: `Tests/WoWSiliconSwiftTests/UserPrefsStoreTests.swift` (new)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `UserPrefsStore.init(fileManager: FileManager = .default, configDirectory: URL? = nil)`. `nil` keeps today's behavior (`App Support/WoWSilicon/prefs.json`); non-nil reads/writes `<configDirectory>/prefs.json`. Task 12 constructs it with `configDirectory: storage.configDirectory`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/WoWSiliconSwiftTests/UserPrefsStoreTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class UserPrefsStoreTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    func testSaveAndLoadRoundTripsThroughInjectedConfigDirectory() throws {
        let configDir = try makeTemporaryDirectory()
        let store = UserPrefsStore(configDirectory: configDir)

        var prefs = UserPrefs.defaults
        prefs.telemetryEnabled = true
        store.save(prefs)

        XCTAssertTrue(FileManager.default.fileExists(atPath: configDir.appendingPathComponent("prefs.json").path))
        let loaded = UserPrefsStore(configDirectory: configDir).load()
        XCTAssertTrue(loaded.telemetryEnabled)
    }

    func testLoadReturnsDefaultsWhenFileMissing() throws {
        let configDir = try makeTemporaryDirectory()
        let loaded = UserPrefsStore(configDirectory: configDir).load()
        XCTAssertEqual(loaded, UserPrefs.defaults)
    }

    func testLoadReturnsDefaultsWhenFileCorrupt() throws {
        let configDir = try makeTemporaryDirectory()
        try "{ not json".write(to: configDir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)
        let loaded = UserPrefsStore(configDirectory: configDir).load()
        XCTAssertEqual(loaded, UserPrefs.defaults)
    }
}
```

Note: `UserPrefs` is Codable+Equatable per the models convention; if `telemetryEnabled` is not a settable var on `UserPrefs`, check `Sources/WoWSiliconSwift/Models/UserPrefs.swift` and use whichever mutable Bool field exists (e.g. `autoDeleteWdb`) — the test's purpose is the round-trip, not that specific field.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UserPrefsStoreTests`
Expected: compile FAILURE — `extra argument 'configDirectory' in call`.

- [ ] **Step 3: Implement the injection**

Replace the property/init/path sections of `Sources/WoWSiliconSwift/Stores/UserPrefsStore.swift` (keep `load()`/`save(_:)` bodies as they are):

```swift
struct UserPrefsStore {
    private let fileManager: FileManager
    private let configDirectory: URL?
    private let directoryName = "WoWSilicon"
    private let fileName = "prefs.json"

    init(fileManager: FileManager = .default, configDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.configDirectory = configDirectory
    }

    // load() and save(_:) unchanged.

    private func prefsFileURL() -> URL? {
        if let configDirectory {
            return configDirectory.appendingPathComponent(fileName, isDirectory: false)
        }
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
```

(The current file uses `private let fileManager = FileManager.default`; that line is replaced by the injected property.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UserPrefsStoreTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/WoWSiliconSwift/Stores/UserPrefsStore.swift Tests/WoWSiliconSwiftTests/UserPrefsStoreTests.swift
git commit -m "feat: inject config directory into UserPrefsStore

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: VersionStore resolved config directory

**Files:**
- Modify: `Sources/WoWSiliconSwift/Stores/VersionStore.swift:10-24, 89-105`
- Modify: `Tests/WoWSiliconSwiftTests/VersionStoreTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `VersionStore.init(fileManager: FileManager = .default, configDirectory: URL? = nil)`. The old `supportDirectory:` parameter is **removed** (its only users are the tests updated here). `nil` keeps today's behavior; non-nil reads/writes `<configDirectory>/versions.json` and `<configDirectory>/version_manager.json`. Task 12 constructs it with `configDirectory: storage.configDirectory`.

- [ ] **Step 1: Update the tests to the new shape (failing first)**

In `Tests/WoWSiliconSwiftTests/VersionStoreTests.swift`:

1. `testSaveAndLoadRoundTripsCustomProfileAndDefaults` (line 17): change
   `let store = VersionStore(supportDirectory: supportURL)` →
   `let store = VersionStore(configDirectory: supportURL)`.
2. `testLoadFallsBackToDefaultsWhenVersionsFileIsInvalid` (lines 48-53): change
   `let versionsURL = supportURL.appendingPathComponent("WoWSilicon/versions.json")` →
   `let versionsURL = supportURL.appendingPathComponent("versions.json")`
   and `VersionStore(supportDirectory: supportURL)` → `VersionStore(configDirectory: supportURL)`.
   (The `createDirectory` line can stay — creating an existing directory's parent is harmless — but the cleaner edit is to delete it since `versionsURL.deletingLastPathComponent()` is now `supportURL`, which already exists.)
3. `testLoadMergesLegacyVersionManagerWhenNewStoreHasNoPaths` (lines 62-83): change
   `supportURL.appendingPathComponent("WoWSilicon/version_manager.json")` →
   `supportURL.appendingPathComponent("version_manager.json")`
   and `VersionStore(supportDirectory: supportURL)` → `VersionStore(configDirectory: supportURL)`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VersionStoreTests`
Expected: compile FAILURE — `extra argument 'configDirectory'` / no member `supportDirectory`.

- [ ] **Step 3: Implement**

In `Sources/WoWSiliconSwift/Stores/VersionStore.swift`, replace lines 10-18 (properties + init):

```swift
    private let fileManager: FileManager
    private let configDirectory: URL?
    private let directoryName = "WoWSilicon"
    private let fileName = "versions.json"

    init(fileManager: FileManager = .default, configDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.configDirectory = configDirectory
    }
```

Replace `versionsFileURL()` and `legacyVersionsFileURL()` (lines 89-105):

```swift
    private func resolvedConfigDirectory() -> URL? {
        if let configDirectory {
            return configDirectory
        }
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return supportDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    private func versionsFileURL() -> URL? {
        resolvedConfigDirectory()?.appendingPathComponent(fileName, isDirectory: false)
    }

    private func legacyVersionsFileURL() -> URL? {
        resolvedConfigDirectory()?.appendingPathComponent("version_manager.json", isDirectory: false)
    }
```

Reword the warning at line 24:
`"Failed to resolve Application Support directory. Using defaults."` →
`"Failed to resolve the configuration directory. Using defaults."`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VersionStoreTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/WoWSiliconSwift/Stores/VersionStore.swift Tests/WoWSiliconSwiftTests/VersionStoreTests.swift
git commit -m "feat: VersionStore takes a fully-resolved config directory

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: First-run config import + MigrationService injectable root

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PortableStorage.swift` (add one method)
- Modify: `Sources/WoWSiliconSwift/Services/MigrationService.swift`
- Test: `Tests/WoWSiliconSwiftTests/StorageMigrationTests.swift` (new)

**Interfaces:**
- Consumes: `PortableStorage` (Task 1), `legacySupportDirectory` property.
- Produces:
  - `PortableStorage.performFirstRunImportIfNeeded()` — byte-copies `version_manager.json`, `prefs.json`, then `versions.json` (that order — the latch file is copied last so an interrupted import never latches early) from `legacySupportDirectory` into `configDirectory`. No-ops when not portable or when `<configDirectory>/versions.json` already exists.
  - `MigrationService.legacyDirectoryExists(supportRoot: URL? = nil) -> Bool` and `MigrationService.migrate(supportRoot: URL? = nil) throws` — same behavior, injectable base for tests. Existing no-argument call sites keep compiling.

- [ ] **Step 1: Write the failing tests**

Create `Tests/WoWSiliconSwiftTests/StorageMigrationTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class StorageMigrationTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    /// Portable storage instance whose fallback/legacy dir is a temp dir.
    private func makePortableStorage() throws -> (storage: PortableStorage, legacyDir: URL) {
        let parent = try makeTemporaryDirectory()
        let fallback = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: fallback
        )
        XCTAssertTrue(storage.isPortable)
        let legacyDir = storage.legacySupportDirectory
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        return (storage, legacyDir)
    }

    func testFirstRunImportCopiesConfigLeavingOriginalsIntact() throws {
        let (storage, legacyDir) = try makePortableStorage()
        try #"{"marker":"versions"}"#.write(to: legacyDir.appendingPathComponent("versions.json"), atomically: true, encoding: .utf8)
        try #"{"marker":"prefs"}"#.write(to: legacyDir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)
        try #"{"marker":"legacy"}"#.write(to: legacyDir.appendingPathComponent("version_manager.json"), atomically: true, encoding: .utf8)

        storage.performFirstRunImportIfNeeded()

        // Byte-copied, originals intact.
        for name in ["versions.json", "prefs.json", "version_manager.json"] {
            let copied = storage.configDirectory.appendingPathComponent(name)
            let original = legacyDir.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: original), name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), name)
        }
    }

    func testImportNoOpsWhenNothingToImport() throws {
        let (storage, _) = try makePortableStorage()
        storage.performFirstRunImportIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.configDirectory.appendingPathComponent("versions.json").path))
    }

    func testDataFolderContentWinsAndIsNeverOverwritten() throws {
        let (storage, legacyDir) = try makePortableStorage()
        try #"{"marker":"stale-app-support"}"#.write(to: legacyDir.appendingPathComponent("versions.json"), atomically: true, encoding: .utf8)
        try #"{"marker":"stale-prefs"}"#.write(to: legacyDir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)
        let liveVersions = storage.configDirectory.appendingPathComponent("versions.json")
        try #"{"marker":"live-portable"}"#.write(to: liveVersions, atomically: true, encoding: .utf8)

        storage.performFirstRunImportIfNeeded()

        // versions.json existing = the latch: nothing is imported at all.
        XCTAssertEqual(try String(contentsOf: liveVersions, encoding: .utf8), #"{"marker":"live-portable"}"#)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.configDirectory.appendingPathComponent("prefs.json").path))
    }

    func testImportNoOpsInFallbackMode() throws {
        let parent = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        try XCTSkipIf(geteuid() == 0, "permissions are not enforced for root")
        let fallback = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: fallback
        )
        XCTAssertFalse(storage.isPortable)

        storage.performFirstRunImportIfNeeded()
        // In fallback mode config dir == legacy dir; nothing to do, nothing created.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.configDirectory.appendingPathComponent("versions.json").path))
    }

    func testTurtleSiliconChainEndToEnd() throws {
        // TurtleSilicon dir -> MigrationService.migrate -> portable import -> VersionStore legacy merge.
        let supportRoot = try makeTemporaryDirectory()
        let turtleDir = supportRoot.appendingPathComponent("TurtleSilicon", isDirectory: true)
        try FileManager.default.createDirectory(at: turtleDir, withIntermediateDirectories: true)
        try """
        {
          "current_version_id": "wrathsilicon",
          "versions": {
            "wrathsilicon": { "game_path": "/Games/Wrath", "settings": { "enable_metal_hud": true } }
          }
        }
        """.write(to: turtleDir.appendingPathComponent("version_manager.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(MigrationService.legacyDirectoryExists(supportRoot: supportRoot))
        try MigrationService.migrate(supportRoot: supportRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: turtleDir.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: supportRoot.appendingPathComponent("WoWSilicon/version_manager.json").path))

        // Portable import picks the migrated files up.
        let parent = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: supportRoot
        )
        storage.performFirstRunImportIfNeeded()

        let result = VersionStore(configDirectory: storage.configDirectory).loadVersionManager()
        XCTAssertEqual(result.manager.versions["wrathsilicon"]?.gamePath, "/Games/Wrath")
    }

    func testTurtleSiliconMergeIntoExistingWoWSiliconDirectory() throws {
        let supportRoot = try makeTemporaryDirectory()
        let turtleDir = supportRoot.appendingPathComponent("TurtleSilicon", isDirectory: true)
        let wowDir = supportRoot.appendingPathComponent("WoWSilicon", isDirectory: true)
        try FileManager.default.createDirectory(at: turtleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wowDir, withIntermediateDirectories: true)
        try "turtle".write(to: turtleDir.appendingPathComponent("version_manager.json"), atomically: true, encoding: .utf8)
        try "existing".write(to: wowDir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)

        try MigrationService.migrate(supportRoot: supportRoot)

        // Legacy file moved in; pre-existing destination files preserved.
        XCTAssertEqual(try String(contentsOf: wowDir.appendingPathComponent("version_manager.json"), encoding: .utf8), "turtle")
        XCTAssertEqual(try String(contentsOf: wowDir.appendingPathComponent("prefs.json"), encoding: .utf8), "existing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: turtleDir.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StorageMigrationTests`
Expected: compile FAILURE — no `performFirstRunImportIfNeeded`, `migrate(supportRoot:)`.

- [ ] **Step 3: Implement**

Add to `PortableStorage` (below `displayDescription`):

```swift
    // MARK: - First-run import

    /// Byte-copies existing config from ~/Library/Application Support/WoWSilicon
    /// into a fresh portable Data folder. Latch: once versions.json exists in
    /// the Data root, the Data root is authoritative forever and the import
    /// never runs again. Copy — never move — so Application Support stays
    /// intact as a rollback net. Never decode/re-encode: re-encoding would
    /// drop unknown legacy keys.
    func performFirstRunImportIfNeeded() {
        guard isPortable else { return }
        let latchURL = configDirectory.appendingPathComponent("versions.json")
        guard !fileManager.fileExists(atPath: latchURL.path) else { return }

        // versions.json is copied LAST: it is the latch, and an interrupted
        // import must not latch before the other files made it across.
        for name in ["version_manager.json", "prefs.json", "versions.json"] {
            let source = legacySupportDirectory.appendingPathComponent(name)
            let destination = configDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }
```

In `Sources/WoWSiliconSwift/Services/MigrationService.swift`, thread the root through (keep behavior identical):

```swift
    static func legacyDirectoryExists(supportRoot: URL? = nil) -> Bool {
        guard let support = supportRoot ?? applicationSupportURL() else { return false }
        let legacy = support.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        return FileManager.default.fileExists(atPath: legacy.path)
    }

    static func migrate(supportRoot: URL? = nil) throws {
        guard let support = supportRoot ?? applicationSupportURL() else {
            throw MigrationError.unableToLocateSupportDirectory
        }
        // ... rest of the existing body unchanged (it already works from `support`).
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StorageMigrationTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/WoWSiliconSwift/Services/PortableStorage.swift Sources/WoWSiliconSwift/Services/MigrationService.swift Tests/WoWSiliconSwiftTests/StorageMigrationTests.swift
git commit -m "feat: first-run config import into the portable Data folder

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Fallback-prefix adoption

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PortableStorage.swift` (add adoption methods)
- Test: `Tests/WoWSiliconSwiftTests/PortableStorageAdoptionTests.swift` (new)

**Interfaces:**
- Consumes: `PortableStorage` (Tasks 1/4).
- Produces: `PortableStorage.adoptFallbackPrefixIfNeeded(isPrefixBusy: () -> Bool = PortableStorage.isBundledWineserverRunning)` — moves `<legacySupportDirectory>/prefix` into `prefixURL` when running portable. `static func isBundledWineserverRunning() -> Bool` (pgrep on the bundled wineserver path). Task 12 calls `adoptFallbackPrefixIfNeeded()` right after `performFirstRunImportIfNeeded()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/WoWSiliconSwiftTests/PortableStorageAdoptionTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class PortableStorageAdoptionTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    /// Builds a fake wine prefix with the pieces adoption cares about.
    private func makeFakePrefix(at prefix: URL, cSymlinkTarget: String) throws {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c", isDirectory: true), withIntermediateDirectories: true)
        try "REG".write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: dosdevices.appendingPathComponent("c:").path,
            withDestinationPath: cSymlinkTarget
        )
    }

    private func makePortableStorage() throws -> PortableStorage {
        let parent = try makeTemporaryDirectory()
        let fallback = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: fallback
        )
        XCTAssertTrue(storage.isPortable)
        return storage
    }

    func testAdoptionMovesFallbackPrefixIntoDataFolder() throws {
        let storage = try makePortableStorage()
        let fallbackPrefix = storage.legacySupportDirectory.appendingPathComponent("prefix", isDirectory: true)
        try makeFakePrefix(at: fallbackPrefix, cSymlinkTarget: "../drive_c")

        storage.adoptFallbackPrefixIfNeeded(isPrefixBusy: { false })

        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackPrefix.path), "moved, not copied")
        XCTAssertEqual(
            try String(contentsOf: storage.prefixURL.appendingPathComponent("user.reg"), encoding: .utf8),
            "REG"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: storage.prefixURL.appendingPathComponent("dosdevices/c:").path),
            "../drive_c"
        )
    }

    func testAdoptionRewritesAbsoluteCDriveSymlink() throws {
        let storage = try makePortableStorage()
        let fallbackPrefix = storage.legacySupportDirectory.appendingPathComponent("prefix", isDirectory: true)
        try makeFakePrefix(at: fallbackPrefix, cSymlinkTarget: fallbackPrefix.appendingPathComponent("drive_c").path)

        storage.adoptFallbackPrefixIfNeeded(isPrefixBusy: { false })

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: storage.prefixURL.appendingPathComponent("dosdevices/c:").path),
            "../drive_c"
        )
    }

    func testAdoptionNeverOverwritesExistingDataPrefix() throws {
        let storage = try makePortableStorage()
        let fallbackPrefix = storage.legacySupportDirectory.appendingPathComponent("prefix", isDirectory: true)
        try makeFakePrefix(at: fallbackPrefix, cSymlinkTarget: "../drive_c")
        try FileManager.default.createDirectory(at: storage.prefixURL, withIntermediateDirectories: true)
        try "LIVE".write(to: storage.prefixURL.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        storage.adoptFallbackPrefixIfNeeded(isPrefixBusy: { false })

        XCTAssertEqual(
            try String(contentsOf: storage.prefixURL.appendingPathComponent("user.reg"), encoding: .utf8),
            "LIVE"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackPrefix.path), "source left in place")
    }

    func testBusyPrefixSkipsAdoptionThisSession() throws {
        let storage = try makePortableStorage()
        let fallbackPrefix = storage.legacySupportDirectory.appendingPathComponent("prefix", isDirectory: true)
        try makeFakePrefix(at: fallbackPrefix, cSymlinkTarget: "../drive_c")

        storage.adoptFallbackPrefixIfNeeded(isPrefixBusy: { true })

        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackPrefix.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.prefixURL.path))
    }

    func testHomeDotWineCanaryIsNeverTouched() throws {
        let storage = try makePortableStorage()
        // A ".wine" directory anywhere near the roots must never be read or moved.
        let canary = storage.legacySupportDirectory.deletingLastPathComponent()
            .appendingPathComponent(".wine", isDirectory: true)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        try "CANARY".write(to: canary.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        storage.performFirstRunImportIfNeeded()
        storage.adoptFallbackPrefixIfNeeded(isPrefixBusy: { false })

        XCTAssertEqual(
            try String(contentsOf: canary.appendingPathComponent("user.reg"), encoding: .utf8),
            "CANARY"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.prefixURL.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PortableStorageAdoptionTests`
Expected: compile FAILURE — no `adoptFallbackPrefixIfNeeded`.

- [ ] **Step 3: Implement**

Add to `PortableStorage`:

```swift
    // MARK: - Fallback-prefix adoption

    /// When a launch resolves beside the app but the Application Support
    /// fallback still holds an app-created prefix (user ran from a read-only
    /// location first), MOVE it into the Data folder instead of paying a full
    /// wineboot init + VC++ reinstall for a fresh one. Skipped while any
    /// bundled wineserver is alive — moving a live prefix corrupts it; the
    /// move is retried on the next launch.
    func adoptFallbackPrefixIfNeeded(isPrefixBusy: () -> Bool = PortableStorage.isBundledWineserverRunning) {
        guard isPortable else { return }
        let source = legacySupportDirectory.appendingPathComponent("prefix", isDirectory: true)
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: prefixURL.path) else { return }
        guard !isPrefixBusy() else { return }

        do {
            try fileManager.moveItem(at: source, to: prefixURL)
        } catch {
            // Cross-volume move: copy, verify the copy landed, then delete.
            do {
                try fileManager.copyItem(at: source, to: prefixURL)
                guard fileManager.fileExists(atPath: prefixURL.appendingPathComponent("user.reg").path) else {
                    try? fileManager.removeItem(at: prefixURL)
                    return
                }
                try? fileManager.removeItem(at: source)
            } catch {
                try? fileManager.removeItem(at: prefixURL)
                return
            }
        }
        normalizeCDriveSymlink()
        // Time Machine must not churn on the prefix (spec: excluded in all modes).
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var adopted = prefixURL
        try? adopted.setResourceValues(backupValues)
    }

    /// wine's own prefixes use a relative "c:" -> "../drive_c" symlink, which
    /// is what makes them relocatable. Rewrite an absolute one after a move.
    private func normalizeCDriveSymlink() {
        let cDrive = prefixURL.appendingPathComponent("dosdevices", isDirectory: true)
            .appendingPathComponent("c:")
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: cDrive.path),
              target != "../drive_c" else { return }
        try? fileManager.removeItem(at: cDrive)
        try? fileManager.createSymbolicLink(atPath: cDrive.path, withDestinationPath: "../drive_c")
    }

    /// Conservative busy check: if the bundled wineserver is running at all,
    /// skip adoption this session (pgrep -f on the binary path).
    static func isBundledWineserverRunning() -> Bool {
        guard let result = try? ProcessRunner.run(
            executablePath: "/usr/bin/pgrep",
            arguments: ["-f", WineRuntime.shared.wineserverBinaryURL.path],
            timeout: 5
        ) else {
            return false
        }
        return result.exitCode == 0
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PortableStorageAdoptionTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/WoWSiliconSwift/Services/PortableStorage.swift Tests/WoWSiliconSwiftTests/PortableStorageAdoptionTests.swift
git commit -m "feat: adopt the fallback prefix when the app becomes portable

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Choke point — winePrefixURL retarget

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift:9-15`
- Modify: `Tests/WoWSiliconSwiftTests/WineRegistrySupportTests.swift`

**Interfaces:**
- Consumes: `PortableStorage` (Task 1).
- Produces: `WineRegistrySupport.winePrefixURL(storage: PortableStorage = .shared) -> URL` and `userRegURL(storage: PortableStorage = .shared) -> URL`. **All existing no-argument call sites keep compiling and are hereby retargeted** (DependencyService.swift:124,142-143,235; RetinaModeService.swift:23,38,67,115; OptionAsAltService.swift:24,63,83,158). `makeWineEnvironment` is unchanged.

- [ ] **Step 1: Write the failing test**

Add to `Tests/WoWSiliconSwiftTests/WineRegistrySupportTests.swift` (keep the two existing tests; add a temp-dir helper + tearDown following the VersionStoreTests pattern):

```swift
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    func testWinePrefixURLDerivesFromPortableStorage() throws {
        let parent = try makeTemporaryDirectory()
        let fallback = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: fallback
        )

        XCTAssertEqual(WineRegistrySupport.winePrefixURL(storage: storage), storage.prefixURL)
        XCTAssertEqual(
            WineRegistrySupport.userRegURL(storage: storage),
            storage.prefixURL.appendingPathComponent("user.reg")
        )
        XCTAssertFalse(WineRegistrySupport.winePrefixURL(storage: storage).path.hasSuffix("/.wine"),
                       "the shared global ~/.wine must no longer be the app's prefix")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WineRegistrySupportTests`
Expected: compile FAILURE — `extra argument 'storage'`.

- [ ] **Step 3: Implement**

In `Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift`, replace lines 9-15:

```swift
    /// The app's dedicated Wine prefix. Every registry/dependency operation and
    /// every direct user.reg read/write routes through this one function — it is
    /// the single choke point that keeps the app off the shared global ~/.wine.
    static func winePrefixURL(storage: PortableStorage = .shared) -> URL {
        storage.prefixURL
    }

    static func userRegURL(storage: PortableStorage = .shared) -> URL {
        winePrefixURL(storage: storage).appendingPathComponent("user.reg")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WineRegistrySupportTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS (DependencyService/RetinaModeService/OptionAsAltService compile untouched — they call the zero-argument form).

```bash
git add Sources/WoWSiliconSwift/Services/WineRegistrySupport.swift Tests/WoWSiliconSwiftTests/WineRegistrySupportTests.swift
git commit -m "feat: retarget winePrefixURL to the dedicated PortableStorage prefix

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: WINEPREFIX pinning in the launch command

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/LaunchService.swift:124-130, 225-254, 294-300, 349-356`
- Modify: `Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift`

**Interfaces:**
- Consumes: `PortableStorage.shared.prefixURL` (Task 1).
- Produces: `LaunchService.makeShellCommand(gamePath:executablePath:wineBinaryPath:rosettaLoaderPath:winePrefixPath:settings:extraArguments:)` — new required `winePrefixPath: String` parameter after `rosettaLoaderPath`. The pin is emitted **after** the base env (last env token), so under sh's last-assignment-wins a user-typed `WINEPREFIX` in the custom env field can never override it.

- [ ] **Step 1: Update the tests (failing first)**

In `Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift`:

1. Add a shared constant below `loaderPath` (line 6):

```swift
    private let prefixPath = "/Applications/WoWSilicon Data/prefix"
```

2. Add `winePrefixPath: prefixPath,` after every `rosettaLoaderPath:` argument in all 7 existing tests.
3. Update `testFullCommandWithLoaderAndDefaultSettings`'s expected string (lines 17-23) to:

```swift
        XCTAssertEqual(
            command,
            "cd \"/Games/WoW Classic\" && " +
            "ROSETTA_X87_PATH=\"\(loaderPath)\" " +
            "WINEDLLOVERRIDES=\"d3d9=n,b;mscoree=d;mshtml=d\" MTL_HUD_ENABLED=0 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 DXVK_ASYNC=1 " +
            "WINEPREFIX=\"/Applications/WoWSilicon Data/prefix\" " +
            "\"\(winePath)\" \"/Games/WoW Classic/WoW.exe\""
        )
```

4. Rewrite `testCustomEnvironmentVariableValuesAreQuoted` (lines 69-79) to use a neutral variable — WINEPREFIX is no longer a user-controllable example:

```swift
    func testCustomEnvironmentVariableValuesAreQuoted() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings(environmentVariables: "MY_DIR=/tmp/$(whoami) FLAG")
        )

        XCTAssertTrue(command.contains("MY_DIR=\"/tmp/\\$(whoami)\" FLAG "))
    }
```

5. Add two new tests:

```swift
    func testWinePrefixIsPinnedQuotedAndEscaped() {
        let hostilePrefix = "/Volumes/USB Stick/WoWSilicon Data/$(evil)/prefix"
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: hostilePrefix,
            settings: VersionSettings()
        )

        XCTAssertTrue(command.contains("WINEPREFIX=\"/Volumes/USB Stick/WoWSilicon Data/\\$(evil)/prefix\""))
    }

    func testAppWinePrefixPinOverridesUserSuppliedOne() throws {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings(environmentVariables: "WINEPREFIX=/tmp/user-prefix")
        )

        let userIndex = try XCTUnwrap(command.range(of: "WINEPREFIX=\"/tmp/user-prefix\"")).lowerBound
        let appIndex = try XCTUnwrap(command.range(of: "WINEPREFIX=\"\(prefixPath)\"")).lowerBound
        // sh applies the LAST assignment of a duplicated env var; the app's pin
        // must therefore appear after the user's.
        XCTAssertLessThan(userIndex, appIndex)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LaunchCommandTests`
Expected: compile FAILURE — `extra argument 'winePrefixPath'`.

- [ ] **Step 3: Implement**

In `Sources/WoWSiliconSwift/Services/LaunchService.swift`:

1. `makeShellCommand` (line 225): add the parameter and emit the pin last:

```swift
    static func makeShellCommand(
        gamePath: String,
        executablePath: String,
        wineBinaryPath: String,
        rosettaLoaderPath: String?,
        winePrefixPath: String,
        settings: VersionSettings,
        extraArguments: [String] = []
    ) -> String {
```

and after `envParts.append(baseEnv)` (line 247) add:

```swift
        // Pinned LAST: sh applies the last assignment of a duplicated variable,
        // so a WINEPREFIX typed into the custom env field can never win. Both
        // the game and every registry/status operation must share one prefix.
        envParts.append("WINEPREFIX=\(doubleQuote(winePrefixPath))")
```

2. All three call sites gain the argument `winePrefixPath: PortableStorage.shared.prefixURL.path`:
   - `prepareLaunchArtifacts` (lines 124-130),
   - `launchInstaller` (lines 294-300),
   - `launchThirdPartyLauncher` (lines 349-356).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LaunchCommandTests`
Expected: 9 tests PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/WoWSiliconSwift/Services/LaunchService.swift Tests/WoWSiliconSwiftTests/LaunchCommandTests.swift
git commit -m "feat: pin WINEPREFIX in every launch command

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: WINEPREFIX for PatchService and VanillaTweaksService

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/PatchService.swift:90-95`
- Modify: `Sources/WoWSiliconSwift/Services/VanillaTweaksService.swift:56-62, 116-131`

**Interfaces:**
- Consumes: `WineRegistrySupport.winePrefixURL()` / `makeWineEnvironment` (Task 6 / existing).
- Produces: nothing new — these two services stop silently initializing `~/.wine`. No behavior change visible to other tasks.

- [ ] **Step 1: PatchService — add the prefix to the hand-built env**

In `patchDivxDecoder` (lines 93-95), after `env["WINEDEBUG"] = "-all"` add:

```swift
        env["WINEPREFIX"] = WineRegistrySupport.winePrefixURL().path
```

- [ ] **Step 2: VanillaTweaksService — use the shared environment builder**

Replace the `ProcessRunner.run` call's environment argument (line 59):

```swift
            environment: WineRegistrySupport.makeWineEnvironment(
                prefixURL: WineRegistrySupport.winePrefixURL(),
                wineExecutable: wineBinaryPath
            ),
```

and **delete** the now-unused private `makeWineEnvironment(wineBinaryPath:)` (lines 116-131).

- [ ] **Step 3: Build + full suite**

Run: `swift build && swift test`
Expected: build OK, all tests PASS (no wine executes during tests; this is compile-level verification — the runtime path is exercised by the manual checklist).

- [ ] **Step 4: Commit**

```bash
git add Sources/WoWSiliconSwift/Services/PatchService.swift Sources/WoWSiliconSwift/Services/VanillaTweaksService.swift
git commit -m "fix: pin WINEPREFIX in divx patch and vanilla-tweaks wine invocations

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: PrefixBootstrapService

**Files:**
- Create: `Sources/WoWSiliconSwift/Services/PrefixBootstrapService.swift`
- Test: `Tests/WoWSiliconSwiftTests/PrefixBootstrapServiceTests.swift` (new)

**Interfaces:**
- Consumes: `PortableStorage` (Task 1), `WineRuntime` (existing: `init(bundleURL:rosettaLoaderOverride:)`, `runtimeVersion`, `validatedWineBinaryURL()`, `wineserverBinaryURL`), `WineRegistrySupport.makeWineEnvironment`, `ProcessRunResult`/`ProcessRunnerError` (existing).
- Produces (Task 12 relies on these exact names):
  - `final class PrefixBootstrapService: @unchecked Sendable`
  - `typealias Runner = (_ executablePath: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) throws -> ProcessRunResult`
  - `init(storage: PortableStorage = .shared, runtime: WineRuntime = .shared, fileManager: FileManager = .default, runner: @escaping Runner = PrefixBootstrapService.defaultRunner)`
  - `static let shared: PrefixBootstrapService`
  - `static let sentinelFileName = ".wowsilicon-prefix-ok"`
  - `func isPrefixReady() -> Bool`
  - `func bootstrapIfNeeded() throws` (no-op when ready)
  - `enum PrefixBootstrapError: LocalizedError { case bootFailed(String), timedOut, structureInvalid, runtimeVersionUnknown }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/WoWSiliconSwiftTests/PrefixBootstrapServiceTests.swift`:

```swift
import XCTest
@testable import WoWSiliconSwift

final class PrefixBootstrapServiceTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    /// A fake .app bundle carrying an executable wine/wineserver and a VERSION file.
    private func makeFakeRuntimeBundle(version: String) throws -> URL {
        let bundleURL = try makeTemporaryDirectory().appendingPathComponent("WoWSilicon.app", isDirectory: true)
        let binDir = bundleURL.appendingPathComponent("Contents/SharedSupport/wine/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            let url = binDir.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try version.write(
            to: bundleURL.appendingPathComponent("Contents/SharedSupport/wine/VERSION"),
            atomically: true, encoding: .utf8)
        return bundleURL
    }

    private func makeStorage() throws -> PortableStorage {
        let parent = try makeTemporaryDirectory()
        return PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: try makeTemporaryDirectory()
        )
    }

    /// Writes the structure wineboot would have produced.
    private func materializePrefixStructure(at prefix: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices", isDirectory: true), withIntermediateDirectories: true)
        try "WINE REGISTRY Version 2".write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2".write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            atPath: prefix.appendingPathComponent("dosdevices/c:").path,
            withDestinationPath: "../drive_c")
    }

    func testBootstrapRunsWinebootThenWineserverAndWritesSentinel() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))
        final class Recorder: @unchecked Sendable { var invocations: [[String]] = [] }
        let recorder = Recorder()
        let materialize = { try self.materializePrefixStructure(at: storage.prefixURL) }

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { exe, args, env, timeout in
            recorder.invocations.append([exe] + args)
            XCTAssertEqual(env["WINEPREFIX"], storage.prefixURL.path)
            if args.first == "wineboot" {
                XCTAssertEqual(timeout, 600)
                try materialize()
            }
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertFalse(service.isPrefixReady())
        try service.bootstrapIfNeeded()

        XCTAssertEqual(recorder.invocations.count, 2)
        XCTAssertEqual(Array(recorder.invocations[0].dropFirst()), ["wineboot", "-u"])
        XCTAssertTrue(recorder.invocations[1][0].hasSuffix("/wineserver"))
        XCTAssertEqual(Array(recorder.invocations[1].dropFirst()), ["-w"])
        XCTAssertTrue(service.isPrefixReady())
        let sentinel = storage.prefixURL.appendingPathComponent(".wowsilicon-prefix-ok")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "wine-14 (test)")
    }

    func testBootstrapIfNeededNoOpsWhenSentinelMatches() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))
        try materializePrefixStructure(at: storage.prefixURL)
        try "wine-14 (test)".write(
            to: storage.prefixURL.appendingPathComponent(".wowsilicon-prefix-ok"),
            atomically: true, encoding: .utf8)

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { _, _, _, _ in
            XCTFail("must not spawn wine when the sentinel matches")
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertTrue(service.isPrefixReady())
        try service.bootstrapIfNeeded()
    }

    func testRuntimeVersionMismatchTriggersRebootstrap() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-15 (new)"))
        try materializePrefixStructure(at: storage.prefixURL)
        try "wine-14 (old)".write(
            to: storage.prefixURL.appendingPathComponent(".wowsilicon-prefix-ok"),
            atomically: true, encoding: .utf8)

        XCTAssertFalse(PrefixBootstrapService(storage: storage, runtime: runtime,
                                              runner: { _, _, _, _ in ProcessRunResult(exitCode: 0, stdout: "", stderr: "") })
            .isPrefixReady())
    }

    func testWinebootFailureCleansHalfBuiltPrefixAndThrows() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { _, args, _, _ in
            if args.first == "wineboot" {
                return ProcessRunResult(exitCode: 1, stdout: "", stderr: "boom")
            }
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertThrowsError(try service.bootstrapIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.prefixURL.path),
                       "half-built prefix must be deleted so the next attempt starts clean")
    }

    func testTimeoutCleansPrefixViaGracefulWineserverKill() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))
        final class Recorder: @unchecked Sendable { var killIssued = false }
        let recorder = Recorder()

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { exe, args, _, _ in
            if args.first == "wineboot" { throw ProcessRunnerError.timedOut(600) }
            if exe.hasSuffix("/wineserver"), args == ["-k"] { recorder.killIssued = true }
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertThrowsError(try service.bootstrapIfNeeded()) { error in
            guard case PrefixBootstrapError.timedOut = error else {
                return XCTFail("expected .timedOut, got \(error)")
            }
        }
        XCTAssertTrue(recorder.killIssued, "timeout path must ask wineserver to shut down cleanly, never SIGKILL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.prefixURL.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PrefixBootstrapServiceTests`
Expected: compile FAILURE — `cannot find 'PrefixBootstrapService' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/WoWSiliconSwift/Services/PrefixBootstrapService.swift`:

```swift
import Foundation

enum PrefixBootstrapError: LocalizedError {
    case runtimeVersionUnknown
    case bootFailed(String)
    case timedOut
    case structureInvalid

    var errorDescription: String? {
        switch self {
        case .runtimeVersionUnknown:
            return "The bundled Wine runtime version could not be read. Please reinstall WoWSilicon."
        case .bootFailed(let output):
            return output.isEmpty ? "Setting up the Wine environment failed." : output
        case .timedOut:
            return "Setting up the Wine environment took too long and was cancelled. Please try again."
        case .structureInvalid:
            return "The Wine environment was not set up completely. Please try again."
        }
    }
}

/// Explicit, sentinel-gated initialization of the dedicated Wine prefix.
///
/// wine stamps its own .update-timestamp BEFORE running the install sections,
/// so an interrupted implicit init looks permanently complete to wine and is
/// never repaired. This service therefore (a) initializes explicitly with a
/// generous timeout, (b) records success in an app-owned sentinel written only
/// after a structural sanity check, and (c) deletes the half-built prefix on
/// any failure so the next attempt starts clean.
final class PrefixBootstrapService: @unchecked Sendable {
    typealias Runner = (
        _ executablePath: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ timeout: TimeInterval
    ) throws -> ProcessRunResult

    static let shared = PrefixBootstrapService()
    static let sentinelFileName = ".wowsilicon-prefix-ok"

    static let defaultRunner: Runner = { executablePath, arguments, environment, timeout in
        try ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    private let storage: PortableStorage
    private let runtime: WineRuntime
    private let fileManager: FileManager
    private let runner: Runner
    private let bootstrapLock = NSLock()

    init(storage: PortableStorage = .shared,
         runtime: WineRuntime = .shared,
         fileManager: FileManager = .default,
         runner: @escaping Runner = PrefixBootstrapService.defaultRunner) {
        self.storage = storage
        self.runtime = runtime
        self.fileManager = fileManager
        self.runner = runner
    }

    /// Ready = sentinel content equals the bundled runtime version AND the
    /// prefix structure is sane. Never trust wine's .update-timestamp.
    func isPrefixReady() -> Bool {
        guard let runtimeVersion = runtime.runtimeVersion else { return false }
        let sentinelURL = storage.prefixURL.appendingPathComponent(Self.sentinelFileName)
        guard let contents = try? String(contentsOf: sentinelURL, encoding: .utf8) else { return false }
        return contents == runtimeVersion && structureLooksSane()
    }

    func bootstrapIfNeeded() throws {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        guard !isPrefixReady() else { return }
        try bootstrap()
    }

    private func bootstrap() throws {
        guard let runtimeVersion = runtime.runtimeVersion else {
            throw PrefixBootstrapError.runtimeVersionUnknown
        }
        let wine = try runtime.validatedWineBinaryURL().path
        let prefix = storage.prefixURL
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        excludeFromBackup(prefix)

        var environment = WineRegistrySupport.makeWineEnvironment(prefixURL: prefix, wineExecutable: wine)
        environment["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree=d;mshtml=d"

        do {
            // wineboot -u forces the update pass even when wine's own timestamp
            // says "up to date" — the only way to repair a half-built prefix.
            // 600 s: wine's implicit boot wait is hardcoded to 5 minutes; the
            // dual-arch inf pass under cold Rosetta needs the headroom.
            let boot = try runner(wine, ["wineboot", "-u"], environment, 600)
            guard boot.exitCode == 0 else {
                removeHalfBuiltPrefix()
                throw PrefixBootstrapError.bootFailed(boot.combinedOutput)
            }
            // Wait for wineserver to flush the registry and exit.
            _ = try? runner(runtime.wineserverBinaryURL.path, ["-w"], environment, 120)
        } catch let error as ProcessRunnerError {
            gracefullyStopWineserver(environment: environment)
            removeHalfBuiltPrefix()
            if case .timedOut = error {
                throw PrefixBootstrapError.timedOut
            }
            throw PrefixBootstrapError.bootFailed(error.localizedDescription)
        }

        guard structureLooksSane() else {
            removeHalfBuiltPrefix()
            throw PrefixBootstrapError.structureInvalid
        }

        let sentinelURL = prefix.appendingPathComponent(Self.sentinelFileName)
        try runtimeVersion.write(to: sentinelURL, atomically: true, encoding: .utf8)
    }

    private func structureLooksSane() -> Bool {
        let prefix = storage.prefixURL
        let cDrive = prefix.appendingPathComponent("dosdevices/c:")
        guard fileManager.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
              fileManager.fileExists(atPath: prefix.appendingPathComponent("user.reg").path),
              fileManager.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows").path),
              (try? fileManager.destinationOfSymbolicLink(atPath: cDrive.path)) != nil else {
            return false
        }
        return true
    }

    private func gracefullyStopWineserver(environment: [String: String]) {
        _ = try? runner(runtime.wineserverBinaryURL.path, ["-k"], environment, 10)
    }

    private func removeHalfBuiltPrefix() {
        try? fileManager.removeItem(at: storage.prefixURL)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PrefixBootstrapServiceTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/WoWSiliconSwift/Services/PrefixBootstrapService.swift Tests/WoWSiliconSwiftTests/PrefixBootstrapServiceTests.swift
git commit -m "feat: explicit sentinel-gated prefix bootstrap service

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: forceQuitWine graceful rework

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/LaunchService.swift:504-523`

**Interfaces:**
- Consumes: `PortableStorage.shared.prefixURL`, `WineRuntime.shared` (existing), `ProcessRunner`.
- Produces: same signature `static func forceQuitWine()`. The global `pkill -9 -f ".exe"` is **removed** — it killed every Wine process on the machine (other apps' games included) and SIGKILLed wineserver mid-registry-flush.

- [ ] **Step 1: Implement**

Replace the body of `forceQuitWine` (lines 504-523):

```swift
    static func forceQuitWine() {
        func pkill(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
        }

        let runtime = WineRuntime.shared

        // Ask our wineserver to shut down cleanly first so it flushes the
        // registry — SIGKILL discards up to 30 s of unflushed changes.
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = PortableStorage.shared.prefixURL.path
        if FileManager.default.isExecutableFile(atPath: runtime.wineserverBinaryURL.path) {
            _ = try? ProcessRunner.run(
                executablePath: runtime.wineserverBinaryURL.path,
                arguments: ["-k"],
                environment: environment,
                timeout: 5
            )
            Thread.sleep(forTimeInterval: 5)
        }

        // Escalate, scoped to OUR runtime only. The old `pkill -9 -f ".exe"`
        // matched every Wine app on the machine and is deliberately gone.
        pkill(["-9", "-f", runtime.wineBinaryURL.path])
        pkill(["-9", "-f", runtime.wineserverBinaryURL.path])
        pkill(["-9", "-f", "rosettax87"])
    }
```

(Callers already run this off the main thread — `MainDashboardViewModel.forceQuitWine()` dispatches to a global queue — so the 5 s grace sleep is acceptable.)

- [ ] **Step 2: Build + full suite**

Run: `swift build && swift test`
Expected: PASS. (Process-killing behavior is covered by the manual checklist, not unit tests.)

- [ ] **Step 3: Commit**

```bash
git add Sources/WoWSiliconSwift/Services/LaunchService.swift
git commit -m "fix: scope force-quit to the bundled runtime and stop the registry-destroying SIGKILL

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Troubleshooting retarget (service + view model + view)

**Files:**
- Modify: `Sources/WoWSiliconSwift/Services/TroubleshootingService.swift:20-24, 57-79, 143-150, 206-227`
- Modify: `Sources/WoWSiliconSwift/ViewModels/TroubleshootingViewModel.swift`
- Modify: `Sources/WoWSiliconSwift/Views/TroubleshootingView.swift`
- Modify: `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift:1116-1125` (context factory)
- Modify: `Tests/WoWSiliconSwiftTests/TroubleshootingServiceTests.swift` (add tests)

**Interfaces:**
- Consumes: `PortableStorage` (Task 1), `PrefixBootstrapService.sentinelFileName` (Task 9).
- Produces:
  - `TroubleshootingService.deleteDedicatedPrefix(prefixURL: URL) throws -> [String]`
  - `TroubleshootingService.deleteLegacyPrefixes(homeDirectory: URL, gamePath: String?) throws -> [String]` (replaces `deleteWinePrefixes`)
  - `TroubleshootingService.resetStorage(storage: PortableStorage) throws -> [String]` (replaces `resetApplicationSupport`)
  - `TroubleshootingContext` gains `let storageDescription: String`, `let dataRootPath: String`, `let prefixPath: String`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/WoWSiliconSwiftTests/TroubleshootingServiceTests.swift` (it already has `makeTemporaryDirectory`/`tempURLs` helpers):

```swift
    func testDeleteDedicatedPrefixDeletesOnlyThePrefix() throws {
        let root = try makeTemporaryDirectory()
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let bystander = root.appendingPathComponent(".wine", isDirectory: true)
        try FileManager.default.createDirectory(at: bystander, withIntermediateDirectories: true)

        let deleted = try TroubleshootingService.deleteDedicatedPrefix(prefixURL: prefix)

        XCTAssertEqual(deleted, [prefix.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path), "a .wine dir is never part of this action")
    }

    func testDeleteDedicatedPrefixThrowsWhenAbsent() throws {
        let root = try makeTemporaryDirectory()
        XCTAssertThrowsError(try TroubleshootingService.deleteDedicatedPrefix(
            prefixURL: root.appendingPathComponent("prefix"))) { error in
            XCTAssertEqual(error as? TroubleshootingServiceError, .nothingToDelete)
        }
    }

    func testDeleteLegacyPrefixesTargetsHomeAndGameDotWine() throws {
        let home = try makeTemporaryDirectory()
        let game = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".wine"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game.appendingPathComponent(".wine"), withIntermediateDirectories: true)

        let deleted = try TroubleshootingService.deleteLegacyPrefixes(homeDirectory: home, gamePath: game.path)

        XCTAssertEqual(Set(deleted), Set([
            home.appendingPathComponent(".wine").path,
            game.appendingPathComponent(".wine").path,
        ]))
    }

    func testResetStorageDeletesActiveRootAndFallback() throws {
        let parent = try makeTemporaryDirectory()
        let fallback = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: fallback
        )
        let fallbackDir = storage.legacySupportDirectory
        try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        try "x".write(to: fallbackDir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)

        let deleted = try TroubleshootingService.resetStorage(storage: storage)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.dataRootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackDir.path))
        XCTAssertEqual(Set(deleted), Set([storage.dataRootURL.path, fallbackDir.path]))
    }

    func testDebugLogContainsStorageBlock() throws {
        let context = TroubleshootingContext(
            gamePath: nil,
            currentVersion: nil,
            isGamePatched: false,
            storageDescription: "Portable — /Volumes/USB/WoWSilicon Data",
            dataRootPath: "/Volumes/USB/WoWSilicon Data",
            prefixPath: "/Volumes/USB/WoWSilicon Data/prefix"
        )

        let log = TroubleshootingService.generateDebugLog(
            context: context, hideMacUserName: false, includeLatestErrorLog: false).full

        XCTAssertTrue(log.contains("=== Storage ==="))
        XCTAssertTrue(log.contains("Location: Portable — /Volumes/USB/WoWSilicon Data"))
        XCTAssertTrue(log.contains("Wine prefix: /Volumes/USB/WoWSilicon Data/prefix"))
    }
```

Also make `TroubleshootingServiceError` `Equatable` if it is not already (`enum TroubleshootingServiceError: LocalizedError, Equatable`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TroubleshootingServiceTests`
Expected: compile FAILURE — missing members.

- [ ] **Step 3: Implement the service changes**

In `Sources/WoWSiliconSwift/Services/TroubleshootingService.swift`:

1. Extend the context (lines 20-24):

```swift
struct TroubleshootingContext: Sendable {
    let gamePath: String?
    let currentVersion: GameVersion?
    let isGamePatched: Bool
    let storageDescription: String
    let dataRootPath: String
    let prefixPath: String
}
```

2. Replace `deleteWinePrefixes` (lines 57-79) with the two scoped actions:

```swift
    /// Primary reset: deletes ONLY the app's dedicated prefix.
    static func deleteDedicatedPrefix(prefixURL: URL = PortableStorage.shared.prefixURL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: prefixURL.path) else {
            throw TroubleshootingServiceError.nothingToDelete
        }
        try fm.removeItem(at: prefixURL)
        return [prefixURL.path]
    }

    /// Legacy cleanup for pre-3.x installs. ~/.wine is the SHARED system
    /// default prefix — CrossOver, GameHub and other Wine apps may own state
    /// in it — so this is a separate, explicitly-confirmed action and never
    /// part of the default reset.
    static func deleteLegacyPrefixes(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        gamePath: String?
    ) throws -> [String] {
        let fm = FileManager.default
        var candidates = [homeDirectory.appendingPathComponent(".wine", isDirectory: true)]
        if let path = gamePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".wine", isDirectory: true))
        }

        var deleted: [String] = []
        for url in candidates where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            deleted.append(url.path)
        }
        if deleted.isEmpty {
            throw TroubleshootingServiceError.nothingToDelete
        }
        return deleted
    }
```

3. Replace `resetApplicationSupport` (lines 143-150):

```swift
    /// Deletes the active storage root (Data folder including the prefix) and,
    /// when running portable, also the Application Support fallback directory.
    static func resetStorage(storage: PortableStorage = .shared) throws -> [String] {
        let fm = FileManager.default
        var targets = [storage.dataRootURL]
        if storage.isPortable {
            targets.append(storage.legacySupportDirectory)
        }
        var deleted: [String] = []
        for url in targets where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            deleted.append(url.path)
        }
        if deleted.isEmpty {
            throw TroubleshootingServiceError.nothingToDelete
        }
        return deleted
    }
```

4. In `generateDebugLog`, insert a Storage block right after the `=== Paths ===` section (after line 210, before `var fullLog = baseLog`):

```swift
        baseLog += "\n=== Storage ===\n"
        baseLog += "Location: \(context.storageDescription)\n"
        baseLog += "Data root: \(context.dataRootPath)"
        baseLog += FileManager.default.fileExists(atPath: context.dataRootPath) ? " (exists)\n" : " (missing)\n"
        baseLog += "Wine prefix: \(context.prefixPath)"
        baseLog += FileManager.default.fileExists(atPath: context.prefixPath) ? " (exists)\n" : " (missing)\n"
        let sentinelPath = (context.prefixPath as NSString).appendingPathComponent(PrefixBootstrapService.sentinelFileName)
        let sentinel = (try? String(contentsOfFile: sentinelPath, encoding: .utf8)) ?? "missing"
        baseLog += "Prefix sentinel: \(sentinel)\n"
        let legacyWine = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wine")
        baseLog += "Legacy ~/.wine present: " + (FileManager.default.fileExists(atPath: legacyWine.path) ? "yes\n" : "no\n")
```

- [ ] **Step 4: Update the view model, view, and context factory**

`Sources/WoWSiliconSwift/ViewModels/TroubleshootingViewModel.swift`:

1. Add published storage fields (below `rosettaStatus`, line 18):

```swift
    @Published var storageDescription: String = ""
```

2. In `refresh()` (inside the `Task.detached`, next to the runtime lookups, line 42-44):

```swift
            let storageDescription = PortableStorage.shared.displayDescription
```

and assign it in the `@MainActor` block: `self.storageDescription = storageDescription`.

3. Replace `deleteWinePrefixes()` (lines 74-80) with:

```swift
    func resetWinePrefix() {
        perform(action: "Resetting the Wine prefix…") {
            let deleted = try TroubleshootingService.deleteDedicatedPrefix()
            return "Deleted:\n" + deleted.joined(separator: "\n") + "\n\nThe Wine environment will be set up again on the next launch."
        }
    }

    func deleteLegacyPrefixes() {
        let gamePath = context.gamePath
        perform(action: "Deleting legacy Wine prefixes…") {
            let deleted = try TroubleshootingService.deleteLegacyPrefixes(gamePath: gamePath)
            return "Deleted:\n" + deleted.joined(separator: "\n")
        }
    }
```

4. Replace `resetApplicationSupport()` (lines 106-111) with:

```swift
    func resetStorage() {
        perform(action: "Resetting WoWSilicon…") {
            let deleted = try TroubleshootingService.resetStorage()
            return "Deleted:\n" + deleted.joined(separator: "\n") + "\n\nPlease restart the app."
        }
    }
```

`Sources/WoWSiliconSwift/Views/TroubleshootingView.swift`:

1. Add a storage section between `runtimeSection` and `actionsSection` (body list at lines 14-15):

```swift
    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage").font(.headline)
            Text(viewModel.storageDescription)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
```

2. In `actionsSection`, replace the `"Delete Wine Prefixes"` button (line 60) with the split actions (add `@State private var showLegacyPrefixConfirmation = false` next to the existing `@State` at line 6):

```swift
            Button("Reset Wine Prefix", action: viewModel.resetWinePrefix)
                .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 4) {
                Button("Delete Legacy Wine Prefixes (~/.wine)") {
                    showLegacyPrefixConfirmation = true
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "Delete legacy Wine prefixes?",
                    isPresented: $showLegacyPrefixConfirmation
                ) {
                    Button("Delete", role: .destructive, action: viewModel.deleteLegacyPrefixes)
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This deletes ~/.wine and the game folder's .wine directory. ~/.wine is shared with OTHER Wine software (CrossOver, GameHub, …) — only do this if nothing else on this Mac uses Wine.")
                }
                Text("Only needed to clean up after WoWSilicon 2.x")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
```

3. Rename the reset button (lines 82-84):

```swift
            Button(role: .destructive, action: viewModel.resetStorage) {
                Text("Reset WoWSilicon (delete all data)")
            }
```

`Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift` — `makeTroubleshootingContext()` (lines 1116-1125):

```swift
    func makeTroubleshootingContext() -> TroubleshootingContext {
        let version = versionManager.currentVersion
        let trimmedGame = version?.gamePath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storage = PortableStorage.shared

        return TroubleshootingContext(
            gamePath: trimmedGame.isEmpty ? nil : trimmedGame,
            currentVersion: version,
            isGamePatched: isGamePatched,
            storageDescription: storage.displayDescription,
            dataRootPath: storage.dataRootURL.path,
            prefixPath: storage.prefixURL.path
        )
    }
```

Note: this task runs before Task 12, so `MainDashboardViewModel` still constructs `PortableStorage.shared` lazily here — that is fine, `.shared` is initialized on first touch.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TroubleshootingServiceTests`
Expected: all (3 existing + 5 new) PASS.

- [ ] **Step 6: Full suite + commit**

Run: `swift build && swift test`
Expected: PASS.

```bash
git add Sources/WoWSiliconSwift/Services/TroubleshootingService.swift Sources/WoWSiliconSwift/ViewModels/TroubleshootingViewModel.swift Sources/WoWSiliconSwift/Views/TroubleshootingView.swift Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift Tests/WoWSiliconSwiftTests/TroubleshootingServiceTests.swift
git commit -m "feat: storage-aware troubleshooting with scoped prefix actions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: MainDashboardViewModel wiring

**Files:**
- Modify: `Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift:39-105, 187, 267-294, 296-301, 573-589, 618-633`

**Interfaces:**
- Consumes: everything above — `PortableStorage` (Tasks 1/4/5), stores with `configDirectory:` (Tasks 2/3), `PrefixBootstrapService` (Task 9), `OptionAsAltService.setOptionAsAlt` (existing).
- Produces: `MainDashboardViewModel.init(storage: PortableStorage = .shared)`; `@Published private(set) var isPrefixBootstrapping: Bool`; `func ensurePrefixReady(then:)`.

- [ ] **Step 1: Wire the stores and startup sequencing**

Replace lines 51-52:

```swift
    private let storage: PortableStorage
    private let versionStore: VersionStore
    private let prefsStore: UserPrefsStore
```

Add near the other `@Published` vars (after line 43):

```swift
    @Published private(set) var isPrefixBootstrapping: Bool = false
```

Change `init()` (line 70) to:

```swift
    init(storage: PortableStorage = .shared) {
        self.storage = storage
        let legacyMigrationPending = MigrationService.legacyDirectoryExists()
        if !legacyMigrationPending {
            // Ordering: the TurtleSilicon prompt must win first when present —
            // pre-existing destination files would break its move-based
            // migration, and the portable import has the same hazard.
            storage.performFirstRunImportIfNeeded()
            storage.adoptFallbackPrefixIfNeeded()
        }
        versionStore = VersionStore(configDirectory: storage.configDirectory)
        prefsStore = UserPrefsStore(configDirectory: storage.configDirectory)
        if legacyMigrationPending {
            shouldShowMigrationPrompt = true
        }

        let result = versionStore.loadVersionManager()
        // ... rest of the existing init body unchanged, EXCEPT the line
        // `if MigrationService.legacyDirectoryExists() { shouldShowMigrationPrompt = true }`
        // at the top (lines 71-73) is deleted (replaced by the block above),
        // and at the very END of init add:
        ensurePrefixReady()
    }
```

- [ ] **Step 2: Sequence the migration completion**

In `handleMigration(migrate:)` (line 267), after the `do { try MigrationService.migrate() } catch { ... }` block and before `let result = versionStore.loadVersionManager()` (line 278), insert:

```swift
        storage.performFirstRunImportIfNeeded()
        storage.adoptFallbackPrefixIfNeeded()
```

- [ ] **Step 3: Add the bootstrap driver**

Add this method (place it after `forceQuitWine()`, line 221):

```swift
    /// Runs the explicit prefix bootstrap when needed, with UI feedback.
    /// The first run (and the first run after an app update) takes minutes
    /// under Rosetta — without this gate that wait looked like a frozen
    /// launch and users force-killed wine mid-initialization.
    func ensurePrefixReady(then completion: (() -> Void)? = nil) {
        guard !PrefixBootstrapService.shared.isPrefixReady() else {
            completion?()
            return
        }
        guard !isPrefixBootstrapping else { return }
        isPrefixBootstrapping = true
        patchFeedback = PatchFeedback(
            title: "Wine Environment",
            message: "Setting up the Wine environment — the first run can take a few minutes.",
            isError: false
        )
        let remapOptionAsAlt = versionManager.currentVersion?.settings.remapOptionAsAlt ?? false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try PrefixBootstrapService.shared.bootstrapIfNeeded()
                // Fresh prefixes lose registry-backed toggles; re-apply the one
                // whose desired state the config persists. (Retina mode has no
                // persisted source of truth — it stays at wine's default until
                // the user toggles it.)
                if remapOptionAsAlt {
                    try? OptionAsAltService.setOptionAsAlt(enabled: true)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPrefixBootstrapping = false
                    self.patchFeedback = nil
                    self.refreshOptionAsAltStatus()
                    self.refreshRetinaModeStatus()
                    self.refreshVisualCppRuntimeStatus()
                    completion?()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPrefixBootstrapping = false
                    self.patchFeedback = PatchFeedback(
                        title: "Wine Environment",
                        message: error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }
```

(If `PatchFeedback` has no `isError: false` usage yet, check its definition — it is a plain struct with an `isError` Bool used across this file; passing `false` is valid.)

- [ ] **Step 4: Gate the implicit wine queries behind the sentinel**

In `refreshOptionAsAltStatus()` (lines 573-589), replace the branch:

```swift
            let enabled: Bool
            if currentVersion != nil && PrefixBootstrapService.shared.isPrefixReady() {
                enabled = OptionAsAltService.isOptionAsAltEnabled()
            } else {
                enabled = OptionAsAltService.isOptionAsAltEnabledFast()
            }
```

In `refreshRetinaModeStatus()` (lines 618-633), same shape:

```swift
            let enabled: Bool
            if currentVersion != nil && PrefixBootstrapService.shared.isPrefixReady() {
                enabled = RetinaModeService.isRetinaModeEnabled()
            } else {
                enabled = RetinaModeService.isRetinaModeEnabledFast()
            }
```

(The fast paths only read `user.reg` as text — no wine process, so no implicit prefix creation.)

- [ ] **Step 5: Gate launch on the bootstrap**

In `launchGame()` (line 296), after the `guard canLaunch ...` block and `patchFeedback = nil` (line 302), insert:

```swift
        guard PrefixBootstrapService.shared.isPrefixReady() else {
            ensurePrefixReady { [weak self] in self?.launchGame() }
            return
        }
```

- [ ] **Step 6: Retarget the launcher file-picker seed**

Line 187 (`selectLauncherPath`):

```swift
        let driveC = storage.prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        panel.directoryURL = FileManager.default.fileExists(atPath: driveC.path)
            ? driveC
            : URL(fileURLWithPath: NSHomeDirectory())
```

- [ ] **Step 7: Build + full suite**

Run: `swift build && swift test`
Expected: PASS. Also verify no stray references remain:
`grep -rn '"\.wine"\|/.wine' Sources/ --include='*.swift'` must only show `TroubleshootingService.deleteLegacyPrefixes` and the debug-log legacy check.

- [ ] **Step 8: Commit**

```bash
git add Sources/WoWSiliconSwift/ViewModels/MainDashboardViewModel.swift
git commit -m "feat: wire portable storage, import sequencing, and bootstrap gating into the dashboard

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update CLAUDE.md**

1. In the project-overview paragraph, after the sentence about the bundled Wine runtime, add:

```markdown
All mutable state is portable: a `WoWSilicon Data` folder beside the .app holds the dedicated Wine prefix (`prefix/`) and configuration (`versions.json`, `prefs.json`), resolved by `PortableStorage` at startup with a silent fallback to `~/Library/Application Support/WoWSilicon` when the app's location is read-only (DMG, App Translocation, non-admin /Applications). The app never uses the shared global `~/.wine`.
```

2. In the `Services/` bullet, add `PortableStorage` (storage-root authority) and `PrefixBootstrapService` (explicit sentinel-gated prefix initialization) to the service list.
3. In the `Stores/` bullet, change "reads/writes `versions.json` under Application Support" to "reads/writes `versions.json` in the `PortableStorage`-resolved config directory (portable Data folder, or Application Support in fallback mode)".
4. In "Security considerations", add: "`~/.wine` belongs to other Wine software (CrossOver, etc.); the app must never write to it — the only code allowed to touch it is the explicitly-confirmed `deleteLegacyPrefixes` troubleshooting action."

- [ ] **Step 2: Update README.md**

Add a "Portable by design" section (place it near the installation instructions):

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document the portable WoWSilicon Data storage contract

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Manual release-candidate checklist (not part of the automated tasks)

1. First run on a clean machine: Data folder appears beside the app, prefix bootstraps with progress feedback, game launches.
2. Run from the mounted DMG: silent Application Support fallback; Troubleshooting shows the fallback notice; after dragging to a writable folder and relaunching, the fallback prefix is adopted (VC++ overrides survive, no re-download).
3. Quarantined (translocated) first launch: fallback; after Finder-move + relaunch, portable.
4. Sparkle update with a populated Data folder: settings and prefix survive; exactly one progress-reported prefix refresh (runtime version change).
5. Non-admin user with the app in /Applications: permanent fallback, no errors.
6. exFAT USB stick: Data folder portable; prefix hosted per the hostility probe result.
7. Delete the Data folder while the app is closed: clean re-setup on next launch, no crash.
8. `~/.wine` canary: create `~/.wine/canary.txt`, run every launch/patch/toggle/VC++ flow, verify the file and the directory's mtime are untouched.
9. Real TurtleSilicon-era Application Support data: prompt → migration → portable import chain preserves game paths.
10. Two app copies (e.g. /Applications and a USB stick) used alternately: independent Data folders, no cross-talk.
11. Run from USB after a DMG first-run; force-quit during adoption; relaunch — adoption must recover (staging cleanup) and complete.
