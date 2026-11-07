import SwiftUI

/// One line of text that shows its end when it doesn't fit: while `isActive` (the focused card),
/// after a moment it scrolls to the end, rests there, goes back, and again — as tvOS scrolls a
/// focused title. Inactive, or text that fits, is the usual one line ending in "…". Nothing moves
/// with Reduce Motion on (Settings → Accessibility → Motion). Only the active line is measured.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color
    var isActive: Bool
    /// As `minimumScaleFactor`: the text shrinks this far before it counts as not fitting, and
    /// scrolls at that size.
    var minimumScaleFactor: CGFloat = 1
    /// Where text that fits sits; scrolling text starts at the leading edge.
    var alignment: Alignment = .leading

    static let startDelay: Double = 1.2
    static let pointsPerSecond: CGFloat = 45
    static let restAtEnds: Double = 1.6
    static let returnDuration: Double = 0.6
    static let edgeFade: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fullWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var scrolling = false
    @State private var offset: CGFloat = 0

    init(_ text: String, font: Font, color: Color, isActive: Bool, minimumScaleFactor: CGFloat = 1, alignment: Alignment = .leading) {
        self.text = text
        self.font = font
        self.color = color
        self.isActive = isActive
        self.minimumScaleFactor = minimumScaleFactor
        self.alignment = alignment
    }

    /// How far the text runs past its box at the size it scrolls at; 0 = it fits.
    static func overflow(fullWidth: CGFloat, boxWidth: CGFloat, scale: CGFloat) -> CGFloat {
        guard fullWidth > 0, boxWidth > 0 else { return 0 }
        return max(0, (fullWidth * scale - boxWidth).rounded(.up))
    }

    private var overflow: CGFloat {
        Self.overflow(fullWidth: fullWidth, boxWidth: boxWidth, scale: minimumScaleFactor)
    }

    private var moves: Bool {
        isActive && overflow > 0 && !reduceMotion
    }

    var body: some View {
        ZStack(alignment: scrolling ? .leading : alignment) {
            // The line's full height, so scrolling at a smaller size doesn't move what's around it.
            Text(" ").font(font).hidden()
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(minimumScaleFactor)
                .opacity(scrolling ? 0 : 1)
            // Already there while focused, so the first move animates instead of appearing.
            if isActive && overflow > 0 {
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .scaleEffect(minimumScaleFactor, anchor: .leading)
                    .offset(x: -offset)
                    .opacity(scrolling ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: scrolling ? .leading : alignment)
        .clipped()
        .mask(fadeMask)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            boxWidth = width
        }
        .background {
            if isActive { lineMeasure }
        }
        .task(id: MarqueeKey(text: text, moves: moves, overflow: overflow)) {
            await run()
        }
    }

    /// The whole line's width, never shown.
    private var lineMeasure: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                fullWidth = width
            }
            .frame(width: 0, alignment: .leading)
    }

    @ViewBuilder
    private var fadeMask: some View {
        if scrolling {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: offset > 0 ? Self.edgeFade : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.edgeFade)
            }
        } else {
            Rectangle()
        }
    }

    /// Back to the start at once, then (while it moves) to the end and back, until cancelled.
    private func run() async {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            offset = 0
            scrolling = false
        }
        guard moves else { return }
        guard await pause(Self.startDelay) else { return }
        withTransaction(reset) { scrolling = true }
        // Let it draw at the start before it moves.
        guard await pause(0.05) else { return }
        // A little past the end, so the last letter clears the fade.
        let distance = overflow + Self.edgeFade
        let duration = Double(distance / Self.pointsPerSecond)
        while !Task.isCancelled {
            withAnimation(.linear(duration: duration)) { offset = distance }
            guard await pause(duration + Self.restAtEnds) else { return }
            withAnimation(.easeInOut(duration: Self.returnDuration)) { offset = 0 }
            guard await pause(Self.returnDuration + Self.restAtEnds) else { return }
        }
    }

    /// false when cancelled (the card lost focus, the text changed).
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        return !Task.isCancelled
    }
}

private struct MarqueeKey: Hashable {
    let text: String
    let moves: Bool
    let overflow: CGFloat
}
