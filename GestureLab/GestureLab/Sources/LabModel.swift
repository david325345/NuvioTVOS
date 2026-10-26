import SwiftUI
import UIKit
import GameController
import GestureCore

/// What the capture screen is for.
enum CaptureMode: Equatable {
    /// Try gestures; bound ones act on the pretend timeline.
    case test
    /// Do the gesture for this action; Play/Pause saves it.
    case record(LabAction)

    var title: String {
        switch self {
        case .test: return "Test gest"
        case let .record(action): return "Nahrát gesto: \(action.title)"
        }
    }
}

struct LogLine: Identifiable {
    enum Kind { case raw, gesture, info }
    let id: Int
    let text: String
    let kind: Kind
}

/// Everything Gesture Lab shows and keeps: settings, bindings, and the live
/// state of the capture screen.
@MainActor
final class LabModel: ObservableObject {
    // MARK: Saved
    @Published var tuning: Tuning {
        didSet {
            recognizer.tuning = tuning
            save(tuning, as: Keys.tuning)
        }
    }
    @Published private(set) var bindings: GestureBindings {
        didSet {
            save(bindings, as: Keys.bindings)
            updateDoublePolicy()
        }
    }

    // MARK: Capture screen
    @Published private(set) var mode: CaptureMode = .test
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var trail: [PadPoint] = []
    @Published private(set) var fingerPoint: PadPoint?
    @Published private(set) var pressed: Set<RemoteButton> = []
    @Published private(set) var headline = ""
    @Published private(set) var detail = ""
    @Published private(set) var timeline = LabTimeline()
    @Published private(set) var recordCandidate: RemoteGesture?
    @Published private(set) var controllerName = "nenalezen"
    @Published private(set) var sampleRate: Double = 0

    private let recognizer = GestureRecognizer()
    private var tickTimer: Timer?
    private var lastTick: TimeInterval?
    private var logCounter = 0
    private var sampleTimes: [TimeInterval] = []
    private var uikitTouchStart: TimeInterval?
    private var padTouchStart: TimeInterval?
    private weak var captureController: UIViewController?

    private enum Keys {
        static let tuning = "lab.tuning"
        static let bindings = "lab.bindings"
        /// Saved by older builds (digit drawing), no longer used.
        static let gone = ["lab.templates", "lab.builtInDigits"]
    }

    init() {
        tuning = Self.load(Tuning.self, Keys.tuning) ?? Tuning()
        bindings = Self.load(GestureBindings.self, Keys.bindings) ?? .defaults
        Keys.gone.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        recognizer.tuning = tuning
        updateDoublePolicy()
        startControllerMonitoring()
    }

    // MARK: - Settings

    func adjust(_ keyPath: WritableKeyPath<Tuning, Double>, by delta: Double, in range: ClosedRange<Double>) {
        let value = tuning[keyPath: keyPath] + delta
        tuning[keyPath: keyPath] = min(max((value * 1000).rounded() / 1000, range.lowerBound), range.upperBound)
    }

    func resetTuning() {
        tuning = Tuning()
    }

    func resetBindings() {
        bindings = .defaults
    }

    func unbind(_ action: LabAction) {
        bindings.unbind(action)
    }

    // MARK: - Capture screen

    func startCapture(_ mode: CaptureMode) {
        guard captureController == nil else { return }
        self.mode = mode
        recognizer.reset()
        log = []
        trail = []
        fingerPoint = nil
        pressed = []
        recordCandidate = nil
        timeline = LabTimeline()
        recognizer.tuning = tuning
        switch mode {
        case .test:
            headline = "Zkus gesto"
            detail = "Přiřazená gesta se projeví na časové ose dole. Menu = zpět."
        case let .record(action):
            headline = "Udělej gesto pro „\(action.title)“"
            detail = "Play/Pause = uložit, další gesto = zkusit znovu, Menu = zrušit."
        }
        updateDoublePolicy()

        let controller = CaptureViewController(model: self)
        controller.modalPresentationStyle = .fullScreen
        captureController = controller
        topViewController()?.present(controller, animated: true)

        lastTick = nil
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func exitCapture() {
        tickTimer?.invalidate()
        tickTimer = nil
        recognizer.reset()
        recognizer.tuning = tuning
        captureController?.dismiss(animated: true)
        captureController = nil
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: - Input

    func touchBegan(at time: TimeInterval) {
        uikitTouchStart = time
        trail = []
        fingerPoint = nil
        addLog("dotyk začal (UIKit)", .raw)
        feed(.touchBegan(time))
    }

    func touchEnded(at time: TimeInterval, cancelled: Bool = false) {
        uikitTouchStart = nil
        fingerPoint = nil
        if cancelled { addLog("dotyk zrušen systémem", .raw) }
        feed(.touchEnded(time))
    }

    /// The system's movement since the touch began, in points (y down, as UIKit gives it).
    func touchTranslated(dx: Double, dy: Double, at time: TimeInterval) {
        feed(.touchTranslation(time, dx: dx, dy: -dy))
    }

    func pressBegan(_ button: RemoteButton, at time: TimeInterval) {
        pressed.insert(button)
        addLog("stisk \(button.title) ↓", .raw)
        feed(.pressBegan(time, button))
    }

    func pressEnded(_ button: RemoteButton, at time: TimeInterval) {
        pressed.remove(button)
        addLog("stisk \(button.title) ↑", .raw)
        feed(.pressEnded(time, button))
    }

    private func padMoved(x: Double, y: Double) {
        guard captureController != nil else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let point = PadPoint(x: x, y: y)
        if x == 0, y == 0 {
            if padTouchStart != nil { addLog("plocha: prst pryč (0, 0)", .raw) }
            padTouchStart = nil
        } else {
            if padTouchStart == nil {
                padTouchStart = time
                addLog(String(format: "plocha: první bod (%.2f, %.2f)", x, y), .raw)
            }
            // The dot and its path only while the system reports a touch, and
            // not the first half position (y still 0) that draws a line from the middle.
            let halfPosition = (x == 0) != (y == 0)
            if uikitTouchStart != nil, !(trail.isEmpty && halfPosition) {
                fingerPoint = point
                trail.append(point)
                if trail.count > 240 { trail.removeFirst(trail.count - 240) }
            }
            sampleTimes.append(time)
            sampleTimes.removeAll { time - $0 > 1 }
            sampleRate = Double(sampleTimes.count)
        }
        feed(.touchMoved(time, point))
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastTick, mode == .test {
            timeline.advance(by: now - lastTick)
        }
        lastTick = now
        if let last = sampleTimes.last, now - last > 1 {
            sampleTimes = []
            sampleRate = 0
        }
        feed(.tick(now))
    }

    private func feed(_ event: InputEvent) {
        for output in recognizer.handle(event) {
            handle(output)
        }
    }

    // MARK: - Results

    private func handle(_ output: RecognizerOutput) {
        switch output {
        case let .gesture(gesture, inputTime, decidedTime):
            let delay = Int(((decidedTime - inputTime) * 1000).rounded())
            addLog("✓ \(gesture.title)" + (delay > 5 ? "  (+\(delay) ms čekání)" : ""), .gesture)
            handle(gesture, delay: delay)
        case let .touchSummary(summary):
            addLog(describe(summary), .raw)
            // Show the touch as it was read: without the lift slide.
            trail = summary.points
        }
    }

    private func handle(_ gesture: RemoteGesture, delay: Int) {
        let wait = delay > 5 ? " · čekání na druhé kliknutí \(delay) ms" : ""
        switch mode {
        case .test:
            if let action = bindings.action(for: gesture) {
                let result = timeline.perform(action)
                headline = "\(gesture.title) → \(action.title)"
                detail = result + wait
            } else {
                headline = gesture.title
                detail = "Nic nepřiřazeno" + wait
            }
        case let .record(action):
            if gesture == .click(.playPause, .single), let candidate = recordCandidate {
                let previous = bindings.bind(candidate, to: action)
                addLog("uloženo: \(candidate.title) → \(action.title)", .info)
                if let previous { addLog("„\(previous.title)“ gesto ztratila", .info) }
                exitCapture()
                return
            }
            recordCandidate = gesture
            headline = "Rozpoznáno: \(gesture.title)"
            if let other = bindings.conflict(for: gesture, action: action) {
                detail = "Pozor: teď patří akci „\(other.title)“, uložením ho ztratí. Play/Pause = uložit."
            } else {
                detail = "Play/Pause = uložit, další gesto = zkusit znovu, Menu = zrušit." + wait
            }
        }
    }

    private func describe(_ summary: TouchSummary) -> String {
        var text = "dotyk \(Int((summary.duration * 1000).rounded())) ms"
        if let movement = summary.movement {
            text += String(format: ", posun %.0f/%.0f", movement.dx, movement.dy)
        } else {
            text += ", bez posunu UIKit"
        }
        if let start = summary.padStart, let end = summary.padEnd {
            text += String(format: ", plocha %.2f,%.2f→%.2f,%.2f", start.x, start.y, end.x, end.y)
        }
        if summary.withClick { text += ", s klikem" }
        return text
    }

    private func addLog(_ text: String, _ kind: LogLine.Kind) {
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1000))
        logCounter += 1
        log.append(LogLine(id: logCounter, text: "\(stamp)  \(text)", kind: kind))
        if log.count > 14 { log.removeFirst(log.count - 14) }
    }

    // MARK: - Recognizer settings

    private func updateDoublePolicy() {
        if case .test = mode {
            let bindings = self.bindings
            recognizer.waitsForDouble = { bindings.waitsForDouble($0) }
        } else {
            // Recording: every double must be recognizable.
            recognizer.waitsForDouble = { _ in true }
        }
    }

    // MARK: - GameController

    private func startControllerMonitoring() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let controller = note.object as? GCController
            MainActor.assumeIsolated { self.attach(controller) }
        }
        GCController.controllers().forEach { attach($0) }
    }

    private func attach(_ controller: GCController?) {
        guard let controller, let pad = controller.microGamepad else { return }
        pad.reportsAbsoluteDpadValues = true
        pad.allowsRotation = false
        controllerName = [controller.vendorName, controller.productCategory]
            .compactMap { $0 }
            .joined(separator: " · ")
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            MainActor.assumeIsolated { self.padMoved(x: Double(x), y: Double(y)) }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.captureController != nil else { return }
                self.addLog("plocha: tlačítko A \(isPressed ? "↓" : "↑")", .raw)
            }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, isPressed in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.captureController != nil else { return }
                self.addLog("plocha: tlačítko X \(isPressed ? "↓" : "↑")", .raw)
            }
        }
    }

    // MARK: - Storage

    private func save<T: Encodable>(_ value: T, as key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
