import XCTest
@testable import WoWSiliconSwift

final class PatchServiceGamePatchTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testStageGamePatchFilesCopiesPayloadAndDeletesStaleRosettax87() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk") == nil,
            "Bundled patch resources not resolvable under swift test"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        // Stale v2 leftover that apply must delete.
        let staleRosettaURL = gameURL.appendingPathComponent("rosettax87", isDirectory: true)
        try FileManager.default.createDirectory(at: staleRosettaURL, withIntermediateDirectories: true)
        try Data([0x00]).write(to: staleRosettaURL.appendingPathComponent("rosettax87"))

        let stagedURL = try PatchService.stageGamePatchFiles(for: makeVersion(gameURL: gameURL))

        XCTAssertEqual(stagedURL.path, gameURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("mods/winerosetta.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("d3d9.dll").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleRosettaURL.path),
            "apply must delete the obsolete <game>/rosettax87/ directory and must not recreate it"
        )
        let dlls = try String(contentsOf: gameURL.appendingPathComponent("dlls.txt"), encoding: .utf8)
        XCTAssertTrue(dlls.contains("mods/winerosetta.dll"))
    }

    func testStageGamePatchFilesWithD9mtStagesD9mtD3d9() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9mt") == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-d9mt)"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .d9mt

        try PatchService.stageGamePatchFiles(for: version)

        let staged = try Data(contentsOf: gameURL.appendingPathComponent("d3d9.dll"))
        let bundled = try Data(contentsOf: PatchService.resourceURL(
            named: "d3d9", extension: "dll", subdirectory: "Patching/d9mt")!)
        XCTAssertEqual(staged, bundled)
    }

    func testStageGamePatchFilesSwitchingBackToD9vkRestoresD9vkDll() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9mt") == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-d9mt)"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .d9mt
        try PatchService.stageGamePatchFiles(for: version)

        version.settings.renderer = .d9vk
        try PatchService.stageGamePatchFiles(for: version)

        let staged = try Data(contentsOf: gameURL.appendingPathComponent("d3d9.dll"))
        let bundled = try Data(contentsOf: PatchService.resourceURL(
            named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk")!)
        XCTAssertEqual(staged, bundled)
    }

    func testRemoveGamePatchDeletesRosettax87Leftovers() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let staleRosettaURL = gameURL.appendingPathComponent("rosettax87", isDirectory: true)
        try FileManager.default.createDirectory(at: staleRosettaURL, withIntermediateDirectories: true)
        try Data([0x00]).write(to: staleRosettaURL.appendingPathComponent("libRuntimeRosettax87"))

        try PatchService.removeGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRosettaURL.path))
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
