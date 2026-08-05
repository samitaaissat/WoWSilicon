import XCTest
@testable import WoWSiliconSwift

final class PatchingStatusCheckerTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    /// Regression pin for the v2 "Play does nothing" failure mode: the checker
    /// must no longer demand <game>/rosettax87/. File-existence tier only —
    /// deliberately independent of bundled-resource checksum resolution.
    func testGamePatchDoesNotRequireGameFolderRosettax87() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try Data([0x01]).write(to: modsURL.appendingPathComponent("winerosetta.dll"))
        try Data([0x02]).write(to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
        // Deliberately NO <game>/rosettax87/ directory.

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertNotEqual(descriptor.text, "Missing rosettax87")
        XCTAssertFalse(
            descriptor.text.contains("rosettax87"),
            "checker must not demand game-folder rosettax87, got: \(descriptor.text)"
        )
    }

    /// Full "Applied" tier: real bundled resource bytes so the checksum
    /// comparison passes. Skipped (not failed) if the SPM resource bundle is
    /// unreachable under swift test — the existence tier above always runs.
    func testGamePatchAppliedWithBundledResourceCopies() throws {
        let winerosettaSource = PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta")
        let d3d9Source = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk")
        try XCTSkipIf(
            winerosettaSource == nil || d3d9Source == nil,
            "Bundled patch resources not resolvable under swift test; existence tier covered by other tests"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: winerosettaSource!, to: modsURL.appendingPathComponent("winerosetta.dll"))
        try FileManager.default.copyItem(at: d3d9Source!, to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
        // Deliberately NO <game>/rosettax87/ directory.

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertTrue(descriptor.applied, "expected Applied, got: \(descriptor.text)")
        XCTAssertEqual(descriptor.text, "Applied")
        XCTAssertEqual(descriptor.level, .success)
    }

    /// The existence tier itself must survive the change.
    func testGamePatchStillReportsMissingWinerosetta() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        try Data([0x02]).write(to: gameURL.appendingPathComponent("d3d9.dll"))

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Missing winerosetta.dll")
        XCTAssertEqual(descriptor.level, .error)
    }

    private func makeVersion(gameURL: URL) -> GameVersion {
        GameVersion(
            id: "test",
            displayName: "Test",
            wowVersion: "2.4.3",
            gamePath: gameURL.path,
            executableName: "WoW.exe",
            supportsVanillaTweaks: false,
            supportsDLLLoading: false,
            usesRosettaPatching: true,
            usesDivxDecoderPatch: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
