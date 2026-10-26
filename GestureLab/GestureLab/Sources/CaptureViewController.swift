import SwiftUI
import UIKit
import GestureCore

/// The only focusable view on the capture screen, so every touch and press
/// of the remote lands here.
final class CaptureView: UIView {
    override var canBecomeFocused: Bool { true }
}

/// Full-screen test surface: UIKit takes the touches and presses, the
/// overlay on top (SwiftUI, not interactive) shows what happened. Menu leaves.
final class CaptureViewController: UIViewController {
    private let model: LabModel
    private let captureView = CaptureView()
    private var touchOrigin: CGPoint?

    init(model: LabModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        captureView.backgroundColor = .black
        view = captureView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let overlay = UIHostingController(rootView: CaptureOverlay(model: model))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(overlay)
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [captureView] }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    // MARK: Touches (the touch surface)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = touches.first?.location(in: view)
        model.touchBegan(at: touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    /// UIKit's movement is relative and filtered: swipes are measured with it.
    /// Absolute positions come from GameController.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        reportTranslation(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        reportTranslation(touches)
        touchOrigin = nil
        model.touchEnded(at: touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchOrigin = nil
        model.touchEnded(at: touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime, cancelled: true)
    }

    private func reportTranslation(_ touches: Set<UITouch>) {
        guard let touch = touches.first, let origin = touchOrigin else { return }
        let location = touch.location(in: view)
        model.touchTranslated(dx: Double(location.x - origin.x), dy: Double(location.y - origin.y),
                              at: touch.timestamp)
    }

    // MARK: Presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if press.type == .menu { continue }
            if let button = RemoteButton(pressType: press.type) {
                model.pressBegan(button, at: press.timestamp)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if press.type == .menu {
                model.exitCapture()
                continue
            }
            if let button = RemoteButton(pressType: press.type) {
                model.pressEnded(button, at: press.timestamp)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let button = RemoteButton(pressType: press.type) {
                model.pressEnded(button, at: press.timestamp)
            }
        }
    }
}

extension RemoteButton {
    init?(pressType: UIPress.PressType) {
        switch pressType {
        case .select: self = .select
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .playPause: self = .playPause
        default: return nil
        }
    }
}
