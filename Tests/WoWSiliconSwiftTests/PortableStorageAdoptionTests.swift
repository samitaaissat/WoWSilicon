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

    func testAdoptionCleansUpLeftoverStagingDirectoryAndCompletes() throws {
        let storage = try makePortableStorage()
        let fallbackPrefix = storage.legacySupportDirectory.appendingPathComponent("prefix", isDirectory: true)
        try makeFakePrefix(at: fallbackPrefix, cSymlinkTarget: "../drive_c")

        // Simulate a staging dir left behind by an adoption that crashed
        // mid-copy on a previous launch.
        let parentDir = storage.prefixURL.deletingLastPathComponent()
        let leftoverStaging = parentDir.appendingPathComponent("prefix.adopting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftoverStaging, withIntermediateDirectories: true)
        try "STALE".write(to: leftoverStaging.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        storage.adoptFallbackPrefixIfNeeded(isPrefixBusy: { false })

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftoverStaging.path), "leftover staging dir cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackPrefix.path), "moved, not copied")
        XCTAssertEqual(
            try String(contentsOf: storage.prefixURL.appendingPathComponent("user.reg"), encoding: .utf8),
            "REG"
        )
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
