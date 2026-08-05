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
}
