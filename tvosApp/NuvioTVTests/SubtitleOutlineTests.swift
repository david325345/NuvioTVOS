import UIKit
import XCTest
import AetherEngine
@testable import NuvioTV

final class SubtitleOutlineTests: XCTestCase {
    private func appearance(outline: CGFloat = 3) -> SubtitleTextAppearance {
        SubtitleTextAppearance(
            fontSize: 55, bold: false, color: .white, opacity: 1,
            outlineColor: .black, outlineWidth: outline, kerning: 0, alignment: .center
        )
    }

    func testOutlineGrowsWithTheTextSize() {
        XCTAssertEqual(SubtitleAttributedText.outlineWidth(forTextSize: 55), 3)
        XCTAssertEqual(SubtitleAttributedText.outlineWidth(forTextSize: 125), 7)
        XCTAssertEqual(SubtitleAttributedText.outlineWidth(forTextSize: 24), 1.5)
    }

    func testRunsKeepTheirStyle() throws {
        let runs = [
            SubtitleTextRun(text: "Ahoj ", color: nil),
            SubtitleTextRun(text: "světe", color: SubtitleColor(r: 255, g: 0, b: 0), isBold: true, isItalic: true, isUnderlined: true),
        ]
        let text = SubtitleAttributedText.make(runs: runs, appearance: appearance())
        XCTAssertEqual(text.string, "Ahoj světe")

        let plainFont = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertFalse(plainFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(plainFont.pointSize, 55)

        let styled = 5
        let styledFont = try XCTUnwrap(text.attribute(.font, at: styled, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(styledFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(styledFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertNotNil(text.attribute(.underlineStyle, at: styled, effectiveRange: nil))
        let color = try XCTUnwrap(text.attribute(.foregroundColor, at: styled, effectiveRange: nil) as? UIColor)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(red, 1, accuracy: 0.01)
        XCTAssertEqual(green, 0, accuracy: 0.01)
    }

    func testOutlineIsStrokeOnlyInTheOutlineColor() throws {
        let text = SubtitleAttributedText.make(plain: "Pěkný den", appearance: appearance())
        let outline = try XCTUnwrap(SubtitleAttributedText.outline(of: text, appearance: appearance()))
        XCTAssertEqual(outline.string, text.string)
        // Twice the outline width (the fill covers the inner half), in percent of 55 pt.
        let stroke = try XCTUnwrap(outline.attribute(.strokeWidth, at: 0, effectiveRange: nil) as? CGFloat)
        XCTAssertEqual(stroke, 6 / 55 * 100, accuracy: 0.001)
        XCTAssertEqual(outline.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, UIColor.black)
        XCTAssertNil(SubtitleAttributedText.outline(of: text, appearance: appearance(outline: 0)))
    }

    func testSizeLeavesRoomForTheOutlineAndWraps() {
        let text = SubtitleAttributedText.make(plain: "Pěkný den, jak se máš?", appearance: appearance())
        let oneLine = OutlinedSubtitleLabel.fittingSize(of: text, padding: 4, maxWidth: nil)
        let wrapped = OutlinedSubtitleLabel.fittingSize(of: text, padding: 4, maxWidth: oneLine.width / 2)
        XCTAssertGreaterThan(oneLine.width, 8)
        XCTAssertGreaterThan(wrapped.height, oneLine.height)
        XCTAssertLessThanOrEqual(wrapped.width, oneLine.width / 2 + 1)
    }
}
