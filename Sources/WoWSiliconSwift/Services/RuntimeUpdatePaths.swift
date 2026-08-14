import Foundation

/// Path layout for runtime self-updates, shared by `RuntimeUpdateService` and
/// the consumers that read what it installs (`WineRuntime`, `PatchService`).
/// Everything lives under the portable Data folder — never inside the signed
/// app bundle — so a downloaded update can be written without touching the
/// bundle's code signature. All functions are pure path math; nothing here
/// touches the filesystem.
enum RuntimeUpdatePaths {
    static func rootDirectory(storage: PortableStorage = .shared) -> URL {
        storage.dataRootURL.appendingPathComponent("RuntimeUpdate", isDirectory: true)
    }

    /// Persisted bookkeeping: last check time and which versions are cached
    /// or currently assembled into the override runtime.
    static func stateFileURL(storage: PortableStorage = .shared) -> URL {
        rootDirectory(storage: storage).appendingPathComponent("state.json", isDirectory: false)
    }

    /// The most recently downloaded wine tarball, extracted flat (bin/lib/share/VERSION).
    static func wineCacheDirectory(storage: PortableStorage = .shared) -> URL {
        rootDirectory(storage: storage).appendingPathComponent("wine-cache", isDirectory: true)
    }

    /// The most recently downloaded d9mt payload, extracted flat — same
    /// layout as the bundled Patching/d9mt resources (d3d9.dll, winemetal/…,
    /// d9mtmetal/…).
    static func d9mtCacheDirectory(storage: PortableStorage = .shared) -> URL {
        rootDirectory(storage: storage).appendingPathComponent("d9mt-cache", isDirectory: true)
    }

    /// The assembled override runtime: a full nested game bundle (same
    /// geometry as the one staged inside the app at build time) built from
    /// the bundled baseline plus whichever of the wine/d9mt caches above beat
    /// the versions the running app was built with. This is what
    /// `WineRuntime.setOverrideGameAppURL` is pointed at.
    static func overrideGameAppURL(storage: PortableStorage = .shared) -> URL {
        rootDirectory(storage: storage).appendingPathComponent(WineRuntime.gameAppName, isDirectory: true)
    }

    /// A fresh scratch directory for building/extracting into before an
    /// atomic move — never left behind on success, best-effort cleaned on failure.
    static func stagingDirectory(storage: PortableStorage = .shared, label: String) -> URL {
        rootDirectory(storage: storage).appendingPathComponent(".staging-\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}
