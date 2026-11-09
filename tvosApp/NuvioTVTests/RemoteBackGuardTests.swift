import XCTest
@testable import NuvioTV

final class RemoteBackGuardTests: XCTestCase {
    func testBackIsSwallowedOnlyWhileNothingIsFocused() {
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: true, sinceLastSwallow: .infinity))
        XCTAssertFalse(BackGuardHostView.shouldSwallow(nothingFocused: false, sinceLastSwallow: .infinity))
    }

    func testABackRightAfterASwallowedOneGoesThrough() {
        XCTAssertFalse(BackGuardHostView.shouldSwallow(nothingFocused: true, sinceLastSwallow: 0.4))
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: true, sinceLastSwallow: 2))
    }
}
