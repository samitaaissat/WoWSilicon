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

    /// Renderer-aware freshness: a d3d9.dll matching the bundled d9vk payload
    /// must be flagged outdated for a d9mt-configured version (the checker has
    /// to compare against Patching/d9mt instead of Patching/d9vk).
    func testGamePatchFlagsD9vkStagedDllOutdatedWhenRendererIsD9mt() throws {
        let winerosettaSource = PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta")
        let d3d9D9vkSource = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk")
        let d3d9D9mtSource = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9mt")
        try XCTSkipIf(
            winerosettaSource == nil || d3d9D9vkSource == nil || d3d9D9mtSource == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-d9mt); existence tier covered by other tests"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: winerosettaSource!, to: modsURL.appendingPathComponent("winerosetta.dll"))
        // Game folder carries the d9vk payload bytes...
        try FileManager.default.copyItem(at: d3d9D9vkSource!, to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)

        var version = makeVersion(gameURL: gameURL)
        // ...but the version is configured for d9mt.
        version.settings.renderer = .d9mt

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "d3d9.dll outdated")
        XCTAssertEqual(descriptor.level, .warning)
    }

    /// Converse of the above: with the d9mt payload staged and the renderer
    /// set to d9mt, the checksum tier must accept the folder as Applied.
    func testGamePatchAppliedWithD9mtPayloadWhenRendererIsD9mt() throws {
        let winerosettaSource = PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta")
        let d3d9D9mtSource = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9mt")
        try XCTSkipIf(
            winerosettaSource == nil || d3d9D9mtSource == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-d9mt); existence tier covered by other tests"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: winerosettaSource!, to: modsURL.appendingPathComponent("winerosetta.dll"))
        try FileManager.default.copyItem(at: d3d9D9mtSource!, to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .d9mt

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

        XCTAssertTrue(descriptor.applied, "expected Applied, got: \(descriptor.text)")
        XCTAssertEqual(descriptor.text, "Applied")
        XCTAssertEqual(descriptor.level, .success)
    }

    /// wined3d stages no d3d9.dll: an otherwise-patched folder without one must
    /// read Applied (through the checksum tier, so the real winerosetta bytes
    /// are staged; skipped when the resource bundle is unreachable).
    func testGamePatchAppliedWithoutD3d9WhenRendererIsWineD3D() throws {
        let winerosettaSource = PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta")
        try XCTSkipIf(
            winerosettaSource == nil,
            "Bundled patch resources not resolvable under swift test; existence tier covered by other tests"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: winerosettaSource!, to: modsURL.appendingPathComponent("winerosetta.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
        // Deliberately NO <game>/d3d9.dll.

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .wined3d

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

        XCTAssertTrue(descriptor.applied, "expected Applied, got: \(descriptor.text)")
        XCTAssertEqual(descriptor.text, "Applied")
        XCTAssertEqual(descriptor.level, .success)
    }

    /// Converse: a leftover d3d9.dll under the wined3d renderer means the folder
    /// was staged for another renderer and needs a re-patch.
    func testGamePatchFlagsLeftoverD3d9WhenRendererIsWineD3D() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try Data([0x01]).write(to: modsURL.appendingPathComponent("winerosetta.dll"))
        try Data([0x02]).write(to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .wined3d

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Leftover d3d9.dll")
        XCTAssertEqual(descriptor.level, .warning)
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

    /// Mutation guard for making the d3d9.dll requirement renderer-conditional:
    /// d9vk (and d9mt) must still REQUIRE the file. Without this pin, dropping
    /// the conditional append silently passes the suite — and a d9vk user with a
    /// deleted d3d9.dll would read "Applied" and launch into the builtin
    /// fallback (no WINE_D3D_CONFIG → no-3D GDI, black screen).
    func testGamePatchStillRequiresD3d9ForD9vk() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try Data([0x01]).write(to: modsURL.appendingPathComponent("winerosetta.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
        // Deliberately NO <game>/d3d9.dll, renderer left at the .d9vk default.

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: makeVersion(gameURL: gameURL))

        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Missing d3d9.dll")
        XCTAssertEqual(descriptor.level, .error)
    }

    /// The usesDivxDecoderPatch tier mirrors the rosetta tier's renderer
    /// conditionals; pure file-existence logic, no bundle resources needed.
    func testDivxTierRendererConditionals() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        var version = makeVersion(gameURL: gameURL, usesRosettaPatching: false, usesDivxDecoderPatch: true)

        // d9vk without d3d9.dll: still required.
        var descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)
        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Missing d3d9.dll")

        // wined3d without d3d9.dll: Applied.
        version.settings.renderer = .wined3d
        descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)
        XCTAssertTrue(descriptor.applied, "expected Applied, got: \(descriptor.text)")
        XCTAssertEqual(descriptor.text, "Applied")

        // wined3d with a leftover d3d9.dll: needs a re-patch.
        try Data([0x02]).write(to: gameURL.appendingPathComponent("d3d9.dll"))
        descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)
        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Leftover d3d9.dll")
        XCTAssertEqual(descriptor.level, .warning)
    }

    private func makeVersion(
        gameURL: URL,
        usesRosettaPatching: Bool = true,
        usesDivxDecoderPatch: Bool = false
    ) -> GameVersion {
        GameVersion(
            id: "test",
            displayName: "Test",
            wowVersion: "2.4.3",
            gamePath: gameURL.path,
            executableName: "WoW.exe",
            supportsVanillaTweaks: false,
            supportsDLLLoading: false,
            usesRosettaPatching: usesRosettaPatching,
            usesDivxDecoderPatch: usesDivxDecoderPatch
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
