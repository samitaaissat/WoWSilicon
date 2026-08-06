import XCTest
@testable import WoWSiliconSwift

final class LaunchCommandTests: XCTestCase {
    private let winePath = "/Applications/WoWSilicon.app/Contents/SharedSupport/wine/bin/wine"
    private let loaderPath = "/Applications/WoWSilicon.app/Contents/Resources/Patching/rosettax87/rosettax87"
    private let prefixPath = "/Applications/WoWSilicon Data/prefix"

    func testFullCommandWithLoaderAndDefaultSettings() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW Classic",
            executablePath: "/Games/WoW Classic/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings()
        )

        XCTAssertEqual(
            command,
            "cd \"/Games/WoW Classic\" && " +
            "ROSETTA_X87_PATH=\"\(loaderPath)\" " +
            "WINEDLLOVERRIDES=\"d3d9=n,b;mscoree=d;mshtml=d\" MTL_HUD_ENABLED=0 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 DXVK_ASYNC=1 " +
            "WINEPREFIX=\"/Applications/WoWSilicon Data/prefix\" " +
            "\"\(winePath)\" \"/Games/WoW Classic/WoW.exe\""
        )
    }

    func testNilLoaderOmitsRosettaX87Path() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW Classic",
            executablePath: "/Games/WoW Classic/Installer.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: nil,
            winePrefixPath: prefixPath,
            settings: VersionSettings()
        )

        XCTAssertFalse(command.contains("ROSETTA_X87_PATH"))
        XCTAssertTrue(command.hasPrefix("cd \"/Games/WoW Classic\" && WINEDLLOVERRIDES=\"d3d9=n,b;mscoree=d;mshtml=d\" "))
    }

    func testCustomEnvironmentVariablesAreFlattenedBeforeBaseEnv() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings(environmentVariables: "A=1\nB=2")
        )

        XCTAssertTrue(command.contains("ROSETTA_X87_PATH=\"\(loaderPath)\" A=\"1\" B=\"2\" WINEDLLOVERRIDES="))
    }

    func testShellMetacharactersInPathsAreEmittedLiterally() {
        let sneakyPath = "/Games/$(rm -rf x)/WoW`ev`il\\"
        let command = LaunchService.makeShellCommand(
            gamePath: sneakyPath,
            executablePath: sneakyPath + "/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings()
        )

        // `$`, backticks, and trailing backslashes must be backslash-escaped inside
        // the double-quoted path so the shell cannot expand or execute them.
        let expectedQuotedPath = "\"/Games/\\$(rm -rf x)/WoW\\`ev\\`il\\\\\""
        XCTAssertTrue(command.hasPrefix("cd \(expectedQuotedPath) && "))
        XCTAssertTrue(command.contains("\(expectedQuotedPath.dropLast())/WoW.exe\""))
        XCTAssertFalse(command.contains("cd \"/Games/$(rm -rf x)"))
    }

    func testCustomEnvironmentVariableValuesAreQuoted() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings(environmentVariables: "MY_DIR=/tmp/$(whoami) FLAG")
        )

        XCTAssertTrue(command.contains("MY_DIR=\"/tmp/\\$(whoami)\" FLAG "))
    }

    func testMetalHudTogglesEnvironmentValue() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings(enableMetalHud: true)
        )

        XCTAssertTrue(command.contains("MTL_HUD_ENABLED=1"))
        XCTAssertFalse(command.contains("MTL_HUD_ENABLED=0"))
    }

    func testExtraArgumentsAreAppendedQuotedAfterExecutable() {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/Launcher",
            executablePath: "/Games/Launcher/Launcher.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings(),
            extraArguments: ["--disable-gpu", "--in-process-gpu"]
        )

        XCTAssertTrue(command.hasSuffix("\"/Games/Launcher/Launcher.exe\" \"--disable-gpu\" \"--in-process-gpu\""))
    }

    func testWinePrefixIsPinnedQuotedAndEscaped() {
        let hostilePrefix = "/Volumes/USB Stick/WoWSilicon Data/$(evil)/prefix"
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: hostilePrefix,
            settings: VersionSettings()
        )

        XCTAssertTrue(command.contains("WINEPREFIX=\"/Volumes/USB Stick/WoWSilicon Data/\\$(evil)/prefix\""))
    }

    func testAppWinePrefixPinOverridesUserSuppliedOne() throws {
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings(environmentVariables: "WINEPREFIX=/tmp/user-prefix")
        )

        let userIndex = try XCTUnwrap(command.range(of: "WINEPREFIX=\"/tmp/user-prefix\"")).lowerBound
        let appIndex = try XCTUnwrap(command.range(of: "WINEPREFIX=\"\(prefixPath)\"")).lowerBound
        // sh applies the LAST assignment of a duplicated env var; the app's pin
        // must therefore appear after the user's.
        XCTAssertLessThan(userIndex, appIndex)
    }
}
