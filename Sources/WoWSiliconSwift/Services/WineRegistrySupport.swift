import Foundation

enum WineRegistrySupport {
    static let macDriverRegistryKey = #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
    static let macDriverSection = "[Software\\Wine\\Mac Driver]"
    static let legacyMacDriverSection = "[Software\\\\Wine\\\\Mac Driver]"
    static let timestampLine = "#time=1dbd859c084de18"

    /// The app's dedicated Wine prefix. Every registry/dependency operation and
    /// every direct user.reg read/write routes through this one function — it is
    /// the single choke point that keeps the app off the shared global ~/.wine.
    static func winePrefixURL(storage: PortableStorage = .shared) -> URL {
        storage.prefixURL
    }

    static func userRegURL(storage: PortableStorage = .shared) -> URL {
        winePrefixURL(storage: storage).appendingPathComponent("user.reg")
    }

    static func isMacDriverSection(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(macDriverSection) || trimmed.hasPrefix(legacyMacDriverSection)
    }

    static func wineBinaryPath() throws -> String {
        try WineRuntime.shared.validatedWineBinaryURL().path
    }

    /// The app-wide msync setting. msync is a property of the *wineserver*, and
    /// every version shares one prefix and therefore one server, so this is a
    /// global preference rather than a per-version one.
    static var msyncEnabled: Bool {
        UserPrefsStore(configDirectory: PortableStorage.shared.configDirectory).load().enableMsync
    }

    /// Builds the environment for every non-launch Wine invocation (registry edits,
    /// prefix bootstrap, dependency installs). These all drive the same prefix and
    /// hence the same wineserver as the game, so `WINEMSYNC` must match what
    /// `LaunchService.makeShellCommand` emits — a mismatch is a hard exit(1), not a
    /// degraded mode. It defaults to the global preference so the two paths cannot
    /// drift; tests pass it explicitly.
    static func makeWineEnvironment(
        prefixURL: URL,
        wineExecutable: String,
        enableMsync: Bool = WineRegistrySupport.msyncEnabled
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = prefixURL.path
        environment["__COMPAT_LAYER"] = "RunAsInvoker"
        environment["WINEMSYNC"] = enableMsync ? "1" : "0"

        let wineDirectory = (wineExecutable as NSString).deletingLastPathComponent
        // wine's exec_wineserver() derives <bin_dir>/wineserver from the dll dir,
        // which no longer resolves under the nested game .app layout.
        environment["WINESERVER"] = wineDirectory + "/wineserver"
        if var path = environment["PATH"] {
            let components = path.split(separator: ":").map(String.init)
            if !components.contains(wineDirectory) {
                path = "\(wineDirectory):\(path)"
                environment["PATH"] = path
            }
        } else {
            environment["PATH"] = wineDirectory
        }

        return environment
    }
}
