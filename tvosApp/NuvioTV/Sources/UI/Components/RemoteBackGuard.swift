import SwiftUI
import UIKit

/// Keeps a quick Back from sending the app to the Home screen.
///
/// Closing a panel or a native menu (subtitles, audio), leaving the player, or going back from
/// Details animates for a moment with nothing focused. A Back pressed then reaches no responder,
/// and tvOS takes it as "leave the app". Installed once for the whole app: a Back that comes
/// while nothing is focused is swallowed instead. If Back keeps coming with still nothing focused,
/// the next one goes through, so the app can never hold the user in; with something focused (Home
/// with its sidebar, any screen at rest) Back works as always.
struct RemoteBackGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> BackGuardHostView {
        BackGuardHostView()
    }

    func updateUIView(_ uiView: BackGuardHostView, context: Context) {}

    static func dismantleUIView(_ uiView: BackGuardHostView, coordinator: ()) {
        uiView.removeRecognizer()
    }
}

final class BackGuardHostView: UIView, UIGestureRecognizerDelegate {
    /// After a swallowed Back, a further one this soon with still nothing focused goes through.
    static let passAfterSwallowWithin: CFTimeInterval = 1.5

    private var tap: UITapGestureRecognizer?
    private weak var attachedWindow: UIWindow?
    private var lastSwallow: CFTimeInterval = -.infinity

    /// Swallow a Back while nothing is focused, unless the previous one was just swallowed.
    static func shouldSwallow(nothingFocused: Bool, sinceLastSwallow: CFTimeInterval) -> Bool {
        nothingFocused && sinceLastSwallow >= passAfterSwallowWithin
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizer()
        guard let window else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(swallowed(_:)))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        tap.allowedTouchTypes = []
        tap.delegate = self
        window.addGestureRecognizer(tap)
        self.tap = tap
        attachedWindow = window
    }

    func removeRecognizer() {
        if let attachedWindow, let tap {
            attachedWindow.removeGestureRecognizer(tap)
        }
        tap = nil
        attachedWindow = nil
    }

    @objc private func swallowed(_ recognizer: UITapGestureRecognizer) {}

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        guard press.type == .menu, let window = attachedWindow else { return false }
        let now = CACurrentMediaTime()
        let nothingFocused = window.windowScene?.focusSystem?.focusedItem == nil
        guard Self.shouldSwallow(nothingFocused: nothingFocused, sinceLastSwallow: now - lastSwallow) else {
            return false
        }
        lastSwallow = now
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        false
    }
}
