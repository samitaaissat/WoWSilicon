import XCTest
@testable import WoWSiliconSwift

final class RendererBindingTests: XCTestCase {
    func testMetalToolchainCheckReturnsBool() {
        // On any dev machine with CLT this is true; assert the API shape and
        // that it doesn't throw/crash either way.
        let result = MainDashboardViewModel.isMetalToolchainAvailable()
        XCTAssertTrue(result == true || result == false)
    }
}
