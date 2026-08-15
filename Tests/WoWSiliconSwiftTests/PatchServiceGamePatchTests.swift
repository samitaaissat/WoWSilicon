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
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows") == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-mtld3d)"
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

    /// Runtime-dependent like the other game-patch tests: the sources live in the
    /// Patching/d9mt bundle resources (SPM resource bundle under swift test), so
    /// skip when they are not resolvable (run make fetch-d9mt).
    func testInstallD9MTPrefixSupportCopiesWinemetalAndD9mtmetalIntoPrefix() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winemetal", extension: "dll", subdirectory: "Patching/d9mt/winemetal/x86_64-windows") == nil
                || PatchService.resourceURL(named: "winemetal", extension: "dll", subdirectory: "Patching/d9mt/winemetal/i386-windows") == nil
                || PatchService.resourceURL(named: "winemetal", extension: "so", subdirectory: "Patching/d9mt/winemetal/x86_64-unix") == nil
                || PatchService.resourceURL(named: "d9mtmetal", extension: "dll", subdirectory: "Patching/d9mt/d9mtmetal/x86_64-windows") == nil
                || PatchService.resourceURL(named: "d9mtmetal", extension: "dll", subdirectory: "Patching/d9mt/d9mtmetal/i386-windows") == nil
                || PatchService.resourceURL(named: "d9mtmetal", extension: "so", subdirectory: "Patching/d9mt/d9mtmetal/x86_64-unix") == nil,
            "Bundled d9mt resources not resolvable under swift test (run make fetch-d9mt)"
        )

        let prefixURL = try makeTemporaryDirectory()
        // A bootstrapped prefix has system32/syswow64 but no x86_64-unix directory;
        // installD9MTPrefixSupport must create whatever destination dir is missing.
        try FileManager.default.createDirectory(
            at: prefixURL.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefixURL.appendingPathComponent("drive_c/windows/syswow64"), withIntermediateDirectories: true)

        try PatchService.installD9MTPrefixSupport(winePrefixPath: prefixURL.path)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefixURL.appendingPathComponent("drive_c/windows/system32/winemetal.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefixURL.appendingPathComponent("drive_c/windows/syswow64/winemetal.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefixURL.appendingPathComponent("drive_c/windows/x86_64-unix/winemetal.so").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefixURL.appendingPathComponent("drive_c/windows/system32/d9mtmetal.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefixURL.appendingPathComponent("drive_c/windows/syswow64/d9mtmetal.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prefixURL.appendingPathComponent("drive_c/windows/x86_64-unix/d9mtmetal.so").path))

        // Arch-sensitive: the 64-bit PE goes to system32, the 32-bit PE to syswow64.
        for dll in ["winemetal", "d9mtmetal"] {
            let staged64 = try Data(contentsOf: prefixURL.appendingPathComponent("drive_c/windows/system32/\(dll).dll"))
            let bundled64 = try Data(contentsOf: PatchService.resourceURL(
                named: dll, extension: "dll", subdirectory: "Patching/d9mt/\(dll)/x86_64-windows")!)
            XCTAssertEqual(staged64, bundled64, "system32/\(dll).dll must be the x86_64-windows build")

            let staged32 = try Data(contentsOf: prefixURL.appendingPathComponent("drive_c/windows/syswow64/\(dll).dll"))
            let bundled32 = try Data(contentsOf: PatchService.resourceURL(
                named: dll, extension: "dll", subdirectory: "Patching/d9mt/\(dll)/i386-windows")!)
            XCTAssertEqual(staged32, bundled32, "syswow64/\(dll).dll must be the i386-windows build")
        }
    }

    /// mtld3d native-override route: the staged d3d9.dll must be the bundle's
    /// unmarked native i386 PE, and the self-documenting sample mtld3d.conf is
    /// staged beside it.
    func testStageGamePatchFilesWithMTLD3DStagesNativeD3d9AndConf() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows") == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-mtld3d)"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .mtld3d
        try PatchService.stageGamePatchFiles(for: version)

        let staged = try Data(contentsOf: gameURL.appendingPathComponent("d3d9.dll"))
        let bundled = try Data(contentsOf: PatchService.resourceURL(
            named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows")!)
        XCTAssertEqual(staged, bundled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("mtld3d.conf").path))

        // The builtin-name marker must sit beside d3d9.dll too: wine searches the
        // exe's own directory before the prefix system dirs, so this keeps the
        // import resolvable even when a wineboot prefix refresh drops the
        // system32/syswow64 copies.
        let stagedMarker = try Data(contentsOf: gameURL.appendingPathComponent("mtld3d.dll"))
        let bundledMarker = try Data(contentsOf: PatchService.resourceURL(
            named: "mtld3d.fake", extension: "dll", subdirectory: "Patching/mtld3d/wine/i386-windows")!)
        XCTAssertEqual(stagedMarker, bundledMarker, "<game>/mtld3d.dll must be the i386 fake-dll marker")
    }

    /// Switching away from mtld3d must not leave the marker behind: a stray
    /// mtld3d.dll next to a d9vk/d9mt d3d9.dll is a dangling builtin name.
    func testStageGamePatchFilesRemovesMTLD3DMarkerWhenSwitchingAway() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows") == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-mtld3d)"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .mtld3d
        try PatchService.stageGamePatchFiles(for: version)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("mtld3d.dll").path))

        version.settings.renderer = .d9vk
        try PatchService.stageGamePatchFiles(for: version)

        XCTAssertFalse(FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("mtld3d.dll").path))
    }

    /// mtld3d.conf is user-editable runtime configuration: re-staging must never
    /// clobber an existing copy, and switching renderers must leave it in place.
    func testStageGamePatchFilesNeverOverwritesUserEditedMTLD3DConf() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows") == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-mtld3d)"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        let userConf = "render.scale = 0.5\n"
        try userConf.write(to: gameURL.appendingPathComponent("mtld3d.conf"), atomically: true, encoding: .utf8)

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .mtld3d
        try PatchService.stageGamePatchFiles(for: version)

        XCTAssertEqual(
            try String(contentsOf: gameURL.appendingPathComponent("mtld3d.conf"), encoding: .utf8),
            userConf
        )
    }

    func testStageGamePatchFilesSwitchingFromMTLD3DBackToD9vkRestoresD9vkD3d9() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk") == nil
                || PatchService.resourceURL(named: "d3d9", extension: "dll", subdirectory: "Patching/mtld3d/native/i386-windows") == nil,
            "Bundled patch resources not resolvable under swift test (run make fetch-mtld3d)"
        )

        let gameURL = try makeTemporaryDirectory()
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))

        var version = makeVersion(gameURL: gameURL)
        version.settings.renderer = .mtld3d
        try PatchService.stageGamePatchFiles(for: version)

        version.settings.renderer = .d9vk
        try PatchService.stageGamePatchFiles(for: version)

        let staged = try Data(contentsOf: gameURL.appendingPathComponent("d3d9.dll"))
        let bundled = try Data(contentsOf: PatchService.resourceURL(
            named: "d3d9", extension: "dll", subdirectory: "Patching/d9vk")!)
        XCTAssertEqual(staged, bundled)
    }

    /// mtld3d prefix support stages the fake-dll markers (arch-sensitive: the
    /// i386 marker to syswow64, the x86_64 marker to system32) so wine can
    /// resolve the custom builtin name in any prefix.
    func testInstallMTLD3DPrefixSupportStagesFakeDllMarkers() throws {
        try XCTSkipIf(
            PatchService.resourceURL(named: "mtld3d.fake", extension: "dll", subdirectory: "Patching/mtld3d/wine/i386-windows") == nil
                || PatchService.resourceURL(named: "mtld3d.fake", extension: "dll", subdirectory: "Patching/mtld3d/wine/x86_64-windows") == nil,
            "Bundled mtld3d resources not resolvable under swift test (run make fetch-mtld3d)"
        )

        let prefixURL = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: prefixURL.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefixURL.appendingPathComponent("drive_c/windows/syswow64"), withIntermediateDirectories: true)

        try PatchService.installMTLD3DPrefixSupport(winePrefixPath: prefixURL.path)

        let staged32 = try Data(contentsOf: prefixURL.appendingPathComponent("drive_c/windows/syswow64/mtld3d.dll"))
        let bundled32 = try Data(contentsOf: PatchService.resourceURL(
            named: "mtld3d.fake", extension: "dll", subdirectory: "Patching/mtld3d/wine/i386-windows")!)
        XCTAssertEqual(staged32, bundled32, "syswow64/mtld3d.dll must be the i386-windows marker")

        let staged64 = try Data(contentsOf: prefixURL.appendingPathComponent("drive_c/windows/system32/mtld3d.dll"))
        let bundled64 = try Data(contentsOf: PatchService.resourceURL(
            named: "mtld3d.fake", extension: "dll", subdirectory: "Patching/mtld3d/wine/x86_64-windows")!)
        XCTAssertEqual(staged64, bundled64, "system32/mtld3d.dll must be the x86_64-windows marker")
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
