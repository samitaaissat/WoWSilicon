import XCTest
@testable import WoWSiliconSwift

final class PrefixBootstrapServiceTests: XCTestCase {
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

    /// A fake .app bundle carrying an executable wine/wineserver and a VERSION file.
    private func makeFakeRuntimeBundle(version: String) throws -> URL {
        let bundleURL = try makeTemporaryDirectory().appendingPathComponent("WoWSilicon.app", isDirectory: true)
        let binDir = bundleURL.appendingPathComponent("Contents/SharedSupport/wine/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            let url = binDir.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try version.write(
            to: bundleURL.appendingPathComponent("Contents/SharedSupport/wine/VERSION"),
            atomically: true, encoding: .utf8)
        return bundleURL
    }

    private func makeStorage() throws -> PortableStorage {
        let parent = try makeTemporaryDirectory()
        return PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: try makeTemporaryDirectory()
        )
    }

    /// Writes the structure wineboot would have produced.
    private func materializePrefixStructure(at prefix: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices", isDirectory: true), withIntermediateDirectories: true)
        try "WINE REGISTRY Version 2".write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2".write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            atPath: prefix.appendingPathComponent("dosdevices/c:").path,
            withDestinationPath: "../drive_c")
    }

    func testBootstrapRunsWinebootThenWineserverAndWritesSentinel() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))
        final class Recorder: @unchecked Sendable { var invocations: [[String]] = [] }
        let recorder = Recorder()

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { exe, args, env, timeout in
            recorder.invocations.append([exe] + args)
            XCTAssertEqual(env["WINEPREFIX"], storage.prefixURL.path)
            if args.first == "wineboot" {
                XCTAssertEqual(timeout, 600)
                // Simulate wineboot creating the prefix structure
                let fm = FileManager.default
                let prefix = storage.prefixURL
                try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows", isDirectory: true), withIntermediateDirectories: true)
                try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices", isDirectory: true), withIntermediateDirectories: true)
                try "WINE REGISTRY Version 2".write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
                try "WINE REGISTRY Version 2".write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
                try fm.createSymbolicLink(
                    atPath: prefix.appendingPathComponent("dosdevices/c:").path,
                    withDestinationPath: "../drive_c")
            }
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertFalse(service.isPrefixReady())
        try service.bootstrapIfNeeded()

        XCTAssertEqual(recorder.invocations.count, 2)
        XCTAssertEqual(Array(recorder.invocations[0].dropFirst()), ["wineboot", "-u"])
        XCTAssertTrue(recorder.invocations[1][0].hasSuffix("/wineserver"))
        XCTAssertEqual(Array(recorder.invocations[1].dropFirst()), ["-w"])
        XCTAssertTrue(service.isPrefixReady())
        let sentinel = storage.prefixURL.appendingPathComponent(".wowsilicon-prefix-ok")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "wine-14 (test)")
    }

    func testBootstrapIfNeededNoOpsWhenSentinelMatches() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))
        try materializePrefixStructure(at: storage.prefixURL)
        try "wine-14 (test)".write(
            to: storage.prefixURL.appendingPathComponent(".wowsilicon-prefix-ok"),
            atomically: true, encoding: .utf8)

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { _, _, _, _ in
            XCTFail("must not spawn wine when the sentinel matches")
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertTrue(service.isPrefixReady())
        try service.bootstrapIfNeeded()
    }

    func testRuntimeVersionMismatchTriggersRebootstrap() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-15 (new)"))
        try materializePrefixStructure(at: storage.prefixURL)
        try "wine-14 (old)".write(
            to: storage.prefixURL.appendingPathComponent(".wowsilicon-prefix-ok"),
            atomically: true, encoding: .utf8)

        XCTAssertFalse(PrefixBootstrapService(storage: storage, runtime: runtime,
                                              runner: { _, _, _, _ in ProcessRunResult(exitCode: 0, stdout: "", stderr: "") })
            .isPrefixReady())
    }

    func testWinebootFailureCleansHalfBuiltPrefixAndThrows() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { _, args, _, _ in
            if args.first == "wineboot" {
                return ProcessRunResult(exitCode: 1, stdout: "", stderr: "boom")
            }
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertThrowsError(try service.bootstrapIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.prefixURL.path),
                       "half-built prefix must be deleted so the next attempt starts clean")
    }

    func testTimeoutCleansPrefixViaGracefulWineserverKill() throws {
        let storage = try makeStorage()
        let runtime = WineRuntime(bundleURL: try makeFakeRuntimeBundle(version: "wine-14 (test)"))
        final class Recorder: @unchecked Sendable { var killIssued = false }
        let recorder = Recorder()

        let service = PrefixBootstrapService(storage: storage, runtime: runtime, runner: { exe, args, _, _ in
            if args.first == "wineboot" { throw ProcessRunnerError.timedOut(600) }
            if exe.hasSuffix("/wineserver"), args == ["-k"] { recorder.killIssued = true }
            return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
        })

        XCTAssertThrowsError(try service.bootstrapIfNeeded()) { error in
            guard case PrefixBootstrapError.timedOut = error else {
                return XCTFail("expected .timedOut, got \(error)")
            }
        }
        XCTAssertTrue(recorder.killIssued, "timeout path must ask wineserver to shut down cleanly, never SIGKILL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.prefixURL.path))
    }
}
