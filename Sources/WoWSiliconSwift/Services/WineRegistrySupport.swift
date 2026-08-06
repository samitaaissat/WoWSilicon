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

    static func makeWineEnvironment(prefixURL: URL, wineExecutable: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = prefixURL.path
        environment["__COMPAT_LAYER"] = "RunAsInvoker"

        let wineDirectory = (wineExecutable as NSString).deletingLastPathComponent
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
