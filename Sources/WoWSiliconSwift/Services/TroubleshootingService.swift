import Foundation

enum TroubleshootingServiceError: LocalizedError, Equatable {
    case gamePathMissing
    case nothingToDelete
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .gamePathMissing:
            return "Game path is not set. Please configure it first."
        case .nothingToDelete:
            return "Nothing to delete for this action."
        case .operationFailed(let reason):
            return reason
        }
    }
}

struct TroubleshootingContext: Sendable {
    let gamePath: String?
    let currentVersion: GameVersion?
    let isGamePatched: Bool
    let storageDescription: String
    let dataRootPath: String
    let prefixPath: String
}

struct CrossOverRestoreResult: Equatable {
    let restoredNtdll: Bool
    let restoredWine: Bool
    let removedWineloader2: Bool
}

enum TroubleshootingService {

    static func deleteWDBDirectories(gamePath: String?) throws -> [String] {
        guard let path = gamePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw TroubleshootingServiceError.gamePathMissing
        }
        let fm = FileManager.default
        let primary = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("WDB", isDirectory: true)
        let cache = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("WDB", isDirectory: true)

        var deleted: [String] = []
        if fm.fileExists(atPath: primary.path) {
            try fm.removeItem(at: primary)
            deleted.append(primary.path)
        }
        if fm.fileExists(atPath: cache.path) {
            try fm.removeItem(at: cache)
            deleted.append(cache.path)
        }
        if deleted.isEmpty {
            throw TroubleshootingServiceError.nothingToDelete
        }
        return deleted
    }

    /// Primary reset: deletes ONLY the app's dedicated prefix.
    static func deleteDedicatedPrefix(prefixURL: URL = PortableStorage.shared.prefixURL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: prefixURL.path) else {
            throw TroubleshootingServiceError.nothingToDelete
        }
        try fm.removeItem(at: prefixURL)
        return [prefixURL.path]
    }

    /// Legacy cleanup for pre-3.x installs. ~/.wine is the SHARED system
    /// default prefix — CrossOver, GameHub and other Wine apps may own state
    /// in it — so this is a separate, explicitly-confirmed action and never
    /// part of the default reset.
    static func deleteLegacyPrefixes(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        gamePath: String?
    ) throws -> [String] {
        let fm = FileManager.default
        var candidates = [homeDirectory.appendingPathComponent(".wine", isDirectory: true)]
        if let path = gamePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".wine", isDirectory: true))
        }

        var deleted: [String] = []
        for url in candidates where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            deleted.append(url.path)
        }
        if deleted.isEmpty {
            throw TroubleshootingServiceError.nothingToDelete
        }
        return deleted
    }

    /// Best-effort revert of the v2.x CrossOver patch. Never throws; each
    /// missing piece is silently skipped and reported as false in the result.
    static func restoreCrossOverModifications(atCrossOverPath path: String) -> CrossOverRestoreResult {
        let fm = FileManager.default
        let shareDir = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("SharedSupport", isDirectory: true)
            .appendingPathComponent("CrossOver", isDirectory: true)

        var removedWineloader2 = false
        let wineloader2 = shareDir
            .appendingPathComponent("CrossOver-Hosted Application", isDirectory: true)
            .appendingPathComponent("wineloader2", isDirectory: false)
        if fm.fileExists(atPath: wineloader2.path) {
            if (try? fm.removeItem(at: wineloader2)) != nil {
                removedWineloader2 = true
            }
        }

        let unixDir = shareDir
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("wine", isDirectory: true)
            .appendingPathComponent("x86_64-unix", isDirectory: true)

        var restoredNtdll = false
        let ntdllBackup = unixDir.appendingPathComponent("ntdll.so.bak", isDirectory: false)
        let ntdllActive = unixDir.appendingPathComponent("ntdll.so", isDirectory: false)
        if fm.fileExists(atPath: ntdllBackup.path) {
            try? fm.removeItem(at: ntdllActive)
            if (try? fm.moveItem(at: ntdllBackup, to: ntdllActive)) != nil {
                restoredNtdll = true
            }
        }

        var restoredWine = false
        let wineBackup = unixDir.appendingPathComponent("wine.bak", isDirectory: false)
        let wineActive = unixDir.appendingPathComponent("wine", isDirectory: false)
        if fm.fileExists(atPath: wineBackup.path) {
            try? fm.removeItem(at: wineActive)
            if (try? fm.moveItem(at: wineBackup, to: wineActive)) != nil {
                restoredWine = true
            }
        }

        return CrossOverRestoreResult(
            restoredNtdll: restoredNtdll,
            restoredWine: restoredWine,
            removedWineloader2: removedWineloader2
        )
    }

    static func deleteVanillaTweaks(gamePath: String?) throws {
        guard let path = gamePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw TroubleshootingServiceError.gamePathMissing
        }
        let tweaked = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("WoW_tweaked.exe")
        guard FileManager.default.fileExists(atPath: tweaked.path) else {
            throw TroubleshootingServiceError.nothingToDelete
        }
        try FileManager.default.removeItem(at: tweaked)
    }

    /// Deletes the active storage root (Data folder including the prefix) and,
    /// when running portable, also the Application Support fallback directory.
    static func resetStorage(storage: PortableStorage = .shared) throws -> [String] {
        let fm = FileManager.default
        var targets = [storage.dataRootURL]
        if storage.isPortable {
            targets.append(storage.legacySupportDirectory)
        }
        var deleted: [String] = []
        for url in targets where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            deleted.append(url.path)
        }
        if deleted.isEmpty {
            throw TroubleshootingServiceError.nothingToDelete
        }
        return deleted
    }

    static func generateDebugLog(context: TroubleshootingContext, hideMacUserName: Bool, includeLatestErrorLog: Bool) -> (full: String, preview: String) {
        var baseLog = "=== WoWSilicon Debug Log ===\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        baseLog += "Generated: \(formatter.string(from: Date()))\n"
        baseLog += "WoWSilicon Version: \(appVersion)\n\n"

        baseLog += "=== System Information ===\n"
        baseLog += "OS: macOS\n"
        let macModel = run(["/usr/sbin/sysctl", "-n", "hw.model"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
        let memSizeStr = run(["/usr/sbin/sysctl", "-n", "hw.memsize"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        let memoryGB = (Double(memSizeStr) ?? 0) / (1024 * 1024 * 1024)
        
        baseLog += "Mac Model: \(macModel)\n"
        baseLog += "Memory: \(String(format: "%.1f", memoryGB)) GB\n"
        baseLog += "Architecture: \(ProcessInfo.processInfo.processorCount)-core \(ProcessInfo.processInfo.activeProcessorCount) active\n"
        if let swVers = run(["/usr/bin/sw_vers"]) {
            baseLog += "macOS Version:\n\(swVers)\n"
        }

        baseLog += "\n=== WoWSilicon Configuration ===\n"
        if let version = context.currentVersion {
            baseLog += "Current Game Version: \(version.displayName) (\(version.id))\n"
            baseLog += "WoW Version: \(version.wowVersion)\n"
            baseLog += "Game Path: \(version.gamePath)\n"
            baseLog += "Executable: \(version.executableName)\n"
            baseLog += "Supports Vanilla Tweaks: \(version.supportsVanillaTweaks)\n"
            baseLog += "Supports DLL Loading: \(version.supportsDLLLoading)\n"
            baseLog += "Uses Rosetta Patching: \(version.usesRosettaPatching)\n"
            baseLog += "Uses DivX Decoder Patch: \(version.usesDivxDecoderPatch)\n"

            baseLog += "\nVersion Settings:\n"
            let settings = version.settings
            baseLog += "  Vanilla Tweaks: \(settings.enableVanillaTweaks)\n"
            baseLog += "  Remap Option as Alt: \(settings.remapOptionAsAlt)\n"
            baseLog += "  Auto Delete WDB: \(settings.autoDeleteWdb)\n"
            baseLog += "  Metal HUD: \(settings.enableMetalHud)\n"
            baseLog += "  Show Terminal Normally: \(settings.showTerminalNormally)\n"
            baseLog += "  Environment Variables: \(settings.environmentVariables)\n"
            let gs = settings.graphicsSettings
            baseLog += "  Window Mode: \(gs.windowMode.rawValue)\n"
            baseLog += "  Resolution: \(gs.resolution.isEmpty ? "default" : gs.resolution)\n"
            baseLog += "  Refresh Rate: \(gs.refreshRate)Hz\n"
            baseLog += "  VSync: \(gs.vsync)\n"
            baseLog += "  Multisampling: \(gs.multisampling.rawValue)\n"
            baseLog += "  Texture Filtering: \(gs.textureFiltering.rawValue)\n"
            baseLog += "  Shadow Quality: \(gs.shadowQuality.rawValue)\n"
            baseLog += "  View Distance: \(gs.viewDistance)\n"
            baseLog += "  Particle Density: \(gs.particleDensity)\n"
            baseLog += "  Enable LibSilicon Patch: \(settings.enableLibSiliconPatch)\n"
        } else {
            baseLog += "Current Game Version: none selected\n"
        }

        baseLog += "\n=== Paths ===\n"
        baseLog += "Game Path: \(context.gamePath ?? "Not set")\n"
        if let game = context.gamePath {
            baseLog += FileManager.default.fileExists(atPath: game) ? "  Game path exists\n" : "  Game path missing\n"
        }

        baseLog += "\n=== Storage ===\n"
        baseLog += "Location: \(context.storageDescription)\n"
        baseLog += "Data root: \(context.dataRootPath)"
        baseLog += FileManager.default.fileExists(atPath: context.dataRootPath) ? " (exists)\n" : " (missing)\n"
        baseLog += "Wine prefix: \(context.prefixPath)"
        baseLog += FileManager.default.fileExists(atPath: context.prefixPath) ? " (exists)\n" : " (missing)\n"
        let sentinelPath = (context.prefixPath as NSString).appendingPathComponent(PrefixBootstrapService.sentinelFileName)
        let sentinel = (try? String(contentsOfFile: sentinelPath, encoding: .utf8)) ?? "missing"
        baseLog += "Prefix sentinel: \(sentinel)\n"
        let legacyWine = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wine")
        baseLog += "Legacy ~/.wine present: " + (FileManager.default.fileExists(atPath: legacyWine.path) ? "yes\n" : "no\n")

        var fullLog = baseLog
        var previewLog = baseLog
        
        baseLog = "\n=== Bundled Runtime ===\n"
        let runtime = WineRuntime.shared
        baseLog += "Runtime Version: \(runtime.runtimeVersion ?? "missing")\n"
        let winePath = runtime.wineBinaryURL.path
        baseLog += "Wine Binary: \(winePath)\n"
        baseLog += "  Exists: " + (FileManager.default.fileExists(atPath: winePath) ? "✓ Yes\n" : "✗ No\n")
        baseLog += "  Executable: " + (FileManager.default.isExecutableFile(atPath: winePath) ? "✓ Yes\n" : "✗ No\n")
        if let loader = runtime.rosettaLoaderURL {
            baseLog += "rosettax87 Loader: \(loader.path)\n"
        } else {
            baseLog += "rosettax87 Loader: missing\n"
        }

        baseLog += "\n=== Patch Status ===\n"
        baseLog += "Game Patched: \(context.isGamePatched)\n"

        if let game = context.gamePath {
            baseLog += "\n=== Game Files ===\n"
            let gameURL = URL(fileURLWithPath: game, isDirectory: true)
            
            // Directory listing
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: gameURL.path)
                let files = contents.filter { 
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: gameURL.appendingPathComponent($0).path, isDirectory: &isDir)
                    return !isDir.boolValue
                }.sorted()
                
                baseLog += "Game Path Directory Contents (Files):\n"
                for file in files {
                    baseLog += "  \(file)\n"
                }
                baseLog += "\n"
            } catch {
                baseLog += "Failed to list game directory: \(error.localizedDescription)\n\n"
            }

            let dllsURL = gameURL.appendingPathComponent("dlls.txt")
            if let content = try? String(contentsOf: dllsURL) {
                baseLog += "dlls.txt content:\n\(content)\n"
            } else {
                baseLog += "dlls.txt not found.\n"
            }
            let tweaked = gameURL.appendingPathComponent("WoW_tweaked.exe")
            baseLog += FileManager.default.fileExists(atPath: tweaked.path) ? "WoW_tweaked.exe: ✓ Found\n" : "WoW_tweaked.exe: Not found\n"
            let config = gameURL.appendingPathComponent("WTF", isDirectory: true).appendingPathComponent("Config.wtf")
            if let content = try? String(contentsOf: config) {
                baseLog += "Config.wtf (WTF):\n\(content)\n"
            }
            
            fullLog += baseLog
            previewLog += baseLog
            
            if includeLatestErrorLog {
                let errorTitle = "\n=== Latest Error Log ===\n"
                fullLog += errorTitle
                previewLog += errorTitle
                
                let errorsURL = gameURL.appendingPathComponent("Errors", isDirectory: true)
                do {
                    let contents = try FileManager.default.contentsOfDirectory(at: errorsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                    let txtFiles = contents.filter { $0.pathExtension == "txt" }
                    let sorted = try txtFiles.sorted {
                        let date1 = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                        let date2 = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                        return date1 > date2
                    }
                    if let latest = sorted.first, let content = try? String(contentsOf: latest) {
                        let fileLine = "File: \(latest.lastPathComponent)\n\n"
                        fullLog += fileLine
                        previewLog += fileLine
                        
                        fullLog += content + "\n"
                        
                        // Limit size just in case it's massive for preview
                        let maxLen = 10000
                        if content.count > maxLen {
                            previewLog += content.prefix(maxLen) + "\n\n... (truncated)\n"
                        } else {
                            previewLog += content + "\n"
                        }
                    } else {
                        fullLog += "No .txt error logs found in Errors directory.\n"
                        previewLog += "No .txt error logs found in Errors directory.\n"
                    }
                } catch {
                    fullLog += "Could not read Errors directory.\n"
                    previewLog += "Could not read Errors directory.\n"
                }
            }
        } else {
            fullLog += baseLog
            previewLog += baseLog
        }

        if hideMacUserName {
            let userName = NSUserName()
            fullLog = fullLog.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/[REDACTED]")
            fullLog = fullLog.replacingOccurrences(of: "Z:\\\\Users\\\\\(userName)", with: "Z:\\\\Users\\\\[REDACTED]")
            fullLog = fullLog.replacingOccurrences(of: "Z:\\Users\\\(userName)", with: "Z:\\Users\\[REDACTED]")
            
            previewLog = previewLog.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/[REDACTED]")
            previewLog = previewLog.replacingOccurrences(of: "Z:\\\\Users\\\\\(userName)", with: "Z:\\\\Users\\\\[REDACTED]")
            previewLog = previewLog.replacingOccurrences(of: "Z:\\Users\\\(userName)", with: "Z:\\Users\\[REDACTED]")
        }

        return (full: fullLog, preview: previewLog)
    }

    private static func run(_ components: [String]) -> String? {
        guard let executable = components.first else { return nil }
        let args = Array(components.dropFirst())
        guard let result = try? ProcessRunner.run(
            executablePath: executable,
            arguments: args,
            timeout: 10
        ) else {
            return nil
        }
        return result.combinedOutput
    }
}
