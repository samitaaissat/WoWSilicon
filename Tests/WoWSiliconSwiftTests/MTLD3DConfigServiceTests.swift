import XCTest
@testable import WoWSiliconSwift

final class MTLD3DConfigServiceTests: XCTestCase {
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

    private func confURL(in gameURL: URL) -> URL {
        gameURL.appendingPathComponent("mtld3d.conf")
    }

    func testSetCursorScaleCreatesLineInMissingConf() throws {
        let gameURL = try makeTemporaryDirectory()

        try MTLD3DConfigService.setCursorSizeMultiplier(gamePath: gameURL.path, multiplier: 2)

        let content = try String(contentsOf: confURL(in: gameURL), encoding: .utf8)
        XCTAssertTrue(content.contains("cursor.scale = 2"))
        XCTAssertEqual(MTLD3DConfigService.cursorSizeMultiplier(gamePath: gameURL.path), 2)
    }

    func testSetCursorScaleUpdatesExistingLineInPlace() throws {
        let gameURL = try makeTemporaryDirectory()
        try "render.scale = 0.5\ncursor.scale = 2\n".write(to: confURL(in: gameURL), atomically: true, encoding: .utf8)

        try MTLD3DConfigService.setCursorSizeMultiplier(gamePath: gameURL.path, multiplier: 3)

        let content = try String(contentsOf: confURL(in: gameURL), encoding: .utf8)
        XCTAssertTrue(content.contains("cursor.scale = 3"))
        XCTAssertFalse(content.contains("cursor.scale = 2"))
        XCTAssertTrue(content.contains("render.scale = 0.5"), "unrelated keys must survive")
    }

    /// multiplier <= 1 removes the line: mtld3d's default (`auto`) then applies,
    /// mirroring DXVKConfigService's removal semantics.
    func testSetCursorScaleToOneRemovesLine() throws {
        let gameURL = try makeTemporaryDirectory()
        try "cursor.scale = 4\nrender.scale = 1\n".write(to: confURL(in: gameURL), atomically: true, encoding: .utf8)

        try MTLD3DConfigService.setCursorSizeMultiplier(gamePath: gameURL.path, multiplier: 1)

        let content = try String(contentsOf: confURL(in: gameURL), encoding: .utf8)
        XCTAssertFalse(content.contains("cursor.scale"))
        XCTAssertTrue(content.contains("render.scale = 1"))
        XCTAssertNil(MTLD3DConfigService.cursorSizeMultiplier(gamePath: gameURL.path))
    }

    /// The shipped sample documents every key commented out — a commented
    /// `# cursor.scale = auto` line is not a value and must not be parsed or
    /// rewritten.
    func testCommentedSampleLineIsIgnored() throws {
        let gameURL = try makeTemporaryDirectory()
        try "# cursor.scale = auto\n".write(to: confURL(in: gameURL), atomically: true, encoding: .utf8)

        XCTAssertNil(MTLD3DConfigService.cursorSizeMultiplier(gamePath: gameURL.path))

        try MTLD3DConfigService.setCursorSizeMultiplier(gamePath: gameURL.path, multiplier: 2)
        let content = try String(contentsOf: confURL(in: gameURL), encoding: .utf8)
        XCTAssertTrue(content.contains("# cursor.scale = auto"), "the commented sample stays as documentation")
        XCTAssertEqual(MTLD3DConfigService.cursorSizeMultiplier(gamePath: gameURL.path), 2)
    }

    /// `cursor.scale = auto` (the upstream default, non-numeric) reads as nil.
    func testAutoValueReadsAsNil() throws {
        let gameURL = try makeTemporaryDirectory()
        try "cursor.scale = auto\n".write(to: confURL(in: gameURL), atomically: true, encoding: .utf8)

        XCTAssertNil(MTLD3DConfigService.cursorSizeMultiplier(gamePath: gameURL.path))
    }
}
