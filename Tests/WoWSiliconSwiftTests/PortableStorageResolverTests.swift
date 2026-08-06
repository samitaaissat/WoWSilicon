import XCTest
@testable import WoWSiliconSwift

final class PortableStorageResolverTests: XCTestCase {
    private var tempURLs: [URL] = []
    private var chmodRestoreURLs: [URL] = []

    override func tearDownWithError() throws {
        // Restore permissions BEFORE removal, or removeItem fails on 0o555 dirs.
        for url in chmodRestoreURLs {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        chmodRestoreURLs.removeAll()
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

    /// (parent, bundleURL, fallbackRoot) — the standard fixture.
    private func makeFixture() throws -> (parent: URL, bundleURL: URL, fallback: URL) {
        let parent = try makeTemporaryDirectory()
        let bundleURL = parent.appendingPathComponent("WoWSilicon.app", isDirectory: true)
        let fallback = try makeTemporaryDirectory()
        return (parent, bundleURL, fallback)
    }

    func testCreatesDataFolderBesideAppWhenParentIsWritable() throws {
        let f = try makeFixture()

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        let expectedRoot = f.parent.appendingPathComponent("WoWSilicon Data", isDirectory: true)
        XCTAssertEqual(storage.location, .besideApp(expectedRoot))
        XCTAssertEqual(storage.reason, .createdBesideApp)
        XCTAssertTrue(storage.isPortable)
        XCTAssertEqual(storage.dataRootURL, expectedRoot)
        XCTAssertEqual(storage.configDirectory, expectedRoot)
        XCTAssertEqual(storage.prefixURL, expectedRoot.appendingPathComponent("prefix", isDirectory: true))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedRoot.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        // README is written at creation time.
        let about = expectedRoot.appendingPathComponent("About this folder.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: about.path))
        // No probe litter left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: expectedRoot.path)
            .filter { $0.hasPrefix(".ws-write-probe-") || $0.hasPrefix(".ws-prefix-probe-") }
        XCTAssertEqual(leftovers, [])
    }

    func testExistingDataFolderWins() throws {
        let f = try makeFixture()
        let existing = f.parent.appendingPathComponent("WoWSilicon Data", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("versions.json")
        try "{}".write(to: marker, atomically: true, encoding: .utf8)

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(storage.location, .besideApp(existing))
        XCTAssertEqual(storage.reason, .existingDataFolder)
        // Existing folder contents are untouched (no About file injected).
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "{}")
    }

    func testReadOnlyParentFallsBackToApplicationSupport() throws {
        let f = try makeFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.parent.path)
        chmodRestoreURLs.append(f.parent)
        try XCTSkipIf(geteuid() == 0, "permissions are not enforced for root")

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        let expectedRoot = f.fallback.appendingPathComponent("WoWSilicon", isDirectory: true)
        XCTAssertEqual(storage.location, .applicationSupport(expectedRoot))
        XCTAssertFalse(storage.isPortable)
        XCTAssertEqual(storage.prefixURL, expectedRoot.appendingPathComponent("prefix", isDirectory: true))
        XCTAssertTrue([.creationFailed, .parentNotWritable].contains(storage.reason))
    }

    func testTranslocatedBundleURLFallsBackWithoutTouchingParent() throws {
        let f = try makeFixture()
        // Simulated translocation mount: the stable "AppTranslocation" component is
        // what production paths contain; the parent is deliberately WRITABLE to
        // prove the check short-circuits before any probe/creation.
        let translocated = f.parent
            .appendingPathComponent("AppTranslocation", isDirectory: true)
            .appendingPathComponent("A1B2C3D4-0000-0000-0000-000000000000", isDirectory: true)
            .appendingPathComponent("d", isDirectory: true)
            .appendingPathComponent("WoWSilicon.app", isDirectory: true)
        try FileManager.default.createDirectory(at: translocated.deletingLastPathComponent(), withIntermediateDirectories: true)

        let storage = PortableStorage(bundleURL: translocated, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(storage.reason, .translocated)
        XCTAssertFalse(storage.isPortable)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: translocated.deletingLastPathComponent().appendingPathComponent("WoWSilicon Data").path))
    }

    func testPlainFileNamedLikeDataFolderFallsBack() throws {
        let f = try makeFixture()
        let blocker = f.parent.appendingPathComponent("WoWSilicon Data")
        try "not a folder".write(to: blocker, atomically: true, encoding: .utf8)

        let storage = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(storage.reason, .blockedByFile)
        XCTAssertFalse(storage.isPortable)
        // The blocking file is preserved, not deleted.
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "not a folder")
    }

    func testResolutionIsIdempotentAcrossInstances() throws {
        let f = try makeFixture()

        let first = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)
        let second = PortableStorage(bundleURL: f.bundleURL, fallbackSupportRoot: f.fallback)

        XCTAssertEqual(first.location, second.location)
        XCTAssertEqual(second.reason, .existingDataFolder)
        XCTAssertEqual(first.prefixURL, second.prefixURL)
    }

    func testCloudSyncedDataRootSplitsPrefixToFallback() throws {
        let parent = try makeTemporaryDirectory()
        // Simulate an iCloud Drive location by path shape — the check is on path
        // containment, which is exactly what production uses.
        let cloudParent = parent
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudParent, withIntermediateDirectories: true)
        let bundleURL = cloudParent.appendingPathComponent("WoWSilicon.app", isDirectory: true)
        let fallback = try makeTemporaryDirectory()

        let storage = PortableStorage(bundleURL: bundleURL, fallbackSupportRoot: fallback)

        XCTAssertTrue(storage.isPortable, "config stays portable on a cloud volume")
        XCTAssertTrue(storage.isPrefixSplit)
        XCTAssertEqual(
            storage.prefixURL,
            fallback.appendingPathComponent("WoWSilicon", isDirectory: true)
                .appendingPathComponent("prefix", isDirectory: true)
        )
    }

    func testWriteProbeReportsReadOnlyDirectory() throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        chmodRestoreURLs.append(dir)
        try XCTSkipIf(geteuid() == 0, "permissions are not enforced for root")

        XCTAssertFalse(PortableStorage.isWritableByProbe(directory: dir, fileManager: .default))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertTrue(PortableStorage.isWritableByProbe(directory: dir, fileManager: .default))
    }
}
