import SwiftUI
import UIKit
import AetherEngine

/// What a host-drawn subtitle line looks like (from `SubtitleStyle`).
struct SubtitleTextAppearance: Equatable {
    var fontSize: CGFloat
    var bold: Bool
    var color: UIColor
    var opacity: CGFloat
    var outlineColor: UIColor
    /// 0 for no outline.
    var outlineWidth: CGFloat
    var kerning: CGFloat
    var alignment: NSTextAlignment
}

/// Text subtitles (SRT, VTT, plain ASS fallback) as attributed strings, plus
/// the outline drawn behind them.
enum SubtitleAttributedText {
    /// How far the outline reaches past the glyphs: about 5.5 % of the font
    /// size (3 pt at the default 55 pt), never under 1.5 pt.
    static func outlineWidth(forTextSize size: CGFloat) -> CGFloat {
        max(1.5, (size * 0.055 * 2).rounded() / 2)
    }

    static func make(plain string: String, appearance: SubtitleTextAppearance) -> NSAttributedString {
        NSAttributedString(string: string, attributes: attributes(
            font: font(size: appearance.fontSize, bold: appearance.bold, italic: false, name: nil),
            color: appearance.color,
            appearance: appearance
        ))
    }

    /// Runs keep their own color, weight, slant, face and size (`<font size>`
    /// is a hint relative to 16, as the SwiftUI path read it).
    static func make(runs: [SubtitleTextRun], appearance: SubtitleTextAppearance) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in runs {
            let size = run.fontSize.map { appearance.fontSize * CGFloat($0) / 16 } ?? appearance.fontSize
            let color = run.color.map {
                UIColor(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
            } ?? appearance.color
            var attrs = attributes(
                font: font(size: size, bold: run.isBold || appearance.bold, italic: run.isItalic, name: run.fontName),
                color: color,
                appearance: appearance
            )
            if run.isUnderlined { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.isStruckThrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return result
    }

    /// The same text as stroke-only glyphs in the outline color. The stroke is
    /// centered on the glyph edge, so it is twice the outline width; the fill
    /// drawn on top covers the inner half.
    static func outline(of text: NSAttributedString, appearance: SubtitleTextAppearance) -> NSAttributedString? {
        guard appearance.outlineWidth > 0, text.length > 0 else { return nil }
        let outline = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: outline.length)
        outline.addAttributes([
            .foregroundColor: appearance.outlineColor,
            .strokeColor: appearance.outlineColor,
        ], range: full)
        outline.enumerateAttribute(.font, in: full) { value, range, _ in
            let pointSize = (value as? UIFont)?.pointSize ?? appearance.fontSize
            // Positive: stroke only, in percent of the font size.
            outline.addAttribute(.strokeWidth, value: appearance.outlineWidth * 2 / max(pointSize, 1) * 100, range: range)
        }
        return outline
    }

    private static func attributes(font: UIFont, color: UIColor, appearance: SubtitleTextAppearance) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = appearance.alignment
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font,
            .foregroundColor: color.withAlphaComponent(appearance.opacity),
            .kern: appearance.kerning,
            .paragraphStyle: paragraph,
        ]
    }

    static func font(size: CGFloat, bold: Bool, italic: Bool, name: String?) -> UIFont {
        let base = name.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard traits != base.fontDescriptor.symbolicTraits,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// A subtitle line with a real outline: the glyph outlines stroked with round
/// joins, the text filled on top. Replaces eight offset shadows, which built a
/// stepped, uneven outline (2 to 6 pt) on curves and diacritics.
struct OutlinedSubtitleText: UIViewRepresentable {
    let text: NSAttributedString
    let outline: NSAttributedString?
    let outlineWidth: CGFloat

    init(_ text: NSAttributedString, appearance: SubtitleTextAppearance) {
        self.text = text
        self.outline = SubtitleAttributedText.outline(of: text, appearance: appearance)
        self.outlineWidth = appearance.outlineWidth
    }

    func makeUIView(context: Context) -> OutlinedSubtitleLabel {
        let view = OutlinedSubtitleLabel()
        view.configure(text: text, outline: outline, outlineWidth: outlineWidth)
        return view
    }

    func updateUIView(_ view: OutlinedSubtitleLabel, context: Context) {
        view.configure(text: text, outline: outline, outlineWidth: outlineWidth)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: OutlinedSubtitleLabel, context: Context) -> CGSize? {
        uiView.fittingSize(maxWidth: proposal.width)
    }
}

final class OutlinedSubtitleLabel: UIView {
    private var text = NSAttributedString()
    private var outline: NSAttributedString?
    private var outlineWidth: CGFloat = 0
    private static let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    /// Room around the text for the outline (and antialiasing).
    var padding: CGFloat { outline == nil ? 1 : ceil(outlineWidth) + 1 }

    func configure(text: NSAttributedString, outline: NSAttributedString?, outlineWidth: CGFloat) {
        guard !text.isEqual(to: self.text) || outline != self.outline || outlineWidth != self.outlineWidth else { return }
        self.text = text
        self.outline = outline
        self.outlineWidth = outlineWidth
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    func fittingSize(maxWidth: CGFloat?) -> CGSize {
        Self.fittingSize(of: text, padding: padding, maxWidth: maxWidth)
    }

    static func fittingSize(of text: NSAttributedString, padding: CGFloat, maxWidth: CGFloat?) -> CGSize {
        let available = maxWidth.map { max(1, $0 - padding * 2) } ?? 100_000
        let used = text.boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: options,
            context: nil
        )
        return CGSize(width: ceil(used.width) + padding * 2, height: ceil(used.height) + padding * 2)
    }

    override func draw(_ rect: CGRect) {
        let textRect = bounds.insetBy(dx: padding, dy: padding)
        if let outline, let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setLineWidth(outlineWidth * 2)
            context.setTextDrawingMode(.stroke)
            outline.draw(with: textRect, options: Self.options, context: nil)
            context.restoreGState()
        }
        text.draw(with: textRect, options: Self.options, context: nil)
    }
}
