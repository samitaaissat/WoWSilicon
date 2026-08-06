import Foundation

enum PrefixBootstrapError: LocalizedError {
    case runtimeVersionUnknown
    case bootFailed(String)
    case timedOut
    case structureInvalid

    var errorDescription: String? {
        switch self {
        case .runtimeVersionUnknown:
            return "The bundled Wine runtime version could not be read. Please reinstall WoWSilicon."
        case .bootFailed(let output):
            return output.isEmpty ? "Setting up the Wine environment failed." : output
        case .timedOut:
            return "Setting up the Wine environment took too long and was cancelled. Please try again."
        case .structureInvalid:
            return "The Wine environment was not set up completely. Please try again."
        }
    }
}

/// Explicit, sentinel-gated initialization of the dedicated Wine prefix.
///
/// wine stamps its own .update-timestamp BEFORE running the install sections,
/// so an interrupted implicit init looks permanently complete to wine and is
/// never repaired. This service therefore (a) initializes explicitly with a
/// generous timeout, (b) records success in an app-owned sentinel written only
/// after a structural sanity check, and (c) deletes the half-built prefix on
/// any failure so the next attempt starts clean.
final class PrefixBootstrapService: @unchecked Sendable {
    typealias Runner = @Sendable (
        _ executablePath: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ timeout: TimeInterval
    ) throws -> ProcessRunResult

    static let shared = PrefixBootstrapService()
    static let sentinelFileName = ".wowsilicon-prefix-ok"

    static let defaultRunner: Runner = { executablePath, arguments, environment, timeout in
        try ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }

    private let storage: PortableStorage
    private let runtime: WineRuntime
    private let fileManager: FileManager
    private let runner: Runner
    private let bootstrapLock = NSLock()

    init(storage: PortableStorage = .shared,
         runtime: WineRuntime = .shared,
         fileManager: FileManager = .default,
         runner: @escaping Runner = PrefixBootstrapService.defaultRunner) {
        self.storage = storage
        self.runtime = runtime
        self.fileManager = fileManager
        self.runner = runner
    }

    /// Ready = sentinel content equals the bundled runtime version AND the
    /// prefix structure is sane. Never trust wine's .update-timestamp.
    func isPrefixReady() -> Bool {
        guard let runtimeVersion = runtime.runtimeVersion else { return false }
        let sentinelURL = storage.prefixURL.appendingPathComponent(Self.sentinelFileName)
        guard let contents = try? String(contentsOf: sentinelURL, encoding: .utf8) else { return false }
        return contents == runtimeVersion && structureLooksSane()
    }

    func bootstrapIfNeeded() throws {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        guard !isPrefixReady() else { return }
        try bootstrap()
    }

    private func bootstrap() throws {
        guard let runtimeVersion = runtime.runtimeVersion else {
            throw PrefixBootstrapError.runtimeVersionUnknown
        }
        let wine = try runtime.validatedWineBinaryURL().path
        let prefix = storage.prefixURL
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        excludeFromBackup(prefix)

        var environment = WineRegistrySupport.makeWineEnvironment(prefixURL: prefix, wineExecutable: wine)
        environment["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;mscoree=d;mshtml=d"

        do {
            // wineboot -u forces the update pass even when wine's own timestamp
            // says "up to date" — the only way to repair a half-built prefix.
            // 600 s: wine's implicit boot wait is hardcoded to 5 minutes; the
            // dual-arch inf pass under cold Rosetta needs the headroom.
            let boot = try runner(wine, ["wineboot", "-u"], environment, 600)
            guard boot.exitCode == 0 else {
                removeHalfBuiltPrefix()
                throw PrefixBootstrapError.bootFailed(boot.combinedOutput)
            }
            // Wait for wineserver to flush the registry and exit.
            _ = try? runner(runtime.wineserverBinaryURL.path, ["-w"], environment, 120)
        } catch let error as ProcessRunnerError {
            gracefullyStopWineserver(environment: environment)
            removeHalfBuiltPrefix()
            if case .timedOut = error {
                throw PrefixBootstrapError.timedOut
            }
            throw PrefixBootstrapError.bootFailed(error.localizedDescription)
        }

        guard structureLooksSane() else {
            removeHalfBuiltPrefix()
            throw PrefixBootstrapError.structureInvalid
        }

        let sentinelURL = prefix.appendingPathComponent(Self.sentinelFileName)
        try runtimeVersion.write(to: sentinelURL, atomically: true, encoding: .utf8)
    }

    private func structureLooksSane() -> Bool {
        let prefix = storage.prefixURL
        let cDrive = prefix.appendingPathComponent("dosdevices/c:")
        guard fileManager.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
              fileManager.fileExists(atPath: prefix.appendingPathComponent("user.reg").path),
              fileManager.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows").path),
              (try? fileManager.destinationOfSymbolicLink(atPath: cDrive.path)) != nil else {
            return false
        }
        return true
    }

    private func gracefullyStopWineserver(environment: [String: String]) {
        _ = try? runner(runtime.wineserverBinaryURL.path, ["-k"], environment, 10)
    }

    private func removeHalfBuiltPrefix() {
        try? fileManager.removeItem(at: storage.prefixURL)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
