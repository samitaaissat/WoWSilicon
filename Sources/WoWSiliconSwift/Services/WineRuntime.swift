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
///
/// The runtime is staged by the Makefile `bundle` target as a nested application
/// bundle at <WoWSilicon.app>/Contents/SharedSupport/WoWSilicon Game.app, laid out
/// so wine's own `<bindir>/../lib` and `<bindir>/../share` resolution still works:
///
///     WoWSilicon Game.app/Contents/MacOS    <- wine's bin/, plus the rosettax87 loader
///     WoWSilicon Game.app/Contents/lib      <- wine's lib/
///     WoWSilicon Game.app/Contents/share    <- wine's share/
///
/// The shape is load-bearing for macOS Game Mode, which only recognises a process
/// whose real executable path is `<Something>.app/Contents/MacOS/<anything>` and
/// whose Info.plist declares a games category. Nesting the binaries any deeper
/// (the old `SharedSupport/wine/bin/wine`) yields no LaunchServices bundle record
/// and Game Mode never activates.
final class WineRuntime: @unchecked Sendable {
    static let shared = WineRuntime()

    /// Name of the nested bundle whose Info.plist carries the games category.
    static let gameAppName = "WoWSilicon Game.app"

    private let bundleURL: URL
    private let rosettaLoaderOverride: URL?
    private let fileManager = FileManager.default

    init(bundleURL: URL = Bundle.main.bundleURL, rosettaLoaderOverride: URL? = nil) {
        self.bundleURL = bundleURL
        self.rosettaLoaderOverride = rosettaLoaderOverride
    }

    var gameAppURL: URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("SharedSupport", isDirectory: true)
            .appendingPathComponent(Self.gameAppName, isDirectory: true)
    }

    var runtimeRootURL: URL {
        gameAppURL.appendingPathComponent("Contents", isDirectory: true)
    }

    var gameAppInfoPlistURL: URL {
        runtimeRootURL.appendingPathComponent("Info.plist")
    }

    /// Contents/MacOS — every executable the game process may exec through must
    /// live here directly, with no subdirectory, or bundle identity is lost.
    var executablesDirectoryURL: URL {
        runtimeRootURL.appendingPathComponent("MacOS", isDirectory: true)
    }

    var wineBinaryURL: URL {
        executablesDirectoryURL.appendingPathComponent("wine")
    }

    var wineserverBinaryURL: URL {
        executablesDirectoryURL.appendingPathComponent("wineserver")
    }

    var runtimeVersion: String? {
        let versionURL = runtimeRootURL.appendingPathComponent("VERSION")
        guard let contents = try? String(contentsOf: versionURL, encoding: .utf8) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wine execs $ROSETTA_X87_PATH as argv[0] for i386 images with argv[1] set to
    /// its ntdll-derived loader in Contents/lib (dlls/ntdll/unix/loader.c) — a path
    /// that would destroy Game Mode bundle identity at the final exec. This
    /// therefore points at the wine-rosetta-shim, which rewrites argv[1] to the
    /// physical Contents/MacOS/wine-gamemode loader copy and execs the real
    /// rosettax87 beside it (see tools/gamemode-shim/main.c and the Makefile
    /// bundle target).
    var rosettaLoaderURL: URL? {
        if let rosettaLoaderOverride {
            return rosettaLoaderOverride
        }
        return executablesDirectoryURL.appendingPathComponent("wine-rosetta-shim")
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
