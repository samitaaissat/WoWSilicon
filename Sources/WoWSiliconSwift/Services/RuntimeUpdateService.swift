import Foundation
import CryptoKit

/// GitHub's release/asset JSON shape, trimmed to the fields this service needs.
struct GitHubRelease: Decodable, Sendable, Equatable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubReleaseAsset: Decodable, Sendable, Equatable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

/// The best available wine/d9mt assets found across every `runtime-v*`
/// release, each paired with its `.sha256` checksum sidecar. d9mt is optional:
/// new payload versions are sometimes uploaded onto an older runtime-v tag
/// without a matching wine bump (see docs/releasing.md, "d9mt Payload").
struct RuntimeAssetSet: Equatable, Sendable {
    let wineTarballURL: URL
    let wineChecksumURL: URL
    let wineVersion: Int
    let d9mtTarballURL: URL?
    let d9mtChecksumURL: URL?
    let d9mtVersion: Int?
}

/// Persisted bookkeeping for the runtime self-update flow: when it last
/// checked, which versions are currently cached on disk, and which version
/// pair the override game bundle was last assembled from.
struct RuntimeUpdateState: Codable, Equatable, Sendable {
    var lastCheckedAt: Date? = nil
    var wineCacheVersion: Int? = nil
    var d9mtCacheVersion: Int? = nil
    var overrideWineVersion: Int? = nil
    var overrideD9MTVersion: Int? = nil

    static func load(fileManager: FileManager, storage: PortableStorage) -> RuntimeUpdateState {
        let url = RuntimeUpdatePaths.stateFileURL(storage: storage)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RuntimeUpdateState.self, from: data) else {
            return RuntimeUpdateState()
        }
        return decoded
    }

    func save(fileManager: FileManager, storage: PortableStorage) {
        let url = RuntimeUpdatePaths.stateFileURL(storage: storage)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url)
    }
}

enum RuntimeUpdateError: LocalizedError, Equatable {
    case githubRequestFailed
    case invalidChecksumFormat
    case checksumMismatch
    case extractionFailed(String)
    case stagingFailed(String)

    var errorDescription: String? {
        switch self {
        case .githubRequestFailed:
            return "Failed to reach GitHub to check for runtime updates."
        case .invalidChecksumFormat:
            return "The downloaded checksum file was not in the expected format."
        case .checksumMismatch:
            return "The downloaded runtime file failed checksum verification."
        case .extractionFailed(let reason):
            return "Failed to extract the downloaded runtime: \(reason)"
        case .stagingFailed(let reason):
            return "Failed to stage the updated runtime: \(reason)"
        }
    }
}

/// Downloads and installs newer wine/d9mt builds than the ones bundled with
/// the app, so users get runtime fixes without waiting on a full app release.
///
/// Every downloaded file is verified against a `.sha256` sidecar asset before
/// use. Nothing is ever written into the signed app bundle: downloads land in
/// a wine-cache/d9mt-cache under the portable Data folder, and are assembled
/// into a full override copy of the nested game bundle (`RuntimeUpdatePaths.
/// overrideGameAppURL`) that `WineRuntime` prefers over the bundled one once
/// it looks valid, and that `PatchService` reads d9mt resources from in
/// preference to the bundled ones. This mirrors exactly what `make bundle`
/// stages at build time (see the Makefile's `bundle` target) — just run at
/// startup instead of at build time, and into a writable location instead of
/// the read-only app bundle.
final class RuntimeUpdateService: @unchecked Sendable {
    static let shared = RuntimeUpdateService()

    private static let releasesURL = URL(string: "https://api.github.com/repos/samitaaissat/WoWSilicon/releases?per_page=30")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let session: URLSession
    private let storage: PortableStorage
    private let runtime: WineRuntime
    private let fileManager: FileManager
    private let bundledWineVersion: Int
    private let bundledD9MTVersion: Int

    init(
        session: URLSession = URLSession(configuration: .ephemeral),
        storage: PortableStorage = .shared,
        runtime: WineRuntime = .shared,
        fileManager: FileManager = .default,
        bundledWineVersion: Int? = nil,
        bundledD9MTVersion: Int? = nil
    ) {
        self.session = session
        self.storage = storage
        self.runtime = runtime
        self.fileManager = fileManager
        let info = Bundle.main.infoDictionary ?? [:]
        self.bundledWineVersion = bundledWineVersion ?? (info["WSBundledRuntimeVersion"] as? NSNumber)?.intValue ?? 0
        self.bundledD9MTVersion = bundledD9MTVersion ?? (info["WSBundledD9MTVersion"] as? NSNumber)?.intValue ?? 0
    }

    /// Fire-and-forget background check, meant to be called once per launch.
    /// Runs off the main actor (tar/ditto are blocking calls) and never
    /// throws to its caller — failures are logged and simply retried next time.
    func checkForUpdatesOnLaunch() {
        Task.detached(priority: .background) { [self] in
            do {
                try await checkForUpdatesIfNeeded()
            } catch {
                debugPrint("RuntimeUpdateService: check failed: \(error)")
            }
        }
    }

    /// Checks GitHub for a newer wine runtime and/or d9mt payload than what's
    /// currently effective (bundled, or a previously downloaded cache),
    /// downloads and verifies whichever is newer, then assembles/refreshes the
    /// override game bundle. Each component is best-effort independently: a
    /// failed d9mt download does not roll back a successful wine one, or vice
    /// versa. Debounced to once per 24h unless `force` is set; only throws
    /// when the GitHub check itself couldn't run at all (e.g. offline), so an
    /// outage is retried on the next launch rather than debounced for a day.
    func checkForUpdatesIfNeeded(force: Bool = false) async throws {
        var state = RuntimeUpdateState.load(fileManager: fileManager, storage: storage)
        if !force, let lastCheckedAt = state.lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < Self.checkInterval {
            return
        }

        let releases = try await fetchReleases()
        let assets = Self.selectLatestAssets(from: releases)

        if let assets, assets.wineVersion > max(bundledWineVersion, state.wineCacheVersion ?? 0) {
            do {
                try await downloadWine(assets: assets, into: &state)
            } catch {
                debugPrint("RuntimeUpdateService: wine update failed: \(error)")
            }
        }

        if let assets,
           let d9mtVersion = assets.d9mtVersion,
           let d9mtTarballURL = assets.d9mtTarballURL,
           let d9mtChecksumURL = assets.d9mtChecksumURL,
           d9mtVersion > max(bundledD9MTVersion, state.d9mtCacheVersion ?? 0) {
            do {
                try await downloadD9MT(tarballURL: d9mtTarballURL, checksumURL: d9mtChecksumURL, version: d9mtVersion, into: &state)
            } catch {
                debugPrint("RuntimeUpdateService: d9mt update failed: \(error)")
            }
        }

        do {
            try rebuildOverrideIfNeeded(state: &state)
        } catch {
            debugPrint("RuntimeUpdateService: override rebuild failed: \(error)")
        }

        state.lastCheckedAt = Date()
        state.save(fileManager: fileManager, storage: storage)
    }

    // MARK: - GitHub

    private func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("WoWSilicon-RuntimeUpdater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RuntimeUpdateError.githubRequestFailed
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    /// Scans every `runtime-v*` release's assets (not just the latest tag,
    /// since a d9mt bump can land on an older runtime-v release without a
    /// wine bump) and picks the highest wine/d9mt version that has a matching
    /// `.sha256` sidecar asset. Pure and network-free — the assets are already
    /// decoded JSON — so this is directly unit-testable.
    static func selectLatestAssets(from releases: [GitHubRelease]) -> RuntimeAssetSet? {
        var bestWine: (version: Int, tarball: URL, checksum: URL)?
        var bestD9MT: (version: Int, tarball: URL, checksum: URL)?

        for release in releases where release.tagName.hasPrefix("runtime-v") {
            var urlsByName: [String: URL] = [:]
            for asset in release.assets {
                urlsByName[asset.name] = asset.browserDownloadURL
            }
            for asset in release.assets {
                if let version = wineTarballVersion(filename: asset.name),
                   let checksumURL = urlsByName["\(asset.name).sha256"],
                   version > (bestWine?.version ?? 0) {
                    bestWine = (version, asset.browserDownloadURL, checksumURL)
                }
                if let version = d9mtTarballVersion(filename: asset.name),
                   let checksumURL = urlsByName["\(asset.name).sha256"],
                   version > (bestD9MT?.version ?? 0) {
                    bestD9MT = (version, asset.browserDownloadURL, checksumURL)
                }
            }
        }

        guard let bestWine else { return nil }
        return RuntimeAssetSet(
            wineTarballURL: bestWine.tarball,
            wineChecksumURL: bestWine.checksum,
            wineVersion: bestWine.version,
            d9mtTarballURL: bestD9MT?.tarball,
            d9mtChecksumURL: bestD9MT?.checksum,
            d9mtVersion: bestD9MT?.version
        )
    }

    static func wineTarballVersion(filename: String) -> Int? {
        let prefix = "wowsilicon-wine-"
        let suffix = "-osx64.tar.xz"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        return Int(filename.dropFirst(prefix.count).dropLast(suffix.count))
    }

    static func d9mtTarballVersion(filename: String) -> Int? {
        let prefix = "d9mt-"
        let suffix = ".tar.gz"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        return Int(filename.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// Parses a `shasum -a 256` sidecar file (`<hexdigest>  <filename>`),
    /// returning just the digest.
    static func parseChecksum(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let hex = token.lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download + install

    private func downloadAndVerify(tarballURL: URL, checksumURL: URL) async throws -> Data {
        let (tarballData, _) = try await session.data(from: tarballURL)
        let (checksumData, _) = try await session.data(from: checksumURL)
        guard let expected = Self.parseChecksum(checksumData) else {
            throw RuntimeUpdateError.invalidChecksumFormat
        }
        guard Self.sha256Hex(of: tarballData) == expected else {
            throw RuntimeUpdateError.checksumMismatch
        }
        return tarballData
    }

    private func downloadWine(assets: RuntimeAssetSet, into state: inout RuntimeUpdateState) async throws {
        let tarballData = try await downloadAndVerify(tarballURL: assets.wineTarballURL, checksumURL: assets.wineChecksumURL)

        let staging = RuntimeUpdatePaths.stagingDirectory(storage: storage, label: "wine")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let tarballFile = staging.appendingPathComponent("wine.tar.xz")
        try tarballData.write(to: tarballFile)

        let extraction = try ProcessRunner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-xJf", tarballFile.path, "-C", staging.path],
            timeout: 300
        )
        guard extraction.exitCode == 0 else {
            throw RuntimeUpdateError.extractionFailed(extraction.combinedOutput)
        }

        let extractedWine = staging.appendingPathComponent("wine", isDirectory: true)
        guard fileManager.isExecutableFile(atPath: extractedWine.appendingPathComponent("bin/wine").path) else {
            throw RuntimeUpdateError.extractionFailed("wine binary missing or not executable after extraction")
        }

        let cacheDirectory = RuntimeUpdatePaths.wineCacheDirectory(storage: storage)
        try? fileManager.removeItem(at: cacheDirectory)
        try ditto(from: extractedWine, to: cacheDirectory)

        state.wineCacheVersion = assets.wineVersion
    }

    private func downloadD9MT(tarballURL: URL, checksumURL: URL, version: Int, into state: inout RuntimeUpdateState) async throws {
        let tarballData = try await downloadAndVerify(tarballURL: tarballURL, checksumURL: checksumURL)

        let staging = RuntimeUpdatePaths.stagingDirectory(storage: storage, label: "d9mt")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let tarballFile = staging.appendingPathComponent("d9mt.tar.gz")
        try tarballData.write(to: tarballFile)

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)

        // Strip the tarball's leading "d9mt/" component so the cache mirrors
        // the bundled Patching/d9mt layout exactly (see build-payload.sh).
        let extraction = try ProcessRunner.run(
            executablePath: "/usr/bin/tar",
            arguments: ["-xzf", tarballFile.path, "-C", extracted.path, "--strip-components=1"],
            timeout: 120
        )
        guard extraction.exitCode == 0 else {
            throw RuntimeUpdateError.extractionFailed(extraction.combinedOutput)
        }
        guard fileManager.fileExists(atPath: extracted.appendingPathComponent("d3d9.dll").path) else {
            throw RuntimeUpdateError.extractionFailed("d3d9.dll missing after extraction")
        }

        let cacheDirectory = RuntimeUpdatePaths.d9mtCacheDirectory(storage: storage)
        try? fileManager.removeItem(at: cacheDirectory)
        try ditto(from: extracted, to: cacheDirectory)

        state.d9mtCacheVersion = version
    }

    // MARK: - Override assembly

    /// Rebuilds the override game bundle only when the desired (wine, d9mt)
    /// version pair differs from what's currently assembled — a no-op most of
    /// the time. Deletes the override entirely once the bundled runtime is at
    /// least as good as anything cached, so a stale override never lingers
    /// after the app itself ships a newer runtime than a previous download.
    /// Internal (not private) so tests can exercise the assembly logic
    /// directly, without a real network round-trip through `checkForUpdatesIfNeeded`.
    func rebuildOverrideIfNeeded(state: inout RuntimeUpdateState) throws {
        let effectiveWineVersion = max(bundledWineVersion, state.wineCacheVersion ?? 0)
        let effectiveD9MTVersion = max(bundledD9MTVersion, state.d9mtCacheVersion ?? 0)
        let overrideURL = RuntimeUpdatePaths.overrideGameAppURL(storage: storage)

        guard effectiveWineVersion > bundledWineVersion || effectiveD9MTVersion > bundledD9MTVersion else {
            if fileManager.fileExists(atPath: overrideURL.path) {
                try? fileManager.removeItem(at: overrideURL)
            }
            state.overrideWineVersion = nil
            state.overrideD9MTVersion = nil
            return
        }

        guard state.overrideWineVersion != effectiveWineVersion || state.overrideD9MTVersion != effectiveD9MTVersion else {
            return
        }

        let staging = RuntimeUpdatePaths.stagingDirectory(storage: storage, label: "override")
        defer { try? fileManager.removeItem(at: staging) }
        try ditto(from: runtime.bundledGameAppURL, to: staging)

        if effectiveWineVersion > bundledWineVersion {
            try overlayWine(from: RuntimeUpdatePaths.wineCacheDirectory(storage: storage), into: staging)
        }
        if effectiveD9MTVersion > bundledD9MTVersion {
            try overlayD9MT(from: RuntimeUpdatePaths.d9mtCacheDirectory(storage: storage), into: staging)
        }

        try? fileManager.removeItem(at: overrideURL)
        try fileManager.createDirectory(at: overrideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: overrideURL)

        state.overrideWineVersion = effectiveWineVersion
        state.overrideD9MTVersion = effectiveD9MTVersion
    }

    /// Overlays a freshly downloaded wine build onto a staged copy of the
    /// bundled game bundle: bin/lib/share/VERSION plus a regenerated
    /// wine-gamemode copy. Mirrors the Makefile `bundle` target's wine steps.
    private func overlayWine(from wineCache: URL, into stagingRoot: URL) throws {
        let macOSDirectory = stagingRoot.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let libDirectory = stagingRoot.appendingPathComponent("Contents/lib", isDirectory: true)
        let shareDirectory = stagingRoot.appendingPathComponent("Contents/share", isDirectory: true)

        try? fileManager.removeItem(at: libDirectory)
        try? fileManager.removeItem(at: shareDirectory)

        try ditto(from: wineCache.appendingPathComponent("bin"), to: macOSDirectory)
        try ditto(from: wineCache.appendingPathComponent("lib"), to: libDirectory)
        try ditto(from: wineCache.appendingPathComponent("share"), to: shareDirectory)

        let versionDestination = stagingRoot.appendingPathComponent("Contents/VERSION")
        try? fileManager.removeItem(at: versionDestination)
        try fileManager.copyItem(at: wineCache.appendingPathComponent("VERSION"), to: versionDestination)

        // A physical copy of the wine binary, named distinctly from wine's own
        // embedded __info_plist identity so macOS Game Mode can bind
        // CFBundleExecutable to it without the SIGKILL that naming it "wine"
        // would trigger (see the Makefile bundle target for the full rationale).
        let wineGamemodeDestination = macOSDirectory.appendingPathComponent("wine-gamemode")
        try? fileManager.removeItem(at: wineGamemodeDestination)
        try fileManager.copyItem(at: libDirectory.appendingPathComponent("wine/x86_64-unix/wine"), to: wineGamemodeDestination)
    }

    /// Overlays winemetal/d9mtmetal builtins onto the staged game bundle's lib
    /// tree, matching DXMT's install convention (same six files the Makefile
    /// stages at build time).
    private func overlayD9MT(from d9mtCache: URL, into stagingRoot: URL) throws {
        let libWineDirectory = stagingRoot.appendingPathComponent("Contents/lib/wine", isDirectory: true)
        let pairs: [(source: String, destination: String)] = [
            ("winemetal/i386-windows/winemetal.dll", "i386-windows/winemetal.dll"),
            ("winemetal/x86_64-windows/winemetal.dll", "x86_64-windows/winemetal.dll"),
            ("winemetal/x86_64-unix/winemetal.so", "x86_64-unix/winemetal.so"),
            ("d9mtmetal/i386-windows/d9mtmetal.dll", "i386-windows/d9mtmetal.dll"),
            ("d9mtmetal/x86_64-windows/d9mtmetal.dll", "x86_64-windows/d9mtmetal.dll"),
            ("d9mtmetal/x86_64-unix/d9mtmetal.so", "x86_64-unix/d9mtmetal.so"),
        ]
        for pair in pairs {
            let sourceURL = d9mtCache.appendingPathComponent(pair.source)
            let destinationURL = libWineDirectory.appendingPathComponent(pair.destination)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    /// `ditto` (not `cp -R`): preserves mtimes, which wine's own prefix-update
    /// check depends on (see WineRuntime.swift's header comment).
    private func ditto(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try ProcessRunner.run(executablePath: "/usr/bin/ditto", arguments: [source.path, destination.path], timeout: 300)
        guard result.exitCode == 0 else {
            throw RuntimeUpdateError.stagingFailed(result.combinedOutput)
        }
    }
}
