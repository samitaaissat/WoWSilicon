import Foundation

enum WineRuntimeError: LocalizedError, Equatable {
    case wineBinaryMissing(String)
    case wineBinaryNotExecutable(String)
    case rosettaLoaderMissing

    var errorDescription: String? {
        switch self {
        case .wineBinaryMissing(let path):
            return "Bundled Wine runtime not found at \(path). Please reinstall WoWSilicon."
        case .wineBinaryNotExecutable(let path):
            return "Bundled Wine runtime at \(path) is not executable. Please reinstall WoWSilicon."
        case .rosettaLoaderMissing:
            return "Bundled rosettax87 loader not found. Please reinstall WoWSilicon."
        }
    }
}

/// Single authority for the bundled Wine runtime and rosettax87 loader paths.
/// The runtime lives at <WoWSilicon.app>/Contents/SharedSupport/wine (staged by
/// the Makefile `bundle` target); the loader is the SPM-vendored resource
/// Patching/rosettax87/rosettax87.
final class WineRuntime: @unchecked Sendable {
    static let shared = WineRuntime()

    private let bundleURL: URL
    private let rosettaLoaderOverride: URL?
    private let fileManager = FileManager.default

    init(bundleURL: URL = Bundle.main.bundleURL, rosettaLoaderOverride: URL? = nil) {
        self.bundleURL = bundleURL
        self.rosettaLoaderOverride = rosettaLoaderOverride
    }

    var runtimeRootURL: URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("SharedSupport", isDirectory: true)
            .appendingPathComponent("wine", isDirectory: true)
    }

    var wineBinaryURL: URL {
        runtimeRootURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("wine")
    }

    var wineserverBinaryURL: URL {
        runtimeRootURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("wineserver")
    }

    var runtimeVersion: String? {
        let versionURL = runtimeRootURL.appendingPathComponent("VERSION")
        guard let contents = try? String(contentsOf: versionURL, encoding: .utf8) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var rosettaLoaderURL: URL? {
        if let rosettaLoaderOverride {
            return rosettaLoaderOverride
        }
        return PatchService.resourceURL(named: "rosettax87", extension: nil, subdirectory: "Patching/rosettax87")
    }

    func validatedWineBinaryURL() throws -> URL {
        let url = wineBinaryURL
        guard fileManager.fileExists(atPath: url.path) else {
            throw WineRuntimeError.wineBinaryMissing(url.path)
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw WineRuntimeError.wineBinaryNotExecutable(url.path)
        }
        return url
    }

    func validatedRosettaLoaderURL() throws -> URL {
        guard let url = rosettaLoaderURL, fileManager.isExecutableFile(atPath: url.path) else {
            throw WineRuntimeError.rosettaLoaderMissing
        }
        return url
    }
}
