import XCTest
@testable import WoWSiliconSwift

/// Covers `PatchService.resourceURL`'s d9mt override lookup — the seam
/// `RuntimeUpdateService` uses to make a downloaded d9mt payload take
/// precedence over the one bundled with the app. Every test passes
/// `overrideDirectory:` explicitly rather than touching the
/// `PatchService.d9mtOverrideDirectory` static var, so nothing here can leak
/// state into other tests in the same process.
final class PatchServiceD9MTOverrideTests: XCTestCase {
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

    func testResourceURLPrefersOverrideDirectoryForD3D9() throws {
        let overrideRoot = try makeTemporaryDirectory()
        let marker = Data("override-d3d9".utf8)
        try marker.write(to: overrideRoot.appendingPathComponent("d3d9.dll"))

        let resolved = PatchService.resourceURL(
            named: "d3d9", extension: "dll", subdirectory: "Patching/d9mt", overrideDirectory: overrideRoot
        )

        XCTAssertEqual(resolved?.path, overrideRoot.appendingPathComponent("d3d9.dll").path)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(resolved)), marker)
    }

    func testResourceURLPrefersOverrideDirectoryForNestedWinemetalPath() throws {
        let overrideRoot = try makeTemporaryDirectory()
        let nested = overrideRoot.appendingPathComponent("winemetal/x86_64-windows", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let marker = Data("override-winemetal".utf8)
        try marker.write(to: nested.appendingPathComponent("winemetal.dll"))

        let resolved = PatchService.resourceURL(
            named: "winemetal", extension: "dll",
            subdirectory: "Patching/d9mt/winemetal/x86_64-windows",
            overrideDirectory: overrideRoot
        )

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(resolved)), marker)
    }

    func testResourceURLReturnsNilWhenNeitherOverrideNorBundleHasTheFile() throws {
        let overrideRoot = try makeTemporaryDirectory() // empty

        let resolved = PatchService.resourceURL(
            named: "totally-fake-resource-name", extension: "dll", subdirectory: "Patching/d9mt", overrideDirectory: overrideRoot
        )

        XCTAssertNil(resolved)
    }

    func testResourceURLIgnoresOverrideForUnrelatedSubdirectories() throws {
        let overrideRoot = try makeTemporaryDirectory()
        let markerName = "totally-fake-resource-name"
        try Data("marker".utf8).write(to: overrideRoot.appendingPathComponent("\(markerName).dll"))

        // Patching/d9vk (and anything else) must never consult the d9mt cache.
        let resolved = PatchService.resourceURL(
            named: markerName, extension: "dll", subdirectory: "Patching/d9vk", overrideDirectory: overrideRoot
        )

        XCTAssertNil(resolved, "the d9mt override must never be consulted for a non-d9mt subdirectory")
    }

    func testResourceURLTreatsNilOverrideAsNoOverride() throws {
        let resolved = PatchService.resourceURL(
            named: "totally-fake-resource-name", extension: "dll", subdirectory: "Patching/d9mt", overrideDirectory: nil
        )

        XCTAssertNil(resolved)
    }
}
