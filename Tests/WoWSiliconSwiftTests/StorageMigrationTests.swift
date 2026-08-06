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
