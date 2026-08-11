import XCTest
@testable import WoWSiliconSwift

final class TelemetryRendererTests: XCTestCase {
    private func makeVersion(renderer: RendererBackend) -> GameVersion {
        var settings = VersionSettings()
        settings.renderer = renderer
        return GameVersion(
            id: "test",
            displayName: "Test",
            wowVersion: "3.3.5a",
            executableName: "WoW.exe",
            supportsVanillaTweaks: false,
            supportsDLLLoading: true,
            usesRosettaPatching: true,
            usesDivxDecoderPatch: false,
            settings: settings
        )
    }

    func testContextReportsD9mtWhenVersionUsesD9mt() {
        let context = TelemetryEventContext(version: makeVersion(renderer: .d9mt))
        XCTAssertEqual(context.renderer, "d9mt")
    }

    func testContextReportsD9vkWhenVersionUsesDefaultRenderer() {
        let context = TelemetryEventContext(version: makeVersion(renderer: .d9vk))
        XCTAssertEqual(context.renderer, "d9vk")
    }

    func testContextReportsD9vkWhenVersionIsNil() {
        let context = TelemetryEventContext(version: nil)
        XCTAssertEqual(context.renderer, "d9vk")
    }
}
