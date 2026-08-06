import XCTest
@testable import WoWSiliconSwift

final class WineRegistrySupportTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWSiliconSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    func testWinePrefixURLDerivesFromPortableStorage() throws {
        let parent = try makeTemporaryDirectory()
        let fallback = try makeTemporaryDirectory()
        let storage = PortableStorage(
            bundleURL: parent.appendingPathComponent("WoWSilicon.app", isDirectory: true),
            fallbackSupportRoot: fallback
        )

        XCTAssertEqual(WineRegistrySupport.winePrefixURL(storage: storage), storage.prefixURL)
        XCTAssertEqual(
            WineRegistrySupport.userRegURL(storage: storage),
            storage.prefixURL.appendingPathComponent("user.reg")
        )
        XCTAssertFalse(WineRegistrySupport.winePrefixURL(storage: storage).path.hasSuffix("/.wine"),
                       "the shared global ~/.wine must no longer be the app's prefix")
    }

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
