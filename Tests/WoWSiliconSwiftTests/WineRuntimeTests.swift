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

        XCTAssertEqual(runtime.runtimeRootURL.path, "/Applications/WoWSilicon.app/Contents/SharedSupport/wine")
        XCTAssertEqual(runtime.wineBinaryURL.path, "/Applications/WoWSilicon.app/Contents/SharedSupport/wine/bin/wine")
        XCTAssertEqual(runtime.wineserverBinaryURL.path, "/Applications/WoWSilicon.app/Contents/SharedSupport/wine/bin/wineserver")
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
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory(), rosettaLoaderOverride: loaderURL)

        XCTAssertEqual(runtime.rosettaLoaderURL, loaderURL)
        XCTAssertEqual(try runtime.validatedRosettaLoaderURL(), loaderURL)
    }

    func testValidatedRosettaLoaderURLThrowsRosettaLoaderMissingWhenOverrideAbsent() throws {
        let loaderURL = try makeTemporaryDirectory().appendingPathComponent("rosettax87")
        let runtime = WineRuntime(bundleURL: try makeTemporaryDirectory(), rosettaLoaderOverride: loaderURL)

        XCTAssertThrowsError(try runtime.validatedRosettaLoaderURL()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .rosettaLoaderMissing)
        }
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
