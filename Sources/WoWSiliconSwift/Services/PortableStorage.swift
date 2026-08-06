import Foundation

/// Single authority for where WoWSilicon's mutable state lives: the config
/// files (versions.json / prefs.json) and the dedicated Wine prefix.
///
/// Resolution is positional and runs once per instance — nothing about the
/// location is ever persisted, so moving the app and relaunching self-heals.
/// Portable mode uses a "WoWSilicon Data" folder beside the .app; when the
/// app's location is read-only (DMG, App Translocation, non-admin
/// /Applications) it falls back to ~/Library/Application Support/WoWSilicon,
/// which is a normal steady state, not an error.
final class PortableStorage: @unchecked Sendable {
    enum Location: Equatable, Sendable {
        case besideApp(URL)
        case applicationSupport(URL)
    }

    enum Reason: String, Sendable {
        case existingDataFolder
        case createdBesideApp
        case translocated
        case blockedByFile
        case parentNotWritable
        case readOnlyVolume
        case creationFailed
    }

    static let shared = PortableStorage()

    static let dataFolderName = "WoWSilicon Data"
    static let aboutFileName = "About this folder.txt"
    static let aboutFileContents = """
    This folder holds all of WoWSilicon's data: your settings and the Wine
    environment the game runs in.

    Keep it next to WoWSilicon.app. Copy both together to move your whole
    installation to another folder, disk, or Mac.

    Deleting this folder resets WoWSilicon completely.
    """

    let location: Location
    let reason: Reason
    /// The dedicated Wine prefix. Usually <data root>/prefix; on a volume that
    /// cannot host a prefix (cloud-synced, no symlinks) it splits to the
    /// Application Support root while the config stays portable.
    let prefixURL: URL
    /// ~/Library/Application Support/WoWSilicon (or the injected equivalent) —
    /// the source for first-run import and fallback-prefix adoption.
    let legacySupportDirectory: URL

    private let fileManager: FileManager

    init(bundleURL: URL = Bundle.main.bundleURL,
         fallbackSupportRoot: URL? = nil,
         fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let supportBase = fallbackSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let fallbackRoot = supportBase.appendingPathComponent("WoWSilicon", isDirectory: true)
        self.legacySupportDirectory = fallbackRoot

        let (location, reason) = Self.resolve(
            bundleURL: bundleURL, fallbackRoot: fallbackRoot, fileManager: fileManager)
        self.location = location
        self.reason = reason

        if case .besideApp(let dataRoot) = location,
           !Self.volumeCanHostPrefix(at: dataRoot, fileManager: fileManager) {
            self.prefixURL = fallbackRoot.appendingPathComponent("prefix", isDirectory: true)
        } else {
            let root: URL
            switch location {
            case .besideApp(let url): root = url
            case .applicationSupport(let url): root = url
            }
            self.prefixURL = root.appendingPathComponent("prefix", isDirectory: true)
        }
    }

    var dataRootURL: URL {
        switch location {
        case .besideApp(let url): return url
        case .applicationSupport(let url): return url
        }
    }

    /// Directory holding versions.json / version_manager.json / prefs.json.
    var configDirectory: URL { dataRootURL }

    var isPortable: Bool {
        if case .besideApp = location { return true }
        return false
    }

    /// True when the config is portable but the prefix had to fall back.
    var isPrefixSplit: Bool {
        isPortable && !prefixURL.path.hasPrefix(dataRootURL.path)
    }

    var displayDescription: String {
        switch location {
        case .besideApp(let url):
            var text = "Portable — \(url.path)"
            if isPrefixSplit {
                text += " (Wine prefix in Application Support — this volume can't host one)"
            }
            return text
        case .applicationSupport(let url):
            switch reason {
            case .translocated:
                return "Application Support (fallback — running from a quarantined location; move the app and relaunch) — \(url.path)"
            case .readOnlyVolume:
                return "Application Support (fallback — running from a disk image or read-only volume; drag WoWSilicon to Applications) — \(url.path)"
            case .blockedByFile:
                return "Application Support (fallback — a file named '\(Self.dataFolderName)' sits beside the app) — \(url.path)"
            default:
                return "Application Support (fallback — the app's folder is not writable) — \(url.path)"
            }
        }
    }

    // MARK: - First-run import

    /// Byte-copies existing config from ~/Library/Application Support/WoWSilicon
    /// into a fresh portable Data folder. Latch: once versions.json exists in
    /// the Data root, the Data root is authoritative forever and the import
    /// never runs again. Copy — never move — so Application Support stays
    /// intact as a rollback net. Never decode/re-encode: re-encoding would
    /// drop unknown legacy keys.
    func performFirstRunImportIfNeeded() {
        guard isPortable else { return }
        let latchURL = configDirectory.appendingPathComponent("versions.json")
        guard !fileManager.fileExists(atPath: latchURL.path) else { return }

        // versions.json is copied LAST: it is the latch, and an interrupted
        // import must not latch before the other files made it across.
        for name in ["version_manager.json", "prefs.json", "versions.json"] {
            let source = legacySupportDirectory.appendingPathComponent(name)
            let destination = configDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    // MARK: - Fallback-prefix adoption

    /// When a launch resolves beside the app but the Application Support
    /// fallback still holds an app-created prefix (user ran from a read-only
    /// location first), MOVE it into the Data folder instead of paying a full
    /// wineboot init + VC++ reinstall for a fresh one. Skipped while any
    /// bundled wineserver is alive — moving a live prefix corrupts it; the
    /// move is retried on the next launch.
    func adoptFallbackPrefixIfNeeded(isPrefixBusy: () -> Bool = PortableStorage.isBundledWineserverRunning) {
        guard isPortable else { return }
        let source = legacySupportDirectory.appendingPathComponent("prefix", isDirectory: true)
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: prefixURL.path) else { return }
        guard !isPrefixBusy() else { return }

        do {
            try fileManager.moveItem(at: source, to: prefixURL)
        } catch {
            // Cross-volume move: copy, verify the copy landed, then delete.
            do {
                try fileManager.copyItem(at: source, to: prefixURL)
                guard fileManager.fileExists(atPath: prefixURL.appendingPathComponent("user.reg").path) else {
                    try? fileManager.removeItem(at: prefixURL)
                    return
                }
                try? fileManager.removeItem(at: source)
            } catch {
                try? fileManager.removeItem(at: prefixURL)
                return
            }
        }
        normalizeCDriveSymlink()
        // Time Machine must not churn on the prefix (spec: excluded in all modes).
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var adopted = prefixURL
        try? adopted.setResourceValues(backupValues)
    }

    /// wine's own prefixes use a relative "c:" -> "../drive_c" symlink, which
    /// is what makes them relocatable. Rewrite an absolute one after a move.
    private func normalizeCDriveSymlink() {
        let cDrive = prefixURL.appendingPathComponent("dosdevices", isDirectory: true)
            .appendingPathComponent("c:")
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: cDrive.path),
              target != "../drive_c" else { return }
        try? fileManager.removeItem(at: cDrive)
        try? fileManager.createSymbolicLink(atPath: cDrive.path, withDestinationPath: "../drive_c")
    }

    /// Conservative busy check: if the bundled wineserver is running at all,
    /// skip adoption this session (pgrep -f on the binary path).
    static func isBundledWineserverRunning() -> Bool {
        guard let result = try? ProcessRunner.run(
            executablePath: "/usr/bin/pgrep",
            arguments: ["-f", WineRuntime.shared.wineserverBinaryURL.path],
            timeout: 5
        ) else {
            return false
        }
        return result.exitCode == 0
    }

    // MARK: - Resolution

    private static func resolve(bundleURL: URL, fallbackRoot: URL,
                                fileManager: FileManager) -> (Location, Reason) {
        let appURL = bundleURL.resolvingSymlinksInPath()

        if appURL.pathComponents.contains("AppTranslocation") {
            return (.applicationSupport(fallbackRoot), .translocated)
        }

        let dataURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(dataFolderName, isDirectory: true)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dataURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return (.applicationSupport(fallbackRoot), .blockedByFile)
            }
            guard isWritableByProbe(directory: dataURL, fileManager: fileManager) else {
                return (.applicationSupport(fallbackRoot), .parentNotWritable)
            }
            return (.besideApp(dataURL), .existingDataFolder)
        }

        do {
            try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: false)
        } catch {
            let nsError = error as NSError
            let posixCode = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? nsError.code
            let isReadOnly = nsError.code == NSFileWriteVolumeReadOnlyError || posixCode == Int(EROFS)
            return (.applicationSupport(fallbackRoot), isReadOnly ? .readOnlyVolume : .creationFailed)
        }
        guard isWritableByProbe(directory: dataURL, fileManager: fileManager) else {
            return (.applicationSupport(fallbackRoot), .parentNotWritable)
        }
        let aboutURL = dataURL.appendingPathComponent(aboutFileName)
        try? aboutFileContents.write(to: aboutURL, atomically: true, encoding: .utf8)
        return (.besideApp(dataURL), .createdBesideApp)
    }

    /// The only trustworthy writability test is a real write.
    /// FileManager.isWritableFile(atPath:) is advisory and lies on ACLs,
    /// network mounts, and TCC-protected folders.
    static func isWritableByProbe(directory: URL, fileManager: FileManager) -> Bool {
        let probeURL = directory.appendingPathComponent(".ws-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probeURL)
            try fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    /// A Wine prefix needs symlinks named like "c:", stable local storage, and
    /// current-user ownership (wineserver refuses foreign-owned prefixes).
    /// Cloud-synced folders pass the syscalls but corrupt prefixes via
    /// eviction, so they are rejected by path shape.
    static func volumeCanHostPrefix(at directory: URL, fileManager: FileManager) -> Bool {
        let path = directory.path
        if path.contains("/Library/Mobile Documents") || path.contains("/Library/CloudStorage") {
            return false
        }
        if let values = try? directory.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey]),
           values.volumeSupportsSymbolicLinks == false {
            return false
        }
        let probeDir = directory.appendingPathComponent(".ws-prefix-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: probeDir) }
        do {
            try fileManager.createDirectory(at: probeDir, withIntermediateDirectories: false)
            let link = probeDir.appendingPathComponent("c:")
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "../drive_c")
            guard try fileManager.destinationOfSymbolicLink(atPath: link.path) == "../drive_c" else {
                return false
            }
            var status = stat()
            guard lstat(probeDir.path, &status) == 0, status.st_uid == getuid() else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}
