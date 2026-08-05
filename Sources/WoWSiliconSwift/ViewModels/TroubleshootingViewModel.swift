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
    @Published var rosettaStatus: String = "missing"
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
            let rosetta = runtime.rosettaLoaderURL != nil ? "ok" : "missing"

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
                self.rosettaStatus = rosetta
                self.debugLog = result.preview
                self.fullDebugLog = result.full
                self.status = .ready
            }
        }
    }

    func deleteWDB() {
        let gamePath = context.gamePath
        perform(action: "Deleting WDB directories…") {
            let deleted = try TroubleshootingService.deleteWDBDirectories(gamePath: gamePath)
            return "Deleted:\n" + deleted.joined(separator: "\n")
        }
    }

    func deleteWinePrefixes() {
        let gamePath = context.gamePath
        perform(action: "Deleting Wine prefixes…") {
            let deleted = try TroubleshootingService.deleteWinePrefixes(gamePath: gamePath)
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

    func resetApplicationSupport() {
        perform(action: "Resetting WoWSilicon…") {
            try TroubleshootingService.resetApplicationSupport()
            return "WoWSilicon configuration removed. Please restart the app."
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
