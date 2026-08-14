import XCTest
@testable import WoWSiliconSwift

final class RuntimeUpdateServiceTests: XCTestCase {
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

    /// A besideApp PortableStorage rooted in a fresh temp directory, mirroring
    /// PrefixBootstrapServiceTests' fixture.
    private func makeStorage() throws -> (storage: PortableStorage, dataRoot: URL) {
        let parent = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: try makeTemporaryDirectory()
        )
        return (storage, storage.dataRootURL)
    }

    private func makeExecutable(at url: URL, content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A fake bundled nested game bundle with the pieces a wine-only overlay
    /// must leave untouched (wine-rosetta-shim) alongside the wine binary
    /// itself, so tests can prove the baseline survives an overlay.
    private func makeFakeBundledGameApp(wineMarker: String) throws -> WineRuntime {
        let outerAppURL = try makeTemporaryDirectory().appendingPathComponent("WoWSilicon.app", isDirectory: true)
        let runtime = WineRuntime(bundleURL: outerAppURL)
        try makeExecutable(at: runtime.wineBinaryURL, content: wineMarker)
        try makeExecutable(at: runtime.executablesDirectoryURL.appendingPathComponent("wine-rosetta-shim"), content: "shim")
        try FileManager.default.createDirectory(
            at: runtime.runtimeRootURL.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtime.runtimeRootURL.appendingPathComponent("share", isDirectory: true),
            withIntermediateDirectories: true)
        try "bundled VERSION\n".write(
            to: runtime.runtimeRootURL.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        return runtime
    }

    private func makeFakeWineCache(storage: PortableStorage, wineMarker: String) throws {
        let cache = RuntimeUpdatePaths.wineCacheDirectory(storage: storage)
        try makeExecutable(at: cache.appendingPathComponent("bin/wine"), content: wineMarker)
        try makeExecutable(at: cache.appendingPathComponent("lib/wine/x86_64-unix/wine"), content: wineMarker)
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("share", isDirectory: true), withIntermediateDirectories: true)
        try "cached VERSION\n".write(to: cache.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
    }

    private func writeFile(at url: URL, content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeFakeD9MTCache(storage: PortableStorage, marker: String) throws {
        let cache = RuntimeUpdatePaths.d9mtCacheDirectory(storage: storage)
        try writeFile(at: cache.appendingPathComponent("winemetal/i386-windows/winemetal.dll"), content: marker)
        try writeFile(at: cache.appendingPathComponent("winemetal/x86_64-windows/winemetal.dll"), content: marker)
        try writeFile(at: cache.appendingPathComponent("winemetal/x86_64-unix/winemetal.so"), content: marker)
        try writeFile(at: cache.appendingPathComponent("d9mtmetal/i386-windows/d9mtmetal.dll"), content: marker)
        try writeFile(at: cache.appendingPathComponent("d9mtmetal/x86_64-windows/d9mtmetal.dll"), content: marker)
        try writeFile(at: cache.appendingPathComponent("d9mtmetal/x86_64-unix/d9mtmetal.so"), content: marker)
        try writeFile(at: cache.appendingPathComponent("d3d9.dll"), content: marker)
    }

    private func makeService(
        storage: PortableStorage,
        runtime: WineRuntime,
        bundledWineVersion: Int,
        bundledD9MTVersion: Int
    ) -> RuntimeUpdateService {
        RuntimeUpdateService(
            session: URLSession(configuration: .ephemeral),
            storage: storage,
            runtime: runtime,
            fileManager: .default,
            bundledWineVersion: bundledWineVersion,
            bundledD9MTVersion: bundledD9MTVersion
        )
    }

    // MARK: - Filename / checksum parsing

    func testWineTarballVersionParsesExpectedFilenames() {
        XCTAssertEqual(RuntimeUpdateService.wineTarballVersion(filename: "wowsilicon-wine-1-osx64.tar.xz"), 1)
        XCTAssertEqual(RuntimeUpdateService.wineTarballVersion(filename: "wowsilicon-wine-42-osx64.tar.xz"), 42)
        XCTAssertNil(RuntimeUpdateService.wineTarballVersion(filename: "wowsilicon-wine-1-osx64.tar.xz.sha256"))
        XCTAssertNil(RuntimeUpdateService.wineTarballVersion(filename: "wowsilicon-wine-osx64.tar.xz"))
        XCTAssertNil(RuntimeUpdateService.wineTarballVersion(filename: "d9mt-3.tar.gz"))
    }

    func testD9MTTarballVersionParsesExpectedFilenames() {
        XCTAssertEqual(RuntimeUpdateService.d9mtTarballVersion(filename: "d9mt-3.tar.gz"), 3)
        XCTAssertNil(RuntimeUpdateService.d9mtTarballVersion(filename: "d9mt-3.tar.gz.sha256"))
        XCTAssertNil(RuntimeUpdateService.d9mtTarballVersion(filename: "wowsilicon-wine-3-osx64.tar.xz"))
    }

    func testParseChecksumExtractsHexDigestFromShasumFormat() {
        let digest = String(repeating: "ab", count: 32)
        let data = Data("\(digest)  wowsilicon-wine-1-osx64.tar.xz\n".utf8)
        XCTAssertEqual(RuntimeUpdateService.parseChecksum(data), digest)
    }

    func testParseChecksumRejectsNonHexOrWrongLength() {
        XCTAssertNil(RuntimeUpdateService.parseChecksum(Data("not-a-checksum".utf8)))
        XCTAssertNil(RuntimeUpdateService.parseChecksum(Data("abcd  file.tar.xz".utf8)))
    }

    func testSHA256HexMatchesKnownDigest() {
        // echo -n "" | shasum -a 256
        XCTAssertEqual(
            RuntimeUpdateService.sha256Hex(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    // MARK: - Asset selection

    private func makeRelease(tag: String, assetNames: [String]) -> GitHubRelease {
        GitHubRelease(tagName: tag, assets: assetNames.map { name in
            GitHubReleaseAsset(name: name, browserDownloadURL: URL(string: "https://example.com/\(name)")!)
        })
    }

    func testSelectLatestAssetsPicksHighestWineVersionAcrossReleasesAndIgnoresNonRuntimeTags() {
        let releases = [
            makeRelease(tag: "runtime-v1", assetNames: ["wowsilicon-wine-1-osx64.tar.xz", "wowsilicon-wine-1-osx64.tar.xz.sha256"]),
            makeRelease(tag: "runtime-v2", assetNames: ["wowsilicon-wine-2-osx64.tar.xz", "wowsilicon-wine-2-osx64.tar.xz.sha256"]),
            makeRelease(tag: "v3.2.0", assetNames: ["wowsilicon-wine-99-osx64.tar.xz", "wowsilicon-wine-99-osx64.tar.xz.sha256"])
        ]

        let result = RuntimeUpdateService.selectLatestAssets(from: releases)

        XCTAssertEqual(result?.wineVersion, 2)
        XCTAssertNil(result?.d9mtVersion)
    }

    func testSelectLatestAssetsFindsD9MTOnAnOlderRuntimeTagThanLatestWine() {
        let releases = [
            makeRelease(tag: "runtime-v1", assetNames: ["d9mt-5.tar.gz", "d9mt-5.tar.gz.sha256"]),
            makeRelease(tag: "runtime-v2", assetNames: ["wowsilicon-wine-2-osx64.tar.xz", "wowsilicon-wine-2-osx64.tar.xz.sha256"])
        ]

        let result = RuntimeUpdateService.selectLatestAssets(from: releases)

        XCTAssertEqual(result?.wineVersion, 2)
        XCTAssertEqual(result?.d9mtVersion, 5)
    }

    func testSelectLatestAssetsExcludesTarballsMissingChecksumSidecar() {
        let releases = [makeRelease(tag: "runtime-v1", assetNames: ["wowsilicon-wine-1-osx64.tar.xz"])]

        XCTAssertNil(RuntimeUpdateService.selectLatestAssets(from: releases))
    }

    func testSelectLatestAssetsReturnsNilWithoutAnyWineAsset() {
        XCTAssertNil(RuntimeUpdateService.selectLatestAssets(from: []))
    }

    // MARK: - RuntimeUpdateState persistence

    func testRuntimeUpdateStateSavesAndLoadsRoundTrip() throws {
        let (storage, _) = try makeStorage()
        var state = RuntimeUpdateState()
        state.wineCacheVersion = 4
        state.d9mtCacheVersion = 7
        state.lastCheckedAt = Date(timeIntervalSince1970: 1_700_000_000)

        state.save(fileManager: .default, storage: storage)
        let loaded = RuntimeUpdateState.load(fileManager: .default, storage: storage)

        XCTAssertEqual(loaded, state)
    }

    func testRuntimeUpdateStateLoadReturnsDefaultsWhenFileMissing() throws {
        let (storage, _) = try makeStorage()

        XCTAssertEqual(RuntimeUpdateState.load(fileManager: .default, storage: storage), RuntimeUpdateState())
    }

    // MARK: - Path layout

    func testRuntimeUpdatePathsAreDerivedFromStorageDataRoot() throws {
        let (storage, dataRoot) = try makeStorage()
        let root = dataRoot.appendingPathComponent("RuntimeUpdate", isDirectory: true)

        XCTAssertEqual(RuntimeUpdatePaths.rootDirectory(storage: storage).path, root.path)
        XCTAssertEqual(RuntimeUpdatePaths.wineCacheDirectory(storage: storage).path, root.appendingPathComponent("wine-cache").path)
        XCTAssertEqual(RuntimeUpdatePaths.d9mtCacheDirectory(storage: storage).path, root.appendingPathComponent("d9mt-cache").path)
        XCTAssertEqual(
            RuntimeUpdatePaths.overrideGameAppURL(storage: storage).path,
            root.appendingPathComponent("WoWSilicon Game.app").path
        )
    }

    // MARK: - Override assembly

    func testRebuildOverrideOverlaysNewerWineOntoBundledBaseline() throws {
        let (storage, _) = try makeStorage()
        let runtime = try makeFakeBundledGameApp(wineMarker: "bundled-wine")
        try makeFakeWineCache(storage: storage, wineMarker: "cached-wine-v2")
        let service = makeService(storage: storage, runtime: runtime, bundledWineVersion: 1, bundledD9MTVersion: 3)

        var state = RuntimeUpdateState(wineCacheVersion: 2)
        try service.rebuildOverrideIfNeeded(state: &state)

        XCTAssertEqual(state.overrideWineVersion, 2)
        XCTAssertEqual(state.overrideD9MTVersion, 3)

        let overrideURL = RuntimeUpdatePaths.overrideGameAppURL(storage: storage)
        XCTAssertEqual(
            try String(contentsOf: overrideURL.appendingPathComponent("Contents/MacOS/wine"), encoding: .utf8),
            "cached-wine-v2"
        )
        XCTAssertEqual(
            try String(contentsOf: overrideURL.appendingPathComponent("Contents/MacOS/wine-gamemode"), encoding: .utf8),
            "cached-wine-v2",
            "wine-gamemode must be regenerated from the freshly staged lib tree"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: overrideURL.appendingPathComponent("Contents/MacOS/wine-rosetta-shim").path),
            "pieces the wine tarball doesn't ship must survive the overlay"
        )
    }

    func testRebuildOverrideOverlaysD9MTWithoutTouchingBundledWine() throws {
        let (storage, _) = try makeStorage()
        let runtime = try makeFakeBundledGameApp(wineMarker: "bundled-wine")
        try makeFakeD9MTCache(storage: storage, marker: "cached-d9mt")
        let service = makeService(storage: storage, runtime: runtime, bundledWineVersion: 1, bundledD9MTVersion: 3)

        var state = RuntimeUpdateState(d9mtCacheVersion: 4)
        try service.rebuildOverrideIfNeeded(state: &state)

        XCTAssertEqual(state.overrideWineVersion, 1)
        XCTAssertEqual(state.overrideD9MTVersion, 4)

        let overrideURL = RuntimeUpdatePaths.overrideGameAppURL(storage: storage)
        XCTAssertEqual(
            try String(contentsOf: overrideURL.appendingPathComponent("Contents/MacOS/wine"), encoding: .utf8),
            "bundled-wine",
            "a d9mt-only update must not disturb the wine binary"
        )
        XCTAssertEqual(
            try String(contentsOf: overrideURL.appendingPathComponent("Contents/lib/wine/x86_64-windows/winemetal.dll"), encoding: .utf8),
            "cached-d9mt"
        )
    }

    func testRebuildOverrideIsNoOpWhenAlreadyCurrent() throws {
        let (storage, _) = try makeStorage()
        let runtime = try makeFakeBundledGameApp(wineMarker: "bundled-wine")
        // No caches staged — the bundled runtime is already the best available.
        let service = makeService(storage: storage, runtime: runtime, bundledWineVersion: 1, bundledD9MTVersion: 3)

        var state = RuntimeUpdateState()
        try service.rebuildOverrideIfNeeded(state: &state)

        XCTAssertNil(state.overrideWineVersion)
        XCTAssertNil(state.overrideD9MTVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RuntimeUpdatePaths.overrideGameAppURL(storage: storage).path))
    }

    func testRebuildOverrideRemovesStaleOverrideWhenBundledCatchesUp() throws {
        let (storage, _) = try makeStorage()
        let runtime = try makeFakeBundledGameApp(wineMarker: "bundled-wine")

        let overrideURL = RuntimeUpdatePaths.overrideGameAppURL(storage: storage)
        try FileManager.default.createDirectory(at: overrideURL, withIntermediateDirectories: true)
        try "stale".write(to: overrideURL.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        // Bundled now ships wine v5 — ahead of the old override's v2.
        let service = makeService(storage: storage, runtime: runtime, bundledWineVersion: 5, bundledD9MTVersion: 3)

        var state = RuntimeUpdateState(overrideWineVersion: 2, overrideD9MTVersion: 3)
        try service.rebuildOverrideIfNeeded(state: &state)

        XCTAssertNil(state.overrideWineVersion)
        XCTAssertNil(state.overrideD9MTVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideURL.path))
    }
}
