import XCTest
@testable import WoWSiliconSwift

final class TroubleshootingServiceTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testRestoreCrossOverModificationsRestoresEverything() throws {
        let crossOverURL = try makeTemporaryDirectory()
        let hostedAppDir = crossOverURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/CrossOver-Hosted Application", isDirectory: true)
        let unixDir = crossOverURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: hostedAppDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)

        try Data([0x01]).write(to: hostedAppDir.appendingPathComponent("wineloader2"))
        try Data([0x02]).write(to: unixDir.appendingPathComponent("ntdll.so"))     // patched copy
        try Data([0x03]).write(to: unixDir.appendingPathComponent("ntdll.so.bak")) // original
        try Data([0x04]).write(to: unixDir.appendingPathComponent("wine"))         // signature-stripped
        try Data([0x05]).write(to: unixDir.appendingPathComponent("wine.bak"))     // original

        let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverURL.path)

        XCTAssertEqual(result, CrossOverRestoreResult(restoredNtdll: true, restoredWine: true, removedWineloader2: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostedAppDir.appendingPathComponent("wineloader2").path))
        XCTAssertEqual(try Data(contentsOf: unixDir.appendingPathComponent("ntdll.so")), Data([0x03]))
        XCTAssertEqual(try Data(contentsOf: unixDir.appendingPathComponent("wine")), Data([0x05]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("ntdll.so.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("wine.bak").path))
    }

    func testRestoreCrossOverModificationsWithNothingToRestore() throws {
        let crossOverURL = try makeTemporaryDirectory()

        let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverURL.path)

        XCTAssertEqual(result, CrossOverRestoreResult(restoredNtdll: false, restoredWine: false, removedWineloader2: false))
    }

    func testRestoreCrossOverModificationsPartialRestoreNtdllOnly() throws {
        let crossOverURL = try makeTemporaryDirectory()
        let unixDir = crossOverURL
            .appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try Data([0x02]).write(to: unixDir.appendingPathComponent("ntdll.so"))
        try Data([0x03]).write(to: unixDir.appendingPathComponent("ntdll.so.bak"))

        let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverURL.path)

        XCTAssertEqual(result, CrossOverRestoreResult(restoredNtdll: true, restoredWine: false, removedWineloader2: false))
        XCTAssertEqual(try Data(contentsOf: unixDir.appendingPathComponent("ntdll.so")), Data([0x03]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("ntdll.so.bak").path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

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

    func testDeleteDedicatedPrefixThrowsWhenWineIsRunning() throws {
        let root = try makeTemporaryDirectory()
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        XCTAssertThrowsError(try TroubleshootingService.deleteDedicatedPrefix(
            prefixURL: prefix, isPrefixBusy: { true })) { error in
            XCTAssertEqual(error as? TroubleshootingServiceError, .operationFailed("Wine is still running. Quit the game (or use Force Quit) and try again."))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.path), "source untouched while busy")
    }

    func testDeleteDedicatedPrefixDeletesWhenNotBusy() throws {
        let root = try makeTemporaryDirectory()
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let deleted = try TroubleshootingService.deleteDedicatedPrefix(prefixURL: prefix, isPrefixBusy: { false })

        XCTAssertEqual(deleted, [prefix.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.path))
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

    func testResetStorageThrowsWhenWineIsRunning() throws {
        let parent = try makeTemporaryDirectory()
        let fallback = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: fallback
        )
        let fallbackDir = storage.legacySupportDirectory
        try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        try "x".write(to: fallbackDir.appendingPathComponent("prefs.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TroubleshootingService.resetStorage(storage: storage, isPrefixBusy: { true })) { error in
            XCTAssertEqual(error as? TroubleshootingServiceError, .operationFailed("Wine is still running. Quit the game (or use Force Quit) and try again."))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackDir.path), "source untouched while busy")
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
}
