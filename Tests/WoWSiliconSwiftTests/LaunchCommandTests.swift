import XCTest
@testable import WoWSiliconSwift

final class LaunchCommandTests: XCTestCase {
    private let winePath = "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/wine"
    private let loaderPath = "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/rosettax87"
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
            "WINEMSYNC=0 WINESERVER=\"/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/wineserver\" " +
            "WINEPREFIX=\"/Applications/WoWSilicon Data/prefix\" " +
            "\"\(winePath)\" \"/Games/WoW Classic/WoW.exe\""
        )
    }

    func testMakeShellCommandWithD9mtRendererDropsMoltenVKVars() {
        var settings = VersionSettings()
        settings.renderer = .d9mt
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: settings
        )

        XCTAssertFalse(command.contains("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"))
        XCTAssertFalse(command.contains("DXVK_ASYNC"))
        XCTAssertTrue(command.contains("D9MT_METALLIB_CACHE=1"))
        XCTAssertTrue(command.contains("D9MT_ASYNC=1"))
        XCTAssertTrue(command.contains(#"WINEDLLOVERRIDES="d3d9=n,b;mscoree=d;mshtml=d""#))
    }

    func testMakeShellCommandWithD9vkRendererKeepsCurrentEnv() {
        let settings = VersionSettings() // default .d9vk
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: settings
        )

        XCTAssertTrue(command.contains("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1"))
        XCTAssertTrue(command.contains("DXVK_ASYNC=1"))
        XCTAssertFalse(command.contains("D9MT_"))
    }

    func testMakeShellCommandWithWineD3DRendererForcesBuiltinD3D9() {
        var settings = VersionSettings()
        settings.renderer = .wined3d
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: settings
        )

        // Builtin-only d3d9: a stray native d3d9.dll must never shadow wined3d.
        XCTAssertTrue(command.contains(#"WINEDLLOVERRIDES="d3d9=b;mscoree=d;mshtml=d""#))
        // MoltenVK is still the presentation path (same rationale as d9vk)...
        XCTAssertTrue(command.contains("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1"))
        // ...but the DXVK/d9mt-specific toggles are meaningless to wined3d.
        XCTAssertFalse(command.contains("DXVK_ASYNC"))
        XCTAssertFalse(command.contains("D9MT_"))
    }

    /// The wined3d renderer is selected per-launch through WINE_D3D_CONFIG (env
    /// beats the registry in wined3d_main.c, and env needs no prefix state):
    /// full-string pin so the env block stays exactly as verified on hardware.
    func testWineD3DCommandSelectsVulkanRendererViaEnvironment() {
        var settings = VersionSettings()
        settings.renderer = .wined3d
        let command = LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: "/rt/bin/wine",
            rosettaLoaderPath: nil,
            winePrefixPath: "/prefix",
            settings: settings
        )

        XCTAssertEqual(
            command,
            "cd \"/Games/WoW\" && " +
            "WINEDLLOVERRIDES=\"d3d9=b;mscoree=d;mshtml=d\" MTL_HUD_ENABLED=0 " +
            "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 WINE_D3D_CONFIG=\"renderer=vulkan\" " +
            "WINEMSYNC=0 WINESERVER=\"/rt/bin/wineserver\" WINEPREFIX=\"/prefix\" " +
            "\"/rt/bin/wine\" \"/Games/WoW/WoW.exe\""
        )
    }

    /// The other renderers must not carry the wined3d selector: their native
    /// d3d9.dll shadows the builtin, and a stray WINE_D3D_CONFIG would only
    /// confuse debugging.
    func testNonWineD3DCommandsDoNotSetWineD3DConfig() {
        for renderer in [RendererBackend.d9vk, .d9mt] {
            var settings = VersionSettings()
            settings.renderer = renderer
            let command = LaunchService.makeShellCommand(
                gamePath: "/Games/WoW",
                executablePath: "/Games/WoW/WoW.exe",
                wineBinaryPath: "/rt/bin/wine",
                rosettaLoaderPath: nil,
                winePrefixPath: "/prefix",
                settings: settings
            )
            XCTAssertFalse(command.contains("WINE_D3D_CONFIG"), "\(renderer) must not set WINE_D3D_CONFIG")
        }
    }

    func testLauncherCommandWithWineD3DRendererForcesBuiltinD3D9() {
        var settings = VersionSettings()
        settings.renderer = .wined3d
        let command = LaunchService.makeLauncherShellCommand(
            exePath: "/Data/prefix/drive_c/Program Files/Launcher/Launcher.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: settings
        )

        XCTAssertTrue(command.contains("WINEDLLOVERRIDES=\"d3d9=b;mscoree=b;mshtml=d\""))
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

    func testLauncherCommandUsesSwiftShaderNotGpuDisableFlags() {
        let command = LaunchService.makeLauncherShellCommand(
            exePath: "/Data/prefix/drive_c/Program Files/Launcher/Launcher.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings()
        )

        // Regression guard, verified against Ascension Launcher 1.0.102 on the
        // bundled wine-11.14: `--disable-gpu`/`--in-process-gpu` (CrossOver-era)
        // leave Electron windowless (GPU thread NOTREACHED loop), and NO flags
        // leaves the window blank (wined3d presents no pixels). Only the SwANGLE
        // software path renders.
        XCTAssertTrue(command.hasSuffix(
            "\"/Data/prefix/drive_c/Program Files/Launcher/Launcher.exe\" " +
            "\"--use-gl=angle\" \"--use-angle=swiftshader\" \"--enable-unsafe-swiftshader\""
        ))
        XCTAssertFalse(command.contains("--disable-gpu"))
        XCTAssertFalse(command.contains("--in-process-gpu"))
        XCTAssertTrue(command.hasPrefix("cd \"/Data/prefix/drive_c/Program Files/Launcher\" && "))
    }

    func testLauncherCommandLeavesMscoreeEnabledForManagedDLLs() {
        let command = LaunchService.makeLauncherShellCommand(
            exePath: "/Data/prefix/drive_c/Program Files/Ascension Launcher/Ascension Launcher.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: VersionSettings()
        )

        XCTAssertTrue(command.contains("WINEDLLOVERRIDES=\"d3d9=n,b;mscoree=b;mshtml=d\""))
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
