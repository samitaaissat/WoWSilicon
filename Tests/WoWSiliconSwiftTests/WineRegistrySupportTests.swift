import XCTest
@testable import WoWSiliconSwift

final class WineRegistrySupportTests: XCTestCase {
    func testWineBinaryPathThrowsWineRuntimeErrorWhenBundledRuntimeIsAbsent() {
        // The swift-test runner's Bundle.main carries no Contents/SharedSupport/wine
        // payload, so resolution must surface WineRuntime's typed error.
        let expectedPath = WineRuntime.shared.wineBinaryURL.path
        XCTAssertThrowsError(try WineRegistrySupport.wineBinaryPath()) { error in
            XCTAssertEqual(error as? WineRuntimeError, .wineBinaryMissing(expectedPath))
        }
    }

    func testMakeWineEnvironmentSetsPrefixCompatLayerAndPrependsWineDirectoryToPath() {
        let prefixURL = URL(fileURLWithPath: "/tmp/wowsilicon-test-prefix", isDirectory: true)
        let wineExecutable = "/opt/wowsilicon-test/wine-runtime/bin/wine"

        let environment = WineRegistrySupport.makeWineEnvironment(prefixURL: prefixURL, wineExecutable: wineExecutable)

        XCTAssertEqual(environment["WINEPREFIX"], prefixURL.path)
        XCTAssertEqual(environment["__COMPAT_LAYER"], "RunAsInvoker")

        let pathComponents = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertEqual(pathComponents.first, "/opt/wowsilicon-test/wine-runtime/bin")
        XCTAssertEqual(pathComponents.filter { $0 == "/opt/wowsilicon-test/wine-runtime/bin" }.count, 1)
    }
}
