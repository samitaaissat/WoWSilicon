import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class TroubleshootingViewModel: ObservableObject, Identifiable {
    let id = UUID()

    enum Status {
        case idle
        case busy(String)
        case ready
    }

    @Published var status: Status = .idle
    @Published var runtimeVersion: String = "Not found"
    @Published var runtimeSource: String = "bundled"
    @Published var x87LoaderStatus: String = "missing"
    @Published var storageDescription: String = ""
    @Published var debugLog: String = ""
    private var fullDebugLog: String = ""
    @Published var alert: ManagerAlert?
    
    @Published var hideMacUserName: Bool = true {
        didSet { if oldValue != hideMacUserName { refresh() } }
    }
    @Published var includeLatestErrorLog: Bool = false {
        didSet { if oldValue != includeLatestErrorLog { refresh() } }
    }

    private let context: TroubleshootingContext

    init(context: TroubleshootingContext) {
        self.context = context
    }

    func refresh() {
        status = .busy("Collecting information…")
        let context = self.context
        Task.detached { [weak self] in
            guard let self else { return }

            let runtime = WineRuntime.shared
            let version = runtime.runtimeVersion ?? "Not found"
            let source = runtime.isUsingDownloadedRuntime ? "downloaded update" : "bundled"
            // x87LoaderURL is a constructed path (never nil) — probe the file.
            let x87Loader = (try? runtime.validatedX87LoaderURL()) != nil ? "ok" : "missing"
            let storageDescription = PortableStorage.shared.displayDescription

            // Capture current toggle states
            let hideName = await self.hideMacUserName
            let includeLog = await self.includeLatestErrorLog

            let result = TroubleshootingService.generateDebugLog(
                context: context,
                hideMacUserName: hideName,
                includeLatestErrorLog: includeLog
            )

            Task { @MainActor in
                self.runtimeVersion = version
                self.runtimeSource = source
                self.x87LoaderStatus = x87Loader
                self.storageDescription = storageDescription
                self.debugLog = result.preview
                self.fullDebugLog = result.full
                self.status = .ready
            }
        }
    }

    /// Manually triggers the same background check `RuntimeUpdateService`
    /// runs once per launch — mostly useful to confirm the app can reach
    /// GitHub, or to pull down a fix without waiting for the daily check.
    func checkForRuntimeUpdates() {
        guard case .busy = status else {
            status = .busy("Checking for runtime updates…")
            // Detached: the check shells out to tar/ditto, which block for as
            // long as the download/extraction takes — must not run on an
            // actor's executor (see refresh() above for the same pattern).
            Task.detached { [weak self] in
                do {
                    try await RuntimeUpdateService.shared.checkForUpdatesIfNeeded(force: true)
                    Task { @MainActor in
                        guard let self else { return }
                        self.status = .ready
                        self.alert = ManagerAlert(message: "Runtime update check complete.")
                        self.refresh()
                    }
                } catch {
                    Task { @MainActor in
                        guard let self else { return }
                        self.status = .ready
                        self.alert = ManagerAlert(message: error.localizedDescription)
                    }
                }
            }
            return
        }
    }

    func deleteWDB() {
        let gamePath = context.gamePath
        perform(action: "Deleting WDB directories…") {
            let deleted = try TroubleshootingService.deleteWDBDirectories(gamePath: gamePath)
            return "Deleted:\n" + deleted.joined(separator: "\n")
        }
    }

    func resetWinePrefix() {
        perform(action: "Resetting the Wine prefix…") {
            let deleted = try TroubleshootingService.deleteDedicatedPrefix()
            return "Deleted:\n" + deleted.joined(separator: "\n") + "\n\nThe Wine environment will be set up again on the next launch."
        }
    }

    func deleteLegacyPrefixes() {
        let gamePath = context.gamePath
        perform(action: "Deleting legacy Wine prefixes…") {
            let deleted = try TroubleshootingService.deleteLegacyPrefixes(gamePath: gamePath)
            return "Deleted:\n" + deleted.joined(separator: "\n")
        }
    }

    func restoreCrossOver() {
        let customPath = context.currentVersion?.crossOverPath.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let crossOverPath = customPath.isEmpty ? "/Applications/CrossOver.app" : customPath
        perform(action: "Restoring CrossOver…") {
            let result = TroubleshootingService.restoreCrossOverModifications(atCrossOverPath: crossOverPath)
            var lines: [String] = []
            if result.restoredNtdll { lines.append("Restored ntdll.so from backup.") }
            if result.restoredWine { lines.append("Restored wine from backup.") }
            if result.removedWineloader2 { lines.append("Removed wineloader2.") }
            if lines.isEmpty {
                return "No WoWSilicon modifications found at \(crossOverPath)."
            }
            return lines.joined(separator: "\n")
        }
    }

    func deleteVanillaTweaks() {
        let gamePath = context.gamePath
        perform(action: "Deleting WoW_tweaked.exe…") {
            try TroubleshootingService.deleteVanillaTweaks(gamePath: gamePath)
            return "WoW_tweaked.exe deleted successfully."
        }
    }

    func resetStorage() {
        perform(action: "Resetting WoWSilicon…") {
            let deleted = try TroubleshootingService.resetStorage()
            return "Deleted:\n" + deleted.joined(separator: "\n") + "\n\nPlease restart the app."
        }
    }

    func copyDebugLog() {
#if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullDebugLog, forType: .string)
#endif
        alert = ManagerAlert(message: "Debug log copied to clipboard.")
    }

    private func perform(action: String, work: @escaping @Sendable () throws -> String) {
        guard case .busy = status else {
            status = .busy(action)
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    let message = try work()
                    Task { @MainActor in
                        self.status = .ready
                        self.alert = ManagerAlert(message: message)
                        self.refresh()
                    }
                } catch {
                    Task { @MainActor in
                        self.status = .ready
                        if let svcError = error as? TroubleshootingServiceError {
                            switch svcError {
                            case .nothingToDelete:
                                self.alert = ManagerAlert(message: "Nothing to delete for this action.")
                            default:
                                self.alert = ManagerAlert(message: svcError.localizedDescription)
                            }
                        } else {
                            self.alert = ManagerAlert(message: error.localizedDescription)
                        }
                        self.refresh()
                    }
                }
            }
            return
        }
    }
}
