import SwiftUI
import UIKit

/// A row of cards that tvOS doesn't scroll: Core Animation moves it so the card at `index` is
/// where the first card is at rest (under the row's title), as Home's rows. The move runs in the
/// render server, so it stays smooth while the main thread builds what focus brought.
///
/// `step`: from one card's start to the next one's. The cards draw past the row's edges, and
/// there is room after the last card for it to come to the start.
struct TVCAStrip<Content: View>: View {
    let index: Int
    let step: CGFloat
    var animated: Bool = true
    @ViewBuilder let content: () -> Content

    @State private var box = TVScrollViewBox()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(.trailing, UIScreen.main.bounds.width)
                .background {
                    TVScrollViewFinder(box: box)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
        }
        .scrollDisabled(true)
        .scrollClipDisabledIfAvailable()
        .onChange(of: index) { _, index in
            move(to: index, animated: animated)
        }
        .onAppear {
            moveOnceFound(to: index)
        }
    }

    @discardableResult
    private func move(to index: Int, animated: Bool) -> Bool {
        guard let scrollView = box.scrollView else { return false }
        TVScrollMove.move(
            scrollView,
            to: CGPoint(x: CGFloat(index) * step, y: scrollView.contentOffset.y),
            animated: animated
        )
        return true
    }

    /// Where the row was left (focus coming back to it), once SwiftUI has made its scroll view.
    private func moveOnceFound(to index: Int, attempt: Int = 0) {
        guard index > 0, !move(to: index, animated: false), attempt < 6 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            moveOnceFound(to: index, attempt: attempt + 1)
        }
    }
}

/// Stops the UIKit scroll view this sits in from scrolling for focus: tvOS still moves focus to
/// what is off screen in it, and the screen moves the scroll view there by Core Animation.
struct TVScrollLock: UIViewRepresentable {
    let locked: Bool

    final class LockView: UIView {
        var locked = false
        private weak var lockedScrollView: UIScrollView?
        private var scrollEnabledObservation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            // After SwiftUI's own update of the scroll view.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var current = self.superview
                while let candidate = current, !(candidate is UIScrollView) { current = candidate.superview }
                guard let scrollView = current as? UIScrollView else { return }
                if self.locked {
                    self.lock(scrollView)
                } else if let lockedScrollView = self.lockedScrollView {
                    self.scrollEnabledObservation = nil
                    self.lockedScrollView = nil
                    lockedScrollView.isScrollEnabled = true
                }
            }
        }

        private func lock(_ scrollView: UIScrollView) {
            scrollView.isScrollEnabled = false
            guard lockedScrollView !== scrollView else { return }
            lockedScrollView = scrollView
            // SwiftUI sets its scroll view scrolling again in some of its updates (Details'
            // content disabled and enabled again around the stream list), which needn't update
            // this view: tvOS then scrolled for focus as well, its scroll and the Core Animation
            // move added up, and Details went far past its ends. Turned off again at once.
            scrollEnabledObservation = scrollView.observe(\.isScrollEnabled, options: [.new]) { scrollView, change in
                guard change.newValue == true else { return }
                MainActor.assumeIsolated { scrollView.isScrollEnabled = false }
            }
        }
    }

    func makeUIView(context: Context) -> LockView {
        let view = LockView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.locked = locked
        return view
    }

    func updateUIView(_ uiView: LockView, context: Context) {
        uiView.locked = locked
        uiView.apply()
    }
}

/// A page's UIKit scroll view, and where each of its parts starts in its content, so the page
/// can move to a part by Core Animation (with `TVScrollLock`, tvOS doesn't scroll it).
final class TVScrollTops {
    let scrollBox = TVScrollViewBox()
    private(set) var tops: [String: CGFloat] = [:]

    /// `visibleMinY`: the part's top in the scroll view's own space (where it is on screen);
    /// with the scroll's offset, where it is in the content.
    func record(_ key: String, visibleMinY: CGFloat) {
        tops[key] = visibleMinY + (scrollBox.scrollView?.contentOffset.y ?? 0)
    }

    /// Moves the page so part `key` starts `margin` below the top of the screen, or to the very
    /// top (`toTop`, the page's first part).
    @discardableResult
    func move(to key: String, margin: CGFloat, toTop: Bool) -> Bool {
        guard let scrollView = scrollBox.scrollView else { return false }
        let inset = scrollView.adjustedContentInset
        let target: CGFloat
        if toTop {
            target = -inset.top
        } else {
            guard let top = tops[key] else { return false }
            target = top - margin - inset.top
        }
        // A scroll UIKit may be running (tvOS's for focus, were it ever on) stops where it is, so
        // it doesn't add up with the move.
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        let current = scrollView.contentOffset
        let maxY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        // Already there (or going there: the move sets where the scroll ends at once).
        guard abs(current.y - min(max(target, -inset.top), maxY)) >= 1 else { return true }
        TVScrollMove.move(scrollView, to: CGPoint(x: current.x, y: target), animated: true)
        return true
    }
}

/// Records where the view starts in `space` (the page's scroll view) for `TVScrollTops`.
struct TVScrollTopReader: ViewModifier {
    let key: String
    let tops: TVScrollTops
    let space: String

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(space)).minY
        } action: { minY in
            tops.record(key, visibleMinY: minY)
        }
    }
}

/// A page tvOS doesn't scroll (`TVScrollLock`) that brings the focused item on screen by Core
/// Animation, as far as tvOS's scroll for focus took it: not at all while the item is on screen
/// with `margin` to spare above and below it, else just far enough. The margin also keeps part
/// of the row beyond on screen, so a lazy grid or list has it built for focus to move to.
final class TVScrollReveal {
    let scrollBox = TVScrollViewBox()
    private var frames: [AnyHashable: CGRect] = [:]

    /// `visibleFrame`: the item's frame in the scroll view's own space (where it is on screen);
    /// with the scroll's offset, where it is in the content.
    func record(_ key: AnyHashable, visibleFrame: CGRect) {
        frames[key] = visibleFrame.offsetBy(dx: 0, dy: scrollBox.scrollView?.contentOffset.y ?? 0)
    }

    /// Brings item `key` on screen with `margin` above and below it (the top of an item taller
    /// than that). False while its place isn't known yet.
    @discardableResult
    func reveal(_ key: AnyHashable, margin: CGFloat) -> Bool {
        guard let scrollView = scrollBox.scrollView, let frame = frames[key] else { return false }
        let inset = scrollView.adjustedContentInset
        let top = scrollView.contentOffset.y + inset.top
        let bottom = scrollView.contentOffset.y + scrollView.bounds.height - inset.bottom
        if frame.minY - margin < top || frame.height + 2 * margin > bottom - top {
            move(scrollView, to: frame.minY - margin - inset.top)
        } else if frame.maxY + margin > bottom {
            move(scrollView, to: frame.maxY + margin - scrollView.bounds.height + inset.bottom)
        }
        return true
    }

    /// Moves so item `key` starts `margin` below the top. False while its place isn't known yet.
    @discardableResult
    func move(toTopOf key: AnyHashable, margin: CGFloat) -> Bool {
        guard let scrollView = scrollBox.scrollView, let frame = frames[key] else { return false }
        move(scrollView, to: frame.minY - margin - scrollView.adjustedContentInset.top)
        return true
    }

    /// Moves to the page's top. False while its scroll view isn't known yet.
    @discardableResult
    func moveToTop() -> Bool {
        guard let scrollView = scrollBox.scrollView else { return false }
        move(scrollView, to: -scrollView.adjustedContentInset.top)
        return true
    }

    private func move(_ scrollView: UIScrollView, to target: CGFloat) {
        let inset = scrollView.adjustedContentInset
        let maxY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let clamped = min(max(target, -inset.top), maxY)
        // A scroll UIKit may be running stops where it is, so it doesn't add up with the move.
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        guard abs(scrollView.contentOffset.y - clamped) >= 1 else { return }
        TVScrollMove.move(scrollView, to: CGPoint(x: scrollView.contentOffset.x, y: clamped), animated: true)
    }
}

/// Records where the view is in `space` (the page's scroll view) for `TVScrollReveal`.
struct TVScrollFrameReader: ViewModifier {
    let key: AnyHashable
    let reveal: TVScrollReveal
    let space: String

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(space))
        } action: { frame in
            reveal.record(key, visibleFrame: frame)
        }
    }
}

extension View {
    /// The page's scroll view, for `TVScrollReveal`, and its scrolling for focus off: put in the
    /// scroll view's content.
    func tvScrollRevealPage(_ reveal: TVScrollReveal) -> some View {
        background {
            TVScrollViewFinder(box: reveal.scrollBox)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            TVScrollLock(locked: true)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }

    /// Brings `key` on screen once `reveal` knows where it is (it may be laid out only just after
    /// focus went to it): tried again a few times.
    func tvReveal<Key: Hashable>(_ key: Key?, in reveal: TVScrollReveal, margin: CGFloat) -> some View {
        onChange(of: key) { _, key in
            guard let key else { return }
            TVScrollRevealRetry.reveal(AnyHashable(key), in: reveal, margin: margin, attempt: 0)
        }
    }
}

private enum TVScrollRevealRetry {
    static func reveal(_ key: AnyHashable, in reveal: TVScrollReveal, margin: CGFloat, attempt: Int) {
        guard !reveal.reveal(key, margin: margin), attempt < 6 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            Self.reveal(key, in: reveal, margin: margin, attempt: attempt + 1)
        }
    }
}

/// How much of the rows above and below a grid's focused card `TVScrollReveal` keeps on screen.
enum TVGridReveal {
    static let margin: CGFloat = 90
}
