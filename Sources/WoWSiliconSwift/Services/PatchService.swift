import Foundation
import Darwin
import CryptoKit

enum PatchServiceError: LocalizedError {
    case gamePathMissing
    case invalidGamePath(String)
    case gameClientNotDetected
    case resourceMissing(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .gamePathMissing:
            return "Game path is not set. Please choose your game directory first."
        case .invalidGamePath(let path):
            return "The selected game path is invalid or inaccessible: \(path)"
        case .gameClientNotDetected:
            return "This folder does not look like a World of Warcraft client. Select the folder containing DivxDecoder.dll."
        case .resourceMissing(let name):
            return "Bundled resource \(name) is missing from the application package."
        case .fileOperationFailed(let reason):
            return reason
        }
    }
}

enum PatchService {
    static func applyGamePatch(for version: GameVersion) throws {
        let gameURL = try stageGamePatchFiles(for: version)

        if version.settings.renderer == .d9mt {
            try installD9MTPrefixSupport(winePrefixPath: WineRegistrySupport.winePrefixURL().path)
            try registerD9MTBuiltins()
        }
        // The wined3d renderer needs no patch-time prefix work: its Vulkan
        // renderer is selected per-launch via WINE_D3D_CONFIG — see
        // LaunchService.makeShellCommand.

        if version.usesRosettaPatching && version.supportsDLLLoading {
            try patchDivxDecoder(gameURL: gameURL)
        }

        ensureGxResolution(in: gameURL)
    }

    /// Copies all patch payload files into the game folder and deletes the
    /// obsolete v2 `<game>/rosettax87/` directory (rosettax87 ships inside the
    /// app bundle since v3). Split from `applyGamePatch` so tests can exercise
    /// the file staging without invoking Wine (the DivxDecoder rundll32 step).
    static func stageGamePatchFiles(for version: GameVersion) throws -> URL {
        guard !version.gamePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatchServiceError.gamePathMissing
        }

        let gameURL = URL(fileURLWithPath: version.gamePath, isDirectory: true)
        try ensureDirectoryExists(gameURL, errorOnMissing: .invalidGamePath(version.gamePath))
        guard isSupportedGameClient(at: gameURL) else {
            throw PatchServiceError.gameClientNotDetected
        }

        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)

        try copyResource(named: "winerosetta", extension: "dll", subdirectory: "Patching/winerosetta", to: modsURL.appendingPathComponent("winerosetta.dll"))
        switch version.settings.renderer {
        case .d9vk, .d9mt:
            let d3d9Subdirectory = version.settings.renderer == .d9mt ? "Patching/d9mt" : "Patching/d9vk"
            try copyResource(named: "d3d9", extension: "dll", subdirectory: d3d9Subdirectory, to: gameURL.appendingPathComponent("d3d9.dll"))
        case .wined3d:
            // wined3d is the builtin d3d9: a native DLL in the game folder would
            // shadow it (WINEDLLOVERRIDES probes the exe's directory first), so
            // staging means guaranteeing the file's absence.
            try removeIfExists(gameURL.appendingPathComponent("d3d9.dll"))
        }

        // Remove legacy exe-patching artifacts
        try removeIfExists(gameURL.appendingPathComponent("Wow_patched.exe"))
        try removeIfExists(modsURL.appendingPathComponent("libDllLdr.dll"))

        if version.usesRosettaPatching && version.supportsDLLLoading {
            try copyResource(named: "libDllLdr", extension: "dll", subdirectory: "Patching/winerosetta", to: gameURL.appendingPathComponent("libDllLdr.dll"))
        } else {
            try removeIfExists(gameURL.appendingPathComponent("libDllLdr.dll"))
        }

        if version.settings.enableLibSiliconPatch, let subdir = version.libSiliconPatchSubdirectory {
            try copyResource(named: "libSiliconPatch", extension: "dll", subdirectory: subdir, to: modsURL.appendingPathComponent("libSiliconPatch.dll"))
        } else {
            try removeIfExists(modsURL.appendingPathComponent("libSiliconPatch.dll"))
        }

        // Optional utility used by vanilla tweaks
        if version.supportsVanillaTweaks, let vanillaTweaksURL = resourceURL(named: "vanilla-tweaks", extension: "exe", subdirectory: "Patching/vanilla-tweaks") {
            let destination = gameURL.appendingPathComponent("vanilla-tweaks.exe")
            try copyItem(from: vanillaTweaksURL, to: destination)
        }

        // v3: rosettax87 lives inside the app bundle; delete the obsolete v2 copy.
        try removeIfExists(gameURL.appendingPathComponent("rosettax87", isDirectory: true))

        try updateDllsTxt(in: gameURL, enableLibSiliconPatch: version.settings.enableLibSiliconPatch && version.libSiliconPatchSubdirectory != nil)

        return gameURL
    }

    /// Environment for the DivxDecoder rundll32 invocation. Built on
    /// makeWineEnvironment so it carries the WINESERVER pin (wine cannot
    /// autostart a server under the nested game .app layout without it) and a
    /// WINEMSYNC value consistent with every other invocation on the shared
    /// prefix, then overlays the patching-specific overrides.
    static func makeDivxPatchEnvironment(
        prefixURL: URL,
        wineExecutable: String,
        enableMsync: Bool = WineRegistrySupport.msyncEnabled
    ) -> [String: String] {
        var env = WineRegistrySupport.makeWineEnvironment(
            prefixURL: prefixURL,
            wineExecutable: wineExecutable,
            enableMsync: enableMsync
        )
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree=d;mshtml=d"
        env["WINEDEBUG"] = "-all"
        return env
    }

    /// d9mt renderer: installs winemetal/d9mtmetal as Wine builtins — the 64-bit
    /// PE into system32, the 32-bit PE into syswow64, and the unix .so into
    /// x86_64-unix, matching DXMT's install convention. The same files are staged
    /// into the bundled runtime's lib/wine arch dirs by `make bundle`, which is
    /// where wine's find_builtin_dll actually loads them from; the prefix copies
    /// keep the loader's lookup order deterministic.
    static func installD9MTPrefixSupport(winePrefixPath: String) throws {
        let pairs: [(subdirectory: String, name: String, ext: String, destination: String)] = [
            ("Patching/d9mt/winemetal/x86_64-windows", "winemetal", "dll", "drive_c/windows/system32/winemetal.dll"),
            ("Patching/d9mt/winemetal/i386-windows", "winemetal", "dll", "drive_c/windows/syswow64/winemetal.dll"),
            ("Patching/d9mt/winemetal/x86_64-unix", "winemetal", "so", "drive_c/windows/x86_64-unix/winemetal.so"),
            ("Patching/d9mt/d9mtmetal/x86_64-windows", "d9mtmetal", "dll", "drive_c/windows/system32/d9mtmetal.dll"),
            ("Patching/d9mt/d9mtmetal/i386-windows", "d9mtmetal", "dll", "drive_c/windows/syswow64/d9mtmetal.dll"),
            ("Patching/d9mt/d9mtmetal/x86_64-unix", "d9mtmetal", "so", "drive_c/windows/x86_64-unix/d9mtmetal.so")
        ]
        let prefixURL = URL(fileURLWithPath: winePrefixPath, isDirectory: true)
        for pair in pairs {
            guard let source = resourceURL(named: pair.name, extension: pair.ext, subdirectory: pair.subdirectory) else {
                throw PatchServiceError.resourceMissing("\(pair.subdirectory)/\(pair.name).\(pair.ext)")
            }
            let destination = prefixURL.appendingPathComponent(pair.destination)
            // A bootstrapped prefix has system32/syswow64 but no x86_64-unix.
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyItem(from: source, to: destination)
        }
    }

    /// Registers winemetal/d9mtmetal as builtin DLLs in the shared prefix so wine
    /// resolves them from its own lib tree instead of looking for native DLLs.
    /// Follows patchDivxDecoder's wine invocation pattern (same environment, same
    /// prefix); not unit-tested for the same reason — it needs a real Wine runtime.
    private static func registerD9MTBuiltins() throws {
        let wineBinaryURL = try WineRuntime.shared.validatedWineBinaryURL()

        let env = makeDivxPatchEnvironment(
            prefixURL: WineRegistrySupport.winePrefixURL(),
            wineExecutable: wineBinaryURL.path
        )

        for dll in ["winemetal", "d9mtmetal"] {
            let result = try ProcessRunner.run(
                executablePath: wineBinaryURL.path,
                arguments: ["reg", "add", #"HKCU\Software\Wine\DllOverrides"#, "/v", dll, "/d", "builtin", "/f"],
                environment: env,
                timeout: 120
            )

            if result.exitCode != 0 {
                throw PatchServiceError.fileOperationFailed("Failed to register \(dll)=builtin: \(result.combinedOutput)")
            }
        }
    }

    private static func patchDivxDecoder(gameURL: URL) throws {
        let wineBinaryURL = try WineRuntime.shared.validatedWineBinaryURL()

        let env = makeDivxPatchEnvironment(
            prefixURL: WineRegistrySupport.winePrefixURL(),
            wineExecutable: wineBinaryURL.path
        )

        let patches: [(entry: String, file: String)] = [
            ("PatchDivxDecoder", "DivxDecoder.dll"),
            ("PatchDivxTac",     "DivxTac.dll"),
        ]

        for patch in patches {
            guard FileManager.default.fileExists(atPath: gameURL.appendingPathComponent(patch.file).path) else {
                continue  // this client doesn't have this DLL — skip
            }

            let result = try ProcessRunner.run(
                executablePath: wineBinaryURL.path,
                arguments: ["rundll32", "libDllLdr.dll,\(patch.entry)", gameURL.path],
                environment: env,
                currentDirectory: gameURL,
                timeout: 120
            )

            if result.exitCode != 0 {
                throw PatchServiceError.fileOperationFailed("Failed to run \(patch.entry): \(result.combinedOutput)")
            }
        }
    }

    private static func revertDivxDecoder(gameURL: URL) throws {
        for name in ["DivxDecoder.dll", "DivxTac.dll"] {
            let fileURL = gameURL.appendingPathComponent(name)
            let bakURL  = gameURL.appendingPathComponent("\(name).bak")
            guard FileManager.default.fileExists(atPath: bakURL.path) else { continue }
            try removeIfExists(fileURL)
            do {
                try FileManager.default.moveItem(at: bakURL, to: fileURL)
            } catch {
                throw PatchServiceError.fileOperationFailed("Failed to restore \(name) from backup: \(error.localizedDescription)")
            }
        }
    }

    static func isSupportedGameClient(at gameURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("DivxDecoder.dll").path)
            || FileManager.default.fileExists(atPath: gameURL.appendingPathComponent("DivxDecoder.dll.bak").path)
    }

    static func removeGamePatch(for version: GameVersion) throws {
        guard !version.gamePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatchServiceError.gamePathMissing
        }

        let gameURL = URL(fileURLWithPath: version.gamePath, isDirectory: true)
        try ensureDirectoryExists(gameURL, errorOnMissing: .invalidGamePath(version.gamePath))

        let modsURL = gameURL.appendingPathComponent("mods", isDirectory: true)

        try removeIfExists(modsURL.appendingPathComponent("winerosetta.dll"))
        try removeIfExists(modsURL.appendingPathComponent("libSiliconPatch.dll"))
        try removeIfExists(modsURL.appendingPathComponent("libDllLdr.dll"))
        try removeIfExists(gameURL.appendingPathComponent("libDllLdr.dll"))
        try removeIfExists(gameURL.appendingPathComponent("Wow_patched.exe"))
        try removeIfExists(gameURL.appendingPathComponent("d3d9.dll"))
        try removeIfExists(gameURL.appendingPathComponent("vanilla-tweaks.exe"))
        // Obsolete v2 payload — rosettax87 ships inside the app bundle since v3.
        try removeIfExists(gameURL.appendingPathComponent("rosettax87"))
        try revertDivxDecoder(gameURL: gameURL)

        try removeDllEntries(in: gameURL)

    }

    // MARK: - Helpers

    private static func ensureDirectoryExists(_ url: URL, errorOnMissing: PatchServiceError) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw errorOnMissing
        }
    }

    private static func copyResource(named name: String, extension ext: String?, subdirectory: String, to destination: URL, makeExecutable: Bool = false) throws {
        guard let source = resourceURL(named: name, extension: ext, subdirectory: subdirectory) else {
            let resourceName = ext == nil ? name : "\(name).\(ext!)"
            throw PatchServiceError.resourceMissing(resourceName)
        }
        try copyItem(from: source, to: destination)

        if makeExecutable {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: destination.path)
        }
    }

    private static func copyItem(from source: URL, to destination: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            let reason: String
            if (error as NSError).code == EPERM {
                reason = "Insufficient permissions to modify \(destination.path). Grant the app access in System Settings > Privacy & Security > App Management."
            } else {
                reason = "Failed to copy \(source.lastPathComponent) to \(destination.path): \(error.localizedDescription)"
            }
            throw PatchServiceError.fileOperationFailed(reason)
        }
    }

    private static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw PatchServiceError.fileOperationFailed("Failed to remove \(url.path): \(error.localizedDescription)")
            }
        }
    }

    static func fileChecksum(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func ensureGxResolution(in gameURL: URL) {
        let configURL = gameURL
            .appendingPathComponent("WTF", isDirectory: true)
            .appendingPathComponent("Config.wtf", isDirectory: false)

        let fm = FileManager.default
        let configExists = fm.fileExists(atPath: configURL.path)

        if configExists {
            // WoW has historically written Config.wtf in non-UTF-8 encodings on some
            // platforms. If the read fails, do NOT fall back to empty-string —
            // that would clobber the user's entire config with a single SET line.
            var usedEncoding: UInt = 0
            guard var text = try? NSString(contentsOf: configURL, usedEncoding: &usedEncoding) as String else {
                return
            }

            let hasResolution = text.range(of: "SET\\s+gxResolution\\s+\"", options: [.regularExpression, .caseInsensitive]) != nil
            if hasResolution { return }

            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "SET gxResolution \"2560x1600\"\n"
            let encoding = String.Encoding(rawValue: usedEncoding == 0 ? String.Encoding.utf8.rawValue : usedEncoding)
            try? text.write(to: configURL, atomically: true, encoding: encoding)
        } else {
            // Fresh install: create WTF/ and seed a minimal Config.wtf.
            let wtfDir = configURL.deletingLastPathComponent()
            try? fm.createDirectory(at: wtfDir, withIntermediateDirectories: true)
            let seed = "SET gxResolution \"2560x1600\"\n"
            try? seed.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    private static func updateDllsTxt(in gameDirectory: URL, enableLibSiliconPatch: Bool) throws {
        let dllsURL = gameDirectory.appendingPathComponent("dlls.txt")
        var content = (try? String(contentsOf: dllsURL)) ?? ""

        func ensureEntry(_ entry: String) {
            let lines = content
                .split(whereSeparator: { $0.isNewline })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if !lines.contains(entry.lowercased()) {
                if !content.hasSuffix("\n") && !content.isEmpty {
                    content.append("\n")
                }
                content.append(entry)
                content.append("\n")
            }
        }

        ensureEntry("mods/winerosetta.dll")
        if enableLibSiliconPatch {
            ensureEntry("mods/libSiliconPatch.dll")
        } else {
            content = content
                .split(whereSeparator: { $0.isNewline })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { line in
                    let lower = line.lowercased()
                    return lower != "mods/libsiliconpatch.dll" && lower != "libsiliconpatch.dll"
                }
                .joined(separator: "\n")
            if !content.isEmpty {
                content.append("\n")
            }
        }

        try content.write(to: dllsURL, atomically: true, encoding: .utf8)
    }

    private static func removeDllEntries(in gameDirectory: URL) throws {
        let dllsURL = gameDirectory.appendingPathComponent("dlls.txt")
        guard let content = try? String(contentsOf: dllsURL) else {
            return
        }

        let filtered = content
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lower = line.lowercased()
                return lower != "mods/winerosetta.dll" && lower != "mods/libsiliconpatch.dll" && lower != "libsiliconpatch.dll"
            }
            .joined(separator: "\n")

        try filtered.write(to: dllsURL, atomically: true, encoding: .utf8)
    }

    static func resourceURL(
        named name: String,
        extension ext: String?,
        subdirectory: String,
        overrideDirectory: URL? = RuntimeUpdatePaths.d9mtCacheDirectory()
    ) -> URL? {
        if let overrideURL = d9mtOverrideResourceURL(named: name, extension: ext, subdirectory: subdirectory, root: overrideDirectory) {
            return overrideURL
        }

        for bundle in CandidateBundles.all {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
            if let lastComponent = subdirectory.split(separator: "/").last,
               let url = bundle.url(forResource: name, withExtension: ext, subdirectory: String(lastComponent)) {
                return url
            }
        }

        // Fallback to manually building the path inside the main bundle's resource directory.
        if let manualURL = CandidateBundles.locateManually(named: name, extension: ext, subdirectory: subdirectory) {
            return manualURL
        }

        return nil
    }

    /// Looks for a resource under a downloaded d9mt cache before falling back
    /// to the bundled Patching/d9mt resources. `root` mirrors the extracted
    /// tarball's own layout (d3d9.dll, winemetal/<arch>/…, d9mtmetal/<arch>/…),
    /// so subdirectories are resolved relative to it by stripping the
    /// "Patching/d9mt/" prefix the rest of this file passes in.
    private static func d9mtOverrideResourceURL(named name: String, extension ext: String?, subdirectory: String, root: URL?) -> URL? {
        guard let root else { return nil }
        guard subdirectory == "Patching/d9mt" || subdirectory.hasPrefix("Patching/d9mt/") else { return nil }

        let prefix = "Patching/d9mt/"
        let relative = subdirectory.hasPrefix(prefix) ? String(subdirectory.dropFirst(prefix.count)) : ""
        let directory = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
        let filename = ext.map { "\(name).\($0)" } ?? name
        let candidate = directory.appendingPathComponent(filename, isDirectory: false)

        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

private enum CandidateBundles {
    private static let resourceBundleNames = [
        "WoWSilicon-swift_WoWSiliconSwift",
        "WoWSilicon_WoWSiliconSwift",
        "WoWSiliconSwift_WoWSiliconSwift"
    ]

    static let all: [Bundle] = {
        var bundles: [Bundle] = []
        var seenPaths = Set<String>()

        func addBundle(_ bundle: Bundle?) {
            guard let bundle else { return }
            let path = bundle.bundlePath
            guard !seenPaths.contains(path) else { return }
            seenPaths.insert(path)
            bundles.append(bundle)
        }

        addBundle(Bundle.main)

        if let resourceURL = Bundle.main.resourceURL {
            if let contents = try? FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for url in contents where url.pathExtension == "bundle" {
                    addBundle(Bundle(url: url))
                }
            }
        }

        class BundleToken {}
        let finderBundle = Bundle(for: BundleToken.self)
        addBundle(finderBundle)

        for candidate in candidateDirectories(from: finderBundle) + candidateDirectories(from: Bundle.main) {
            for name in resourceBundleNames {
                let bundleURL = candidate.appendingPathComponent("\(name).bundle")
                addBundle(Bundle(url: bundleURL))
            }
        }

        return bundles
    }()

    private static func candidateDirectories(from bundle: Bundle) -> [URL] {
        var urls: [URL] = []
        if let resourceURL = bundle.resourceURL {
            urls.append(resourceURL)
            urls.append(resourceURL.deletingLastPathComponent())
        }
        urls.append(bundle.bundleURL)
        urls.append(bundle.bundleURL.deletingLastPathComponent())
        return urls
    }

    static func locateManually(named name: String, extension ext: String?, subdirectory: String) -> URL? {
        guard let resourceRoot = Bundle.main.resourceURL else { return nil }
        let pathsToTry: [URL] = [
            resourceRoot.appendingPathComponent(subdirectory),
            resourceRoot.appendingPathComponent((subdirectory as NSString).lastPathComponent)
        ]

        let possibleFileNames: [String]
        if let ext, !ext.isEmpty {
            possibleFileNames = ["\(name).\(ext)"]
        } else {
            possibleFileNames = [name]
        }

        for directory in pathsToTry {
            for file in possibleFileNames {
                let candidate = directory.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
    }
}
