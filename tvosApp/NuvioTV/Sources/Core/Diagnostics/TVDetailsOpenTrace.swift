import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// TEST: where focus goes as Details opens (the first six seconds), and Details' moves to its
/// sections, in the test log.
enum TVDetailsOpenTrace {
    nonisolated(unsafe) private static var openedAt: CFTimeInterval = 0
    nonisolated(unsafe) private static var restGeneration = 0
    nonisolated(unsafe) private static weak var watchedScrollView: UIScrollView?
    nonisolated(unsafe) private static var offsetObservation: NSKeyValueObservation?
    nonisolated(unsafe) private static var lastLoggedOffset: CGFloat = .nan

    static func begin(_ id: String) {
        openedAt = CACurrentMediaTime()
        TestDiagnosticLog.ui("details open \(id)")
    }

    /// Logged within the first six seconds after Details opened.
    static func note(_ text: String) {
        let elapsed = CACurrentMediaTime() - openedAt
        guard openedAt > 0, elapsed < 6 else { return }
        TestDiagnosticLog.ui("details open +\(Int(elapsed * 1_000)) ms: \(text)")
    }

    /// Logged any time.
    static func move(_ text: String) {
        TestDiagnosticLog.ui("details: \(text)")
    }

    /// The scroll view Details moves: which one, on screen or not, its content's and its own
    /// height, where it is (where the move ends, and what is on screen now), whether it scrolls
    /// for focus, and whether the focused view is in it.
    static func scrollState(_ scrollView: UIScrollView?) -> String {
        guard let scrollView else { return "sv none" }
        let shown = scrollView.layer.presentation()?.bounds.origin.y ?? scrollView.contentOffset.y
        let inset = scrollView.adjustedContentInset
        return "sv " + shortID(scrollView)
            + (scrollView.window == nil ? " OFF screen" : " on screen")
            + " content=\(Int(scrollView.contentSize.height))"
            + " bounds=\(Int(scrollView.bounds.height))"
            + " inset=\(Int(inset.top))/\(Int(inset.bottom))"
            + " offset=\(Int(scrollView.contentOffset.y))"
            + " shown=\(Int(shown))"
            + " scroll \(scrollView.isScrollEnabled ? "ON" : "off")"
            + " focus in it: " + focusIsIn(scrollView)
    }

    /// The scroll view's state again once the move has had time to finish (the last move only).
    static func rest(after key: String, _ box: TVScrollViewBox) {
        restGeneration &+= 1
        let generation = restGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard generation == restGeneration else { return }
            move("rest after to \(key): " + scrollState(box.scrollView))
        }
    }

    /// Logs every change of the scroll view's offset (Details' own moves among them, each just
    /// after its line), to see whether anything else puts it back.
    static func watch(_ scrollView: UIScrollView?) {
        guard let scrollView, scrollView !== watchedScrollView else { return }
        watchedScrollView = scrollView
        lastLoggedOffset = scrollView.contentOffset.y
        move("watching sv \(shortID(scrollView))")
        offsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { scrollView, _ in
            MainActor.assumeIsolated {
                let y = scrollView.contentOffset.y
                guard lastLoggedOffset.isNaN || abs(y - lastLoggedOffset) >= 1 else { return }
                lastLoggedOffset = y
                move("offset of sv \(shortID(scrollView)) → \(Int(y))")
            }
        }
    }

    private static func shortID(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xFFFFF, radix: 16)
    }

    private static func focusIsIn(_ scrollView: UIScrollView) -> String {
        guard let window = scrollView.window ?? UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
            let item = window.windowScene?.focusSystem?.focusedItem
        else { return "no focus" }
        var environment: UIFocusEnvironment? = item
        while let current = environment, !(current is UIView) {
            environment = current.parentFocusEnvironment
        }
        guard let view = environment as? UIView else { return "?" }
        return view.isDescendant(of: scrollView) ? "yes" : "NO"
    }
}

/// TEST: logs Details' action focus, focused section and number of sections as they change.
struct TVDetailsOpenTraceModifier: ViewModifier {
    let action: String
    let section: String
    let sections: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: action) { old, new in
                TVDetailsOpenTrace.note("action focus \(old) → \(new)")
            }
            .onChange(of: section) { old, new in
                TVDetailsOpenTrace.note("section \(old) → \(new)")
            }
            .onChange(of: sections) { old, new in
                TVDetailsOpenTrace.note("sections \(old) → \(new)")
            }
    }
}
