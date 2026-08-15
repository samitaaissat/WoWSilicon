import XCTest
@testable import WoWSiliconSwift

/// The bug these guard: a game that dies mid-session left no artifact anywhere.
/// wine's own crash reporting goes to stderr, the auto-started wineserver's
/// fatal messages go to whatever stderr it inherited, and both launch paths
/// (Terminal window / in-app pipes) threw that stream away. A crash was
/// therefore unreproducible after the fact — "it just closed".
final class LaunchSessionLogTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LaunchSessionLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Log file allocation

    func testPrepareCreatesDirectoryAndTimestampedFile() throws {
        let logs = tempDirectory.appendingPathComponent("Logs", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))

        let url = try LaunchService.prepareSessionLogURL(in: logs)

        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.path))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, logs.standardizedFileURL)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("wine-session-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".log"))
    }

    func testPrepareKeepsOnlyTheNewestSessionLogs() throws {
        let logs = tempDirectory.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        // Twelve stale logs, oldest first, with distinct modification dates.
        var stale: [URL] = []
        for index in 0..<12 {
            let url = logs.appendingPathComponent("wine-session-2026010\(index % 10)-00000\(index).log")
            try "old \(index)".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: url.path
            )
            stale.append(url)
        }

        _ = try LaunchService.prepareSessionLogURL(in: logs, keepNewest: 5)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: logs.path)
            .filter { $0.hasPrefix("wine-session-") }
        // 4 newest survivors + the freshly allocated one.
        XCTAssertEqual(remaining.count, 5, "expected pruning down to keepNewest, got \(remaining)")
        XCTAssertFalse(remaining.contains(stale[0].lastPathComponent), "oldest log should have been pruned")
        XCTAssertTrue(remaining.contains(stale[11].lastPathComponent), "newest stale log should survive")
    }

    func testPruningIgnoresUnrelatedFiles() throws {
        let logs = tempDirectory.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let keeper = logs.appendingPathComponent("important-notes.txt")
        try "keep me".write(to: keeper, atomically: true, encoding: .utf8)
        for index in 0..<8 {
            try "x".write(to: logs.appendingPathComponent("wine-session-\(index).log"),
                          atomically: true, encoding: .utf8)
        }

        _ = try LaunchService.prepareSessionLogURL(in: logs, keepNewest: 2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path),
                      "pruning must only ever touch its own wine-session-*.log files")
    }

    func testPrepareThrowsOnUnwritableDirectory() {
        // A read-only data root (DMG, translocated app) must not yield a log
        // path: a `tee` that cannot open its file dies, and the game then takes
        // SIGPIPE on its next write to stdout. No log is strictly better.
        let unwritable = URL(fileURLWithPath: "/System/WoWSiliconLogsShouldNotBeCreatable")
        XCTAssertThrowsError(try LaunchService.prepareSessionLogURL(in: unwritable))
    }

    // MARK: - Command wrapping

    func testSessionLogPathWrapsCommandInTeeCapture() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: VersionSettings(),
            sessionLogPath: "/Data/Logs/wine-session-1.log"
        )

        // 2>&1 on the whole group, not just wine: an auto-started wineserver
        // inherits this stderr, and its fatal messages are the only record of
        // why a session died when the client dies silently in abort_thread().
        XCTAssertTrue(command.hasPrefix("{ cd \"/Games/WoW\" && "), command)
        XCTAssertTrue(command.hasSuffix("; } 2>&1 | tee -a \"/Data/Logs/wine-session-1.log\""), command)
        XCTAssertTrue(command.contains("echo \"[wowsilicon] wine exited with status $?\""), command)
        // The command it wraps is unchanged.
        XCTAssertTrue(command.contains("\"/rt/bin/wine\" \"/Games/WoW/WoW.exe\""), command)
    }

    func testSessionLogPathIsQuotedAndEscaped() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: VersionSettings(),
            sessionLogPath: "/Data/$(evil)/Logs/s.log"
        )

        XCTAssertTrue(command.hasSuffix("| tee -a \"/Data/\\$(evil)/Logs/s.log\""), command)
        XCTAssertFalse(command.contains("tee -a \"/Data/$(evil)"), command)
    }

    func testNilSessionLogPathLeavesCommandUnwrapped() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: VersionSettings()
        )

        XCTAssertTrue(command.hasPrefix("cd \"/Games/WoW\" && "))
        XCTAssertFalse(command.contains("tee"))
        XCTAssertFalse(command.contains("{ "))
    }

    func testLauncherCommandAlsoCapturesItsSession() {
        let command = LaunchService.makeLauncherShellCommand(
            exePath: "/Data/prefix/drive_c/Program Files/L/L.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: VersionSettings(),
            sessionLogPath: "/Data/Logs/launcher.log"
        )

        XCTAssertTrue(command.hasSuffix("; } 2>&1 | tee -a \"/Data/Logs/launcher.log\""), command)
    }

    /// The wrapper has to survive the AppleScript round-trip used by the
    /// "show terminal" launch path: `$?` must reach the shell unexpanded.
    func testWrappedCommandSurvivesAppleScriptEscaping() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: VersionSettings(),
            sessionLogPath: "/Data/Logs/s.log"
        )
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        XCTAssertTrue(escaped.contains("$?"), "AppleScript escaping must not mangle the status capture")
    }
}
