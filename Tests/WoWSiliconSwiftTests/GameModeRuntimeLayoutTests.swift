import XCTest
@testable import WoWSiliconSwift

/// macOS Game Mode only turns on for a process whose real executable path is
/// `<Something>.app/Contents/MacOS/<anything>` and whose bundle declares a games
/// category (verified empirically on macOS 27: a binary at
/// `…/Contents/SharedSupport/wine/bin/wine` gets no LaunchServices bundle record,
/// and one nested at `…/Contents/MacOS/bin/wine` does not qualify either).
/// These tests pin the runtime layout that satisfies that rule.
final class GameModeRuntimeLayoutTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/Applications/WoWSilicon.app", isDirectory: true)

    private var runtime: WineRuntime { WineRuntime(bundleURL: bundleURL) }

    func testWineBinaryLivesInTheGameAppContentsMacOS() {
        XCTAssertEqual(
            runtime.wineBinaryURL.path,
            "/Applications/WoWSilicon.app/Contents/SharedSupport/WoWSilicon Game.app/Contents/MacOS/wine"
        )
    }

    func testWineserverSitsBesideWineSoExecWineserverResolvesViaWINESERVER() {
        XCTAssertEqual(
            runtime.wineserverBinaryURL.deletingLastPathComponent(),
            runtime.wineBinaryURL.deletingLastPathComponent()
        )
        XCTAssertEqual(runtime.wineserverBinaryURL.lastPathComponent, "wineserver")
    }

    /// Wine execs $ROSETTA_X87_PATH as argv[0] for i386 images with argv[1] set to
    /// its ntdll-derived loader path in Contents/lib — a path that destroys bundle
    /// identity at the final exec. ROSETTA_X87_PATH therefore points at the
    /// gamemode shim, which rewrites argv[1] to the physical Contents/MacOS/wine
    /// before exec'ing the real rosettax87 beside it.
    func testRosettaLoaderPathIsTheGameModeShimBesideWine() throws {
        let loader = try XCTUnwrap(runtime.rosettaLoaderURL)

        XCTAssertEqual(
            loader.deletingLastPathComponent(),
            runtime.wineBinaryURL.deletingLastPathComponent()
        )
        XCTAssertEqual(loader.lastPathComponent, "wine-rosetta-shim")
    }

    /// Depth breaks identification — the binary must sit directly in Contents/MacOS,
    /// not in a subdirectory of it.
    func testExecutablesSitDirectlyInAnAppContentsMacOSWithNoNesting() throws {
        for url in [runtime.wineBinaryURL, runtime.wineserverBinaryURL, try XCTUnwrap(runtime.rosettaLoaderURL)] {
            let macOSDirectory = url.deletingLastPathComponent()
            let contentsDirectory = macOSDirectory.deletingLastPathComponent()
            let appDirectory = contentsDirectory.deletingLastPathComponent()

            XCTAssertEqual(macOSDirectory.lastPathComponent, "MacOS", "\(url.path) is not directly in Contents/MacOS")
            XCTAssertEqual(contentsDirectory.lastPathComponent, "Contents", "\(url.path) is nested too deep")
            XCTAssertTrue(appDirectory.lastPathComponent.hasSuffix(".app"), "\(url.path) is not inside an .app bundle")
        }
    }

    func testGameAppInfoPlistAndLibrariesAreSiblingsOfMacOS() {
        let contents = runtime.gameAppURL.appendingPathComponent("Contents", isDirectory: true)

        XCTAssertEqual(runtime.runtimeRootURL, contents)
        XCTAssertEqual(runtime.gameAppInfoPlistURL, contents.appendingPathComponent("Info.plist"))
        // wine resolves its dll/data dirs as <bindir>/../lib and <bindir>/../share.
        XCTAssertEqual(
            runtime.wineBinaryURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib"),
            contents.appendingPathComponent("lib")
        )
    }
}
