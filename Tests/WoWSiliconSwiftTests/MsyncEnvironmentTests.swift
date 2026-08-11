import XCTest
@testable import WoWSiliconSwift

/// msync is compiled into the bundled Wine runtime unconditionally and gated only
/// by `getenv("WINEMSYNC") && atoi(getenv("WINEMSYNC"))`. A client that disagrees
/// with the running wineserver calls exit(1), so every invocation that touches the
/// shared prefix must emit the same value.
final class MsyncEnvironmentTests: XCTestCase {
    private let winePath = "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/wine"
    private let loaderPath = "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/rosettax87"
    private let prefixPath = "/Applications/WoWSilicon Data/prefix"

    private func command(_ settings: VersionSettings) -> String {
        LaunchService.makeShellCommand(
            gamePath: "/Games/WoW",
            executablePath: "/Games/WoW/WoW.exe",
            wineBinaryPath: winePath,
            rosettaLoaderPath: loaderPath,
            winePrefixPath: prefixPath,
            settings: settings
        )
    }

    // MARK: - Launch command

    /// Emitted explicitly rather than omitted: an inherited or user-typed
    /// WINEMSYNC would otherwise desync the client from a wineserver that the
    /// registry helpers started with msync off, which is a hard exit(1).
    func testLaunchCommandPinsMsyncOffByDefault() {
        XCTAssertTrue(command(VersionSettings()).contains("WINEMSYNC=0"))
    }

    /// The gate runs the value through atoi(), so only a nonzero numeric literal
    /// works — "true"/"yes"/"on" all silently leave msync off.
    func testLaunchCommandEnablesMsyncWithNumericOne() {
        XCTAssertTrue(command(VersionSettings(enableMsync: true)).contains("WINEMSYNC=1"))
    }

    func testLaunchCommandPinsWineserverPathBecauseBinDirNoLongerResolves() {
        // exec_wineserver() tries <bin_dir>/wineserver first; with the runtime
        // restaged into Contents/MacOS that derives to a nonexistent Contents/bin,
        // so WINESERVER must be pinned explicitly.
        let expected = "WINESERVER=\"/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/wineserver\""
        XCTAssertTrue(command(VersionSettings()).contains(expected))
    }

    func testAppMsyncPinOverridesUserSuppliedValue() throws {
        let result = command(VersionSettings(enableMsync: false, environmentVariables: "WINEMSYNC=1"))

        // The app's own assignment must come last so sh applies it, otherwise a
        // user-typed WINEMSYNC desynchronises the client from the wineserver.
        let userRange = try XCTUnwrap(result.range(of: "WINEMSYNC=\"1\""))
        let appRange = try XCTUnwrap(result.range(of: "WINEMSYNC=0"))
        XCTAssertLessThan(userRange.lowerBound, appRange.lowerBound)
    }

    // MARK: - Shared wineserver path

    func testMakeWineEnvironmentSetsMsyncWhenEnabled() {
        let environment = WineRegistrySupport.makeWineEnvironment(
            prefixURL: URL(fileURLWithPath: prefixPath, isDirectory: true),
            wineExecutable: winePath,
            enableMsync: true
        )

        XCTAssertEqual(environment["WINEMSYNC"], "1")
    }

    func testMakeWineEnvironmentDisablesMsyncExplicitlyRatherThanUnsettingIt() {
        let environment = WineRegistrySupport.makeWineEnvironment(
            prefixURL: URL(fileURLWithPath: prefixPath, isDirectory: true),
            wineExecutable: winePath,
            enableMsync: false
        )

        // An inherited WINEMSYNC from the app's own environment would otherwise
        // leak into these helpers and desync them from the launch path.
        XCTAssertEqual(environment["WINEMSYNC"], "0")
    }

    func testMakeWineEnvironmentPinsWineserverBesideWine() {
        let environment = WineRegistrySupport.makeWineEnvironment(
            prefixURL: URL(fileURLWithPath: prefixPath, isDirectory: true),
            wineExecutable: winePath,
            enableMsync: false
        )

        XCTAssertEqual(
            environment["WINESERVER"],
            "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/wineserver"
        )
    }

    // MARK: - DivxDecoder patching path

    /// patchDivxDecoder spawns wine too, so it must carry the same WINESERVER
    /// pin (wine cannot autostart a server under the nested game .app layout
    /// otherwise) and the same WINEMSYNC value as every other invocation.
    func testDivxPatchEnvironmentCarriesWineserverPinAndMsync() {
        let environment = PatchService.makeDivxPatchEnvironment(
            prefixURL: URL(fileURLWithPath: prefixPath, isDirectory: true),
            wineExecutable: winePath,
            enableMsync: true
        )

        XCTAssertEqual(
            environment["WINESERVER"],
            "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/wineserver"
        )
        XCTAssertEqual(environment["WINEMSYNC"], "1")
        XCTAssertEqual(environment["WINEPREFIX"], prefixPath)
        XCTAssertEqual(environment["WINEDLLOVERRIDES"], "winemenubuilder.exe=d;mscoree=d;mshtml=d")
        XCTAssertEqual(environment["WINEDEBUG"], "-all")
        let pathComponents = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(pathComponents.first, (winePath as NSString).deletingLastPathComponent)
    }

    // MARK: - Persistence

    func testUserPrefsDefaultsMsyncOffAndDecodesFilesWithoutTheKey() throws {
        let json = "{\"enable_metal_hud\": true}"

        let prefs = try JSONDecoder().decode(UserPrefs.self, from: Data(json.utf8))

        XCTAssertFalse(prefs.enableMsync)
        XCTAssertTrue(prefs.enableMetalHud)
    }

    func testUserPrefsRoundTripsMsync() throws {
        var prefs = UserPrefs.defaults
        prefs.enableMsync = true

        let decoded = try JSONDecoder().decode(UserPrefs.self, from: JSONEncoder().encode(prefs))

        XCTAssertTrue(decoded.enableMsync)
    }

    func testVersionSettingsDefaultsMsyncOffAndDecodesFilesWithoutTheKey() throws {
        let json = "{\"enableMetalHud\": true}"

        let settings = try JSONDecoder().decode(VersionSettings.self, from: Data(json.utf8))

        XCTAssertFalse(settings.enableMsync)
    }

    func testVersionSettingsRoundTripsMsync() throws {
        let settings = VersionSettings(enableMsync: true)

        let decoded = try JSONDecoder().decode(VersionSettings.self, from: JSONEncoder().encode(settings))

        XCTAssertTrue(decoded.enableMsync)
    }
}
