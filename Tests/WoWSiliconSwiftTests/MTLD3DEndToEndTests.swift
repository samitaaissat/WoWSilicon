import XCTest
@testable import WoWSiliconSwift

/// End-to-end proof that a FRESH install renders through mtld3d: staging runs
/// through the real `PatchService` entry points (no hand-copied files), into a
/// brand-new prefix and game folder, and the result is launched under the
/// bundled Wine runtime with a real i386 Direct3D 9 client.
///
/// Opt-in, because it needs artifacts `swift test` alone does not build:
///
///     make bundle
///     WOWSILICON_E2E_RUNTIME=".build/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents" \
///     WOWSILICON_E2E_PROBE="<path>/d3d9probe.exe" \
///     swift test --filter MTLD3DEndToEndTests
///
/// The probe is a mingw-built PE that calls Direct3DCreate9 / CreateDevice /
/// Present and prints `PROBE: driver=<name>`; its source lives in
/// `Tests/Fixtures/d3d9probe.c`.
final class MTLD3DEndToEndTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            // Best effort: a wineserver may still hold the prefix briefly.
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testFreshInstallRendersThroughMTLD3D() throws {
        let runtimeContents = try requireEnvironmentPath("WOWSILICON_E2E_RUNTIME")
        let probeExe = try requireEnvironmentPath("WOWSILICON_E2E_PROBE")

        let gameURL = try makeTemporaryDirectory()
        let prefixURL = try makeTemporaryDirectory()

        // A folder that looks like a supported client, with nothing staged yet.
        try Data([0x4d, 0x5a]).write(to: gameURL.appendingPathComponent("DivxDecoder.dll"))
        try FileManager.default.copyItem(at: probeExe, to: gameURL.appendingPathComponent("d3d9probe.exe"))

        var version = GameVersion(
            id: "e2e",
            displayName: "E2E",
            wowVersion: "3.3.5a",
            gamePath: gameURL.path,
            executableName: "d3d9probe.exe",
            supportsVanillaTweaks: false,
            supportsDLLLoading: false,
            usesRosettaPatching: true,
            usesDivxDecoderPatch: false
        )
        version.settings.renderer = .mtld3d

        // === the real staging code paths ===
        try PatchService.stageGamePatchFiles(for: version)
        try PatchService.installMTLD3DPrefixSupport(winePrefixPath: prefixURL.path)

        let wine = runtimeContents.appendingPathComponent("MacOS/wine")
        let wineserver = runtimeContents.appendingPathComponent("MacOS/wineserver")
        let shim = runtimeContents.appendingPathComponent("MacOS/wine-rosetta-shim")

        var environment = [
            "WINEPREFIX": prefixURL.path,
            "WINESERVER": wineserver.path,
            "WINEMSYNC": "0",
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "mscoree=d;mshtml=d",
        ]
        let boot = try ProcessRunner.run(
            executablePath: wine.path, arguments: ["wineboot", "-u"],
            environment: environment, timeout: 300
        )
        XCTAssertEqual(boot.exitCode, 0, "wineboot failed: \(boot.combinedOutput)")

        // The prefix markers must be re-staged after wineboot: a prefix update
        // rewrites drive_c/windows, and this is exactly the ordering a fresh
        // install hits (bootstrap, then patch).
        try PatchService.installMTLD3DPrefixSupport(winePrefixPath: prefixURL.path)

        // === launch exactly as LaunchService does ===
        environment["WINEDLLOVERRIDES"] = "d3d9=n,b;mscoree=d;mshtml=d"
        environment["X87_SIDECAR_PATH"] = shim.path
        environment["RUST_LOG"] = "mtld3d=info"
        // Not part of the app's launch env: the handshake is silent unless
        // asked, and this test asserts on its progress messages.
        environment["X87_LOGS"] = "1"
        // Wine's err: channel must stay ON for the launch: a failed
        // d3d9 → mtld3d import is reported there and nowhere else, so
        // suppressing it (as the wineboot step does) would make the
        // import_dll assertion below vacuous.
        environment.removeValue(forKey: "WINEDEBUG")
        let run = try ProcessRunner.run(
            executablePath: wine.path,
            arguments: [gameURL.appendingPathComponent("d3d9probe.exe").path],
            environment: environment,
            currentDirectory: gameURL,
            timeout: 300
        )
        let output = run.combinedOutput

        XCTAssertFalse(
            output.contains("import_dll"),
            "the d3d9 → mtld3d import must resolve on a fresh install; got:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("PROBE: driver=mtld3d"),
            "expected mtld3d to be the active D3D9 driver; got:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("PROBE: CreateDevice ok"),
            "expected a working device; got:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("PROBE: DONE ok"),
            "expected the probe to present frames and exit cleanly; got:\n\(output)"
        )
        // The cooperative x87 attach is part of the same launch path. Assert on
        // the sidecar's own evidence that the JIT hook was installed, not just
        // that wine sent the handshake — a reply alone would not prove the
        // translation hook is live.
        XCTAssertTrue(
            output.contains("x87 coop: handshake reply kr=0x0"),
            "expected wine's half of the cooperative handshake to succeed; got:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("cooperative attach:") && output.contains("translate_insn entry patched"),
            "expected x87sidecar to attach and patch translate_insn; got:\n\(output)"
        )

        _ = try? ProcessRunner.run(
            executablePath: wineserver.path, arguments: ["-k"],
            environment: environment, timeout: 30
        )
    }

    private func requireEnvironmentPath(_ name: String) throws -> URL {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) not set; see this file's header for how to run the end-to-end test")
        }
        let url = URL(fileURLWithPath: value)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) points at a missing path: \(value)")
        }
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
