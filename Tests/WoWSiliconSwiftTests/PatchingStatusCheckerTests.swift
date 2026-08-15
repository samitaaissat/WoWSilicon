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

        // d9vk bytes are staged, so the version must be configured for d9vk
        // (the default renderer is mtld3d and would flag them outdated).
        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .d9vk

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

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

    /// mtld3d uses the native-override route: the staged d3d9.dll must match the
    /// bundle's native i386 PE for the checksum tier to read Applied.
    func testGamePatchAppliedWithMTLD3DPayloadWhenRendererIsMTLD3D() throws {
        let winerosettaSource = PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta")
        let d3d9MTLD3DSource = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows")
        try XCTSkipIf(
            winerosettaSource == nil || d3d9MTLD3DSource == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-mtld3d); existence tier covered by other tests"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: winerosettaSource!, to: modsURL.appendingPathComponent("winerosetta.dll"))
        try FileManager.default.copyItem(at: d3d9MTLD3DSource!, to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .mtld3d

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

        XCTAssertTrue(descriptor.applied, "expected Applied, got: \(descriptor.text)")
        XCTAssertEqual(descriptor.text, "Applied")
        XCTAssertEqual(descriptor.level, .success)
    }

    /// Renderer-aware freshness for mtld3d: a d3d9.dll carrying the d9vk payload
    /// bytes must be flagged outdated when the version is configured for mtld3d.
    func testGamePatchFlagsD9vkStagedDllOutdatedWhenRendererIsMTLD3D() throws {
        let winerosettaSource = PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta")
        let d3d9D9vkSource = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk")
        let d3d9MTLD3DSource = PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows")
        try XCTSkipIf(
            winerosettaSource == nil || d3d9D9vkSource == nil || d3d9MTLD3DSource == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-mtld3d); existence tier covered by other tests"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: winerosettaSource!, to: modsURL.appendingPathComponent("winerosetta.dll"))
        try FileManager.default.copyItem(at: d3d9D9vkSource!, to: gameURL.appendingPathComponent("d3d9.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .mtld3d

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "d3d9.dll outdated")
        XCTAssertEqual(descriptor.level, .warning)
    }

    /// mtld3d requires the native-override d3d9.dll like every other renderer —
    /// a missing file is an error, not Applied (unlike the removed wined3d).
    func testGamePatchRequiresD3d9WhenRendererIsMTLD3D() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
        try Data([0x01]).write(to: modsURL.appendingPathComponent("winerosetta.dll"))
        try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
        // Deliberately NO <game>/d3d9.dll.

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .mtld3d

        let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Missing d3d9.dll")
        XCTAssertEqual(descriptor.level, .error)
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

    /// Mutation guard: every renderer REQUIRES the staged d3d9.dll. Without this
    /// pin, dropping the required-file append silently passes the suite — and a
    /// user with a deleted d3d9.dll would read "Applied" and launch into wine's
    /// builtin d3d9 instead of the selected backend.
    func testGamePatchRequiresD3d9ForEveryRenderer() throws {
        for renderer in RendererBackend.allCases {
            let gameURL = try makeTemporaryDirectory()
            try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
            let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
            try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
            try Data([0x01]).write(to: modsURL.appendingPathComponent("winerosetta.dll"))
            try "mods/winerosetta.dll\n".write(to: gameURL.appendingPathComponent("dlls.txt"), atomically: true, encoding: .utf8)
            // Deliberately NO <game>/d3d9.dll.

            var version = makeVersion(gameURL: gameURL)
            version.settings.renderer = renderer

            let descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)

            XCTAssertFalse(descriptor.applied, "\(renderer) must require d3d9.dll")
            XCTAssertEqual(descriptor.text, "Missing d3d9.dll")
            XCTAssertEqual(descriptor.level, .error)
        }
    }

    /// The usesDivxDecoderPatch tier requires d3d9.dll for every renderer too;
    /// pure file-existence logic, no bundle resources needed.
    func testDivxTierRequiresD3d9() throws {
        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        let version = makeVersion(gameURL: gameURL, usesRosettaPatching: false, usesDivxDecoderPatch: true)

        // No d3d9.dll: still required (default renderer, mtld3d).
        var descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)
        XCTAssertFalse(descriptor.applied)
        XCTAssertEqual(descriptor.text, "Missing d3d9.dll")

        // With it: Applied (the divx tier has no checksum stage).
        try Data([0x02]).write(to: gameURL.appendingPathComponent("d3d9.dll"))
        descriptor = PatchingStatusChecker.evaluateGamePatch(for: version)
        XCTAssertTrue(descriptor.applied, "expected Applied, got: \(descriptor.text)")
        XCTAssertEqual(descriptor.text, "Applied")
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
