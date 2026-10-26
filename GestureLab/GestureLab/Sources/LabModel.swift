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
    /// Draw this digit; every drawing is saved as an own sample.
    case trainDigit(Int)

    var title: String {
        switch self {
        case .test: return "Test gest"
        case let .record(action): return "Nahrát gesto: \(action.title)"
        case let .trainDigit(digit): return "Vzor číslice \(digit)"
        }
    }
}

struct LogLine: Identifiable {
    enum Kind { case raw, gesture, info }
    let id: Int
    let text: String
    let kind: Kind
}

/// Everything Gesture Lab shows and keeps: settings, bindings, own digit
/// samples, and the live state of the capture screen.
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
    @Published private(set) var digitTemplates: [DigitTemplate] {
        didSet {
            save(digitTemplates, as: Keys.templates)
            rebuildDigits()
        }
    }
    @Published var useBuiltInDigits: Bool {
        didSet {
            UserDefaults.standard.set(useBuiltInDigits, forKey: Keys.builtInDigits)
            rebuildDigits()
        }
    }

    // MARK: Capture screen
    @Published private(set) var mode: CaptureMode = .test
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var trail: [PadPoint] = []
    @Published private(set) var fingerPoint: PadPoint?
    @Published private(set) var pressed: Set<RemoteButton> = []
    @Published private(set) var isDrawing = false
    @Published private(set) var liveStrokes: [[PadPoint]] = []
    @Published private(set) var lastDrawing: [[PadPoint]] = []
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
        static let templates = "lab.templates"
        static let builtInDigits = "lab.builtInDigits"
    }

    init() {
        tuning = Self.load(Tuning.self, Keys.tuning) ?? Tuning()
        bindings = Self.load(GestureBindings.self, Keys.bindings) ?? .defaults
        digitTemplates = Self.load([DigitTemplate].self, Keys.templates) ?? []
        useBuiltInDigits = UserDefaults.standard.object(forKey: Keys.builtInDigits) as? Bool ?? true
        recognizer.tuning = tuning
        rebuildDigits()
        updateDoublePolicy()
        startControllerMonitoring()
    }

    // MARK: - Settings

    func adjust(_ keyPath: WritableKeyPath<Tuning, Double>, by delta: Double, in range: ClosedRange<Double>) {
        let value = tuning[keyPath: keyPath] + delta
        tuning[keyPath: keyPath] = min(max((value * 1000).rounded() / 1000, range.lowerBound), range.upperBound)
    }

    func cycleDrawingMode() {
        let all = DrawingMode.allCases
        let index = all.firstIndex(of: tuning.drawingMode) ?? 0
        tuning.drawingMode = all[(index + 1) % all.count]
    }

    func resetTuning() {
        tuning = Tuning()
    }

    func toggleDigitMode() {
        let all = DigitMode.allCases
        let index = all.firstIndex(of: bindings.digitMode) ?? 0
        bindings.digitMode = all[(index + 1) % all.count]
    }

    func resetBindings() {
        bindings = .defaults
    }

    func unbind(_ action: LabAction) {
        bindings.unbind(action)
    }

    func sampleCount(for digit: Int) -> Int {
        digitTemplates.filter { $0.digit == digit }.count
    }

    func deleteSamples(for digit: Int? = nil) {
        if let digit {
            digitTemplates.removeAll { $0.digit == digit }
        } else {
            digitTemplates = []
        }
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
        liveStrokes = []
        lastDrawing = []
        isDrawing = false
        recordCandidate = nil
        timeline = LabTimeline()
        // Drawing samples must work even with drawing turned off in Tuning.
        var effective = tuning
        if case .trainDigit = mode, effective.drawingMode == .off {
            effective.drawingMode = .longPressThenDraw
        }
        recognizer.tuning = effective
        switch mode {
        case .test:
            headline = "Zkus gesto"
            detail = "Přiřazená gesta se projeví na časové ose dole. Menu = zpět."
            if tuning.drawingMode == .off {
                detail += " Kreslení číslic je vypnuté (Ladění)."
            }
        case let .record(action):
            headline = "Udělej gesto pro „\(action.title)“"
            detail = "Play/Pause = uložit, další gesto = zkusit znovu, Menu = zrušit."
        case let .trainDigit(digit):
            headline = "Nakresli \(digit)"
            detail = "Podrž střed, až naskočí „Kresli…“, pusť a nakresli \(digit). Po chvíli bez dotyku se uloží. Menu = zpět."
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
        lastDrawing = isDrawing ? lastDrawing : []
        addLog("dotyk začal (UIKit)", .raw)
        feed(.touchBegan(time))
    }

    func touchEnded(at time: TimeInterval, cancelled: Bool = false) {
        uikitTouchStart = nil
        fingerPoint = nil
        if cancelled { addLog("dotyk zrušen systémem", .raw) }
        if isDrawing { addLog("tah kresby hotov", .raw) }
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
        if isDrawing {
            liveStrokes = recognizer.drawingStrokes + [recognizer.currentStroke]
        }
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
        case .drawingStarted:
            isDrawing = true
            liveStrokes = []
            lastDrawing = []
            headline = "Kresli…"
            detail = tuning.drawingMode == .holdSelect
                ? "Drž střed a kresli, puštěním skončíš."
                : "Kresli, chvíle bez dotyku kreslení ukončí."
            addLog("kreslení začalo", .info)
        case let .drawingFinished(result):
            isDrawing = false
            liveStrokes = []
            lastDrawing = result.strokes
            addLog("kreslení skončilo: \(result.strokes.count) tah(y)", .info)
            handle(result)
        case .drawingCancelled:
            isDrawing = false
            liveStrokes = []
            headline = "Kreslení zrušeno"
            detail = "Nic nenakresleno."
            addLog("kreslení zrušeno", .info)
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
        case .trainDigit:
            headline = gesture.title
            detail = "Tady se kreslí číslice (\(tuning.drawingMode.title))."
        }
    }

    private func handle(_ result: DrawingResult) {
        let best = result.best.map { describe($0) } ?? "nic podobného"
        switch mode {
        case .test:
            if let digit = result.digit {
                let effect = timeline.jump(toDigit: digit, mode: bindings.digitMode)
                headline = "Číslice \(digit)"
                detail = "\(effect) · \(best)"
            } else {
                headline = "Nepoznáno"
                detail = "\(best) · hranice \(format(tuning.digitMinScore))"
            }
        case .record:
            headline = "Číslice se nepřiřazují"
            detail = "Co dělají, nastavíš v Přiřazení gest (kapitola / procenta)."
        case let .trainDigit(digit):
            digitTemplates.append(DigitTemplate(digit: digit, strokes: result.strokes))
            headline = "Vzor \(digit) uložen (\(sampleCount(for: digit)))"
            detail = "Před uložením: \(best)"
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

    private func describe(_ match: DigitMatch) -> String {
        var text = "nejblíž \(match.digit) (\(format(match.score)))"
        if let second = match.runnerUp, let score = match.runnerUpScore {
            text += ", pak \(second) (\(format(score)))"
        }
        return text
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
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
            // Recording and training: every double must be recognizable.
            recognizer.waitsForDouble = { _ in true }
        }
    }

    private func rebuildDigits() {
        recognizer.digits = DigitRecognizer(userTemplates: digitTemplates, includeDefaults: useBuiltInDigits)
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
