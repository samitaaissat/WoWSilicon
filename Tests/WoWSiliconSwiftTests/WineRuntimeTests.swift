import XCTest
@testable import WoWSiliconSwift

final class WineRuntimeTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    func testPathsAreDerivedFromInjectedBundleURL() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/WoWSilicon.app", isDirectory: true)
        let runtime = WineRuntime(bundleURL: bundleURL)

        let gameApp = "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app"
        XCTAssertEqual(runtime.gameAppURL.path, gameApp)
        XCTAssertEqual(runtime.runtimeRootURL.path, "\(gameApp)/Contents")
        XCTAssertEqual(runtime.wineBinaryURL.path, "\(gameApp)/Contents/MacOS/wine")
        XCTAssertEqual(runtime.wineserverBinaryURL.path, "\(gameApp)/Contents/MacOS/wineserver")
    }

    func testValidatedWineBinaryURLThrowsWineBinaryMissingWhenAbsent() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())

        XCTAssertThrowsError(try runtime.validatedWineBinaryURL()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .wineBinaryMissing(runtime.wineBinaryURL.path))
        }
    }

    func testValidatedWineBinaryURLThrowsWineBinaryNotExecutableForMode644() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        try makeFile(at: runtime.wineBinaryURL, posixPermissions: 0o644)

        XCTAssertThrowsError(try runtime.validatedWineBinaryURL()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .wineBinaryNotExecutable(runtime.wineBinaryURL.path))
        }
    }

    func testValidatedWineBinaryURLReturnsURLWhenExecutable() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        try makeFile(at: runtime.wineBinaryURL, posixPermissions: 0o755)

        XCTAssertEqual(try runtime.validatedWineBinaryURL(), runtime.wineBinaryURL)
    }

    func testRuntimeVersionReadsAndTrimsVersionFile() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        try FileManager.default.createDirectory(at: runtime.runtimeRootURL, withIntermediateDirectories: true)
        try "  1\n".write(to: runtime.runtimeRootURL.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        XCTAssertEqual(runtime.runtimeVersion, "1")
    }

    func testRuntimeVersionIsNilWhenVersionFileAbsent() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())

        XCTAssertNil(runtime.runtimeVersion)
    }

    func testValidatedRosettaLoaderURLReturnsExecutableOverride() throws {
        let loaderURL = try makeTemporaryDirectory().appendingPathComponent("rosettax87")
        try makeFile(at: loaderURL, posixPermissions: 0o755)
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory(), x87LoaderOverride: loaderURL)

        XCTAssertEqual(runtime.x87LoaderURL, loaderURL)
        XCTAssertEqual(try runtime.validatedX87LoaderURL(), loaderURL)
    }

    func testValidatedRosettaLoaderURLThrowsRosettaLoaderMissingWhenOverrideAbsent() throws {
        let loaderURL = try makeTemporaryDirectory().appendingPathComponent("rosettax87")
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory(), x87LoaderOverride: loaderURL)

        XCTAssertThrowsError(try runtime.validatedX87LoaderURL()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .x87LoaderMissing)
        }
    }

    func testGameAppURLUsesBundledPathWhenNoOverrideIsSet() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/WoWSilicon.app", isDirectory: true)
        let runtime = WineRuntime(bundleURL: bundleURL)

        XCTAssertEqual(runtime.gameAppURL, runtime.bundledGameAppURL)
        XCTAssertFalse(runtime.isUsingDownloadedRuntime)
    }

    func testGameAppURLPrefersOverrideWhenItsWineBinaryIsExecutable() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        let overrideRoot = try makeCompleteOverride()

        runtime.setOverrideGameAppURL(overrideRoot)

        XCTAssertEqual(runtime.gameAppURL, overrideRoot)
        XCTAssertTrue(runtime.isUsingDownloadedRuntime)
        XCTAssertEqual(runtime.wineBinaryURL.path, overrideRoot.appendingPathComponent("Contents/MacOS/wine").path)
    }

    /// Regression pin for the "Library mtld3d.dll not found" failure: an
    /// override bundle assembled by an OLDER app build carries a perfectly
    /// good wine binary but none of the mtld3d builtins this build's default
    /// renderer imports. Trusting it makes every launch fail in the game's
    /// loader (`import_dll ... mtld3d.dll not found`) until RuntimeUpdateService
    /// next reconciles — up to 24h later, because its check is debounced.
    /// The runtime must reject such an override immediately.
    func testGameAppURLFallsBackToBundledWhenOverrideLacksMTLD3DBuiltins() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        let overrideRoot = try makeCompleteOverride()
        try FileManager.default.removeItem(
            at: overrideRoot.appendingPathComponent("Contents/lib/wine/i386-windows/mtld3d.dll"))

        runtime.setOverrideGameAppURL(overrideRoot)

        XCTAssertEqual(runtime.gameAppURL, runtime.bundledGameAppURL)
        XCTAssertFalse(runtime.isUsingDownloadedRuntime)
    }

    /// The PE half is useless without its unix half — wine pairs them by name.
    func testGameAppURLFallsBackToBundledWhenOverrideLacksMTLD3DUnixLibrary() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        let overrideRoot = try makeCompleteOverride()
        try FileManager.default.removeItem(
            at: overrideRoot.appendingPathComponent("Contents/lib/wine/x86_64-unix/mtld3d.so"))

        runtime.setOverrideGameAppURL(overrideRoot)

        XCTAssertEqual(runtime.gameAppURL, runtime.bundledGameAppURL)
        XCTAssertFalse(runtime.isUsingDownloadedRuntime)
    }

    /// An override from before the x87sidecar switch has no sidecar binary, so
    /// the shim's exec would fail for every i386 image.
    func testGameAppURLFallsBackToBundledWhenOverrideLacksX87Sidecar() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        let overrideRoot = try makeCompleteOverride()
        try FileManager.default.removeItem(
            at: overrideRoot.appendingPathComponent("Contents/MacOS/x87sidecar"))

        runtime.setOverrideGameAppURL(overrideRoot)

        XCTAssertEqual(runtime.gameAppURL, runtime.bundledGameAppURL)
        XCTAssertFalse(runtime.isUsingDownloadedRuntime)
    }

    /// A structurally complete override runtime: an executable wine, the
    /// x87sidecar the shim execs, and the mtld3d builtin trio the default
    /// renderer needs.
    private func makeCompleteOverride() throws -> URL {
        let root = try makeTemporaryDirectory().appendingPathComponent("Override Game.app", isDirectory: true)
        try makeFile(at: root.appendingPathComponent("Contents/MacOS/wine"), posixPermissions: 0o755)
        try makeFile(at: root.appendingPathComponent("Contents/MacOS/x87sidecar"), posixPermissions: 0o755)
        for relative in [
            "Contents/lib/wine/i386-windows/mtld3d.dll",
            "Contents/lib/wine/x86_64-windows/mtld3d.dll",
            "Contents/lib/wine/x86_64-unix/mtld3d.so",
        ] {
            try makeFile(at: root.appendingPathComponent(relative), posixPermissions: 0o644)
        }
        return root
    }

    func testGameAppURLFallsBackToBundledWhenOverrideWineBinaryIsMissing() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        let overrideRoot = try makeTemporaryDirectory().appendingPathComponent("Override Game.app", isDirectory: true)
        // Override directory exists but was never populated with a wine binary.

        runtime.setOverrideGameAppURL(overrideRoot)

        XCTAssertEqual(runtime.gameAppURL, runtime.bundledGameAppURL)
        XCTAssertFalse(runtime.isUsingDownloadedRuntime)
    }

    func testGameAppURLFallsBackToBundledWhenOverrideWineBinaryIsNotExecutable() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        let overrideRoot = try makeTemporaryDirectory().appendingPathComponent("Override Game.app", isDirectory: true)
        try makeFile(at: overrideRoot.appendingPathComponent("Contents/MacOS/wine"), posixPermissions: 0o644)

        runtime.setOverrideGameAppURL(overrideRoot)

        XCTAssertEqual(runtime.gameAppURL, runtime.bundledGameAppURL)
        XCTAssertFalse(runtime.isUsingDownloadedRuntime)
    }

    func testSetOverrideGameAppURLBackToNilRestoresBundledPath() throws {
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory())
        let overrideRoot = try makeCompleteOverride()

        runtime.setOverrideGameAppURL(overrideRoot)
        XCTAssertTrue(runtime.isUsingDownloadedRuntime)

        runtime.setOverrideGameAppURL(nil)
        XCTAssertEqual(runtime.gameAppURL, runtime.bundledGameAppURL)
        XCTAssertFalse(runtime.isUsingDownloadedRuntime)
    }

    private func makeFile(at url: URL, posixPermissions: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: posixPermissions], ofItemAtPath: url.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }
}
