import XCTest
@testable import NuvioTV

/// Long titles scroll on the focused card only when they don't fit (`MarqueeText`).
final class MarqueeTextTests: XCTestCase {
    func testOnlyTextThatDoesNotFitScrolls() {
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 300, boxWidth: 200, scale: 1), 100)
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 180, boxWidth: 200, scale: 1), 0)
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 200.4, boxWidth: 200, scale: 1), 1)
        // Text that may shrink first: it fits at 82 %, so it doesn't scroll…
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 240, boxWidth: 200, scale: 0.82), 0)
        // …and longer text scrolls at the smaller size.
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 400, boxWidth: 200, scale: 0.82), 128)
        // Not measured yet.
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 0, boxWidth: 200, scale: 1), 0)
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 300, boxWidth: 0, scale: 1), 0)
    }
}
