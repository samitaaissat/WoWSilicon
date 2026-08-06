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
