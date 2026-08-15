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

    /// Wine re-execs i386 images through $X87_SIDECAR_PATH as
    /// [loader, --cooperative, <ntdll-derived loader path in Contents/lib>, …] —
    /// a loader path that destroys bundle identity at the final exec.
    /// X87_SIDECAR_PATH therefore points at the gamemode shim, which rewrites
    /// the loader argument to the physical Contents/MacOS/wine-gamemode copy
    /// before exec'ing the real x87sidecar beside it.
    func testX87LoaderPathIsTheGameModeShimBesideWine() throws {
        let loader = try XCTUnwrap(runtime.x87LoaderURL)

        XCTAssertEqual(
            loader.deletingLastPathComponent(),
            runtime.wineBinaryURL.deletingLastPathComponent()
        )
        XCTAssertEqual(loader.lastPathComponent, "wine-rosetta-shim")
    }

    /// Depth breaks identification — the binary must sit directly in Contents/MacOS,
    /// not in a subdirectory of it.
    func testExecutablesSitDirectlyInAnAppContentsMacOSWithNoNesting() throws {
        for url in [runtime.wineBinaryURL, runtime.wineserverBinaryURL, try XCTUnwrap(runtime.x87LoaderURL)] {
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
