import Foundation

/// What the remote sent, with `ProcessInfo.systemUptime` times (the clock
/// UITouch and UIPress timestamps use).
public enum InputEvent: Equatable, Sendable {
    case touchBegan(TimeInterval)
    /// Absolute finger position from GameController.
    case touchMoved(TimeInterval, PadPoint)
    case touchEnded(TimeInterval)
    case pressBegan(TimeInterval, RemoteButton)
    case pressEnded(TimeInterval, RemoteButton)
    /// Sent regularly (every frame), so pending singles and long presses resolve.
    case tick(TimeInterval)
}

public struct DrawingResult: Equatable, Sendable {
    public let strokes: [[PadPoint]]
    /// The best match, whatever its score.
    public let best: DigitMatch?
    /// The digit, when the best match reaches `Tuning.digitMinScore`.
    public let digit: Int?
}

public enum RecognizerOutput: Equatable, Sendable {
    /// `inputTime` is when the deciding input happened (release, lift);
    /// `decidedTime - inputTime` is the delay the recognizer added.
    case gesture(Gesture, inputTime: TimeInterval, decidedTime: TimeInterval)
    case drawingStarted
    case drawingFinished(DrawingResult)
    case drawingCancelled
}

/// Turns raw remote input into gestures. One instance per test screen; feed
/// every event to `handle` and act on what it returns.
public final class GestureRecognizer {
    public var tuning: Tuning
    public var digits: DigitRecognizer
    /// Whether a single click or tap has to wait `doubleWindow` for a second
    /// one: true when its double is in use. Otherwise singles come at once.
    public var waitsForDouble: (Gesture) -> Bool

    public private(set) var isDrawing = false
    /// Strokes of the drawing in progress (finished ones, then the current one).
    public private(set) var drawingStrokes: [[PadPoint]] = []
    public private(set) var currentStroke: [PadPoint] = []

    // Touch
    private var touchActive = false
    private var touchStart: TimeInterval = 0
    private var touchSamples: [PadPoint] = []
    private var pathLength = 0.0
    private var turned = 0.0
    private var lastAngle: Double?
    private var pressDuringTouch = false
    private var lastTouchEnd: TimeInterval = -.infinity
    /// Positions this soon after a lift are the pad settling, not a new touch.
    static let liftSettleTime: TimeInterval = 0.08

    // Presses
    private var pressDown: [RemoteButton: TimeInterval] = [:]
    private var longHandled: Set<RemoteButton> = []
    private var pendingClick: (button: RemoteButton, time: TimeInterval)?
    private var pendingTap: (side: PadSide, time: TimeInterval)?

    // Drawing
    private enum DrawState: Equatable {
        case idle
        /// Long press done; waiting for the first stroke until `until` (nil while still held).
        case armed(until: TimeInterval?)
        /// Strokes coming in; ends `strokeGap` after the last one.
        case strokes(lastEnd: TimeInterval?)
        /// Hold-to-draw: ends when the centre is released.
        case holding
    }
    private var drawState: DrawState = .idle

    public init(tuning: Tuning = Tuning(), digits: DigitRecognizer = DigitRecognizer(),
                waitsForDouble: @escaping (Gesture) -> Bool = { _ in true }) {
        self.tuning = tuning
        self.digits = digits
        self.waitsForDouble = waitsForDouble
    }

    /// Drops everything in progress (leaving the screen).
    public func reset() {
        touchActive = false
        touchSamples = []
        pressDown = [:]
        longHandled = []
        pendingClick = nil
        pendingTap = nil
        drawState = .idle
        isDrawing = false
        drawingStrokes = []
        currentStroke = []
    }

    public func handle(_ event: InputEvent) -> [RecognizerOutput] {
        switch event {
        case let .touchBegan(time):
            // The pad's first positions may have started the touch already.
            return touchActive ? [] : beginTouch(at: time)
        case let .touchMoved(time, point):
            return move(to: point, at: time)
        case let .touchEnded(time):
            return endTouch(at: time)
        case let .pressBegan(time, button):
            pressDown[button] = time
            if touchActive { pressDuringTouch = true }
            return []
        case let .pressEnded(time, button):
            return endPress(button, at: time)
        case let .tick(time):
            return tick(at: time)
        }
    }

    // MARK: - Touch

    private func beginTouch(at time: TimeInterval) -> [RecognizerOutput] {
        touchActive = true
        touchStart = time
        touchSamples = []
        pathLength = 0
        turned = 0
        lastAngle = nil
        pressDuringTouch = !pressDown.isEmpty
        switch drawState {
        case .armed, .strokes:
            drawState = .strokes(lastEnd: nil)
            currentStroke = []
        case .holding:
            currentStroke = []
        case .idle:
            break
        }
        return []
    }

    private func move(to point: PadPoint, at time: TimeInterval) -> [RecognizerOutput] {
        // The pad reports exactly (0, 0) when the finger lifts.
        guard point.x != 0 || point.y != 0 else { return [] }
        var outputs: [RecognizerOutput] = []
        if !touchActive {
            guard time - lastTouchEnd >= Self.liftSettleTime else { return [] }
            outputs += beginTouch(at: time)
        }
        if let last = touchSamples.last { pathLength += last.distance(to: point) }
        touchSamples.append(point)

        let radius = (point.x * point.x + point.y * point.y).squareRoot()
        if radius >= tuning.circleMinRadius {
            let angle = atan2(point.y, point.x)
            if let lastAngle {
                var delta = angle - lastAngle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                turned += delta
            }
            lastAngle = angle
        } else {
            lastAngle = nil
        }

        if isDrawing, drawState != .idle {
            if case .armed = drawState { drawState = .strokes(lastEnd: nil) }
            currentStroke.append(point)
        }
        return outputs
    }

    private func endTouch(at time: TimeInterval) -> [RecognizerOutput] {
        guard touchActive else { return [] }
        touchActive = false
        lastTouchEnd = time
        let duration = time - touchStart

        if isDrawing {
            if !currentStroke.isEmpty {
                drawingStrokes.append(currentStroke)
                currentStroke = []
            }
            if case .strokes = drawState { drawState = .strokes(lastEnd: time) }
            return []
        }
        guard !pressDuringTouch, pressDown.isEmpty else { return [] }

        guard let first = touchSamples.first, let last = touchSamples.last else {
            // A touch too short for the pad to report a position: a tap, side unknown.
            return duration <= tuning.tapMaxDuration ? tap(.center, at: time) : []
        }

        if abs(turned) >= tuning.circleDegrees * .pi / 180 {
            return [.gesture(.circle(clockwise: turned < 0), inputTime: time, decidedTime: time)]
        }

        let dx = last.x - first.x, dy = last.y - first.y
        let major = max(abs(dx), abs(dy)), minor = min(abs(dx), abs(dy))
        if major >= tuning.swipeMin, duration <= tuning.swipeMaxDuration, major >= minor * 1.5 {
            let direction: SwipeDirection = abs(dx) >= abs(dy)
                ? (dx > 0 ? .right : .left)
                : (dy > 0 ? .up : .down)
            return [.gesture(.swipe(direction, long: major >= tuning.swipeLong), inputTime: time, decidedTime: time)]
        }

        if duration <= tuning.tapMaxDuration, pathLength <= tuning.tapMaxMovement {
            let side: PadSide = first.x < -tuning.sideThreshold ? .left
                : (first.x > tuning.sideThreshold ? .right : .center)
            return tap(side, at: time)
        }
        return []
    }

    private func tap(_ side: PadSide, at time: TimeInterval) -> [RecognizerOutput] {
        var outputs: [RecognizerOutput] = []
        if let pending = pendingTap {
            if pending.side == side, time - pending.time <= tuning.doubleWindow {
                pendingTap = nil
                return [.gesture(.tap(side, double: true), inputTime: time, decidedTime: time)]
            }
            outputs.append(.gesture(.tap(pending.side, double: false), inputTime: pending.time, decidedTime: time))
            pendingTap = nil
        }
        let single = Gesture.tap(side, double: false)
        if let double = single.doubled, waitsForDouble(double) {
            pendingTap = (side, time)
        } else {
            outputs.append(.gesture(single, inputTime: time, decidedTime: time))
        }
        return outputs
    }

    // MARK: - Presses

    private func endPress(_ button: RemoteButton, at time: TimeInterval) -> [RecognizerOutput] {
        guard pressDown.removeValue(forKey: button) != nil else { return [] }
        if longHandled.remove(button) != nil {
            if button == .select {
                switch drawState {
                case .holding:
                    return finishDrawing()
                case .armed(until: .none):
                    drawState = .armed(until: time + tuning.drawArmWindow)
                default:
                    break
                }
            }
            return []
        }
        // Clicks don't count while a drawing is under way.
        guard !isDrawing else { return [] }

        var outputs: [RecognizerOutput] = []
        if let pending = pendingClick {
            if pending.button == button, time - pending.time <= tuning.doubleWindow {
                pendingClick = nil
                return [.gesture(.click(button, .double), inputTime: time, decidedTime: time)]
            }
            outputs.append(.gesture(.click(pending.button, .single), inputTime: pending.time, decidedTime: time))
            pendingClick = nil
        }
        let single = Gesture.click(button, .single)
        if let double = single.doubled, waitsForDouble(double) {
            pendingClick = (button, time)
        } else {
            outputs.append(.gesture(single, inputTime: time, decidedTime: time))
        }
        return outputs
    }

    // MARK: - Time

    private func tick(at time: TimeInterval) -> [RecognizerOutput] {
        var outputs: [RecognizerOutput] = []

        for (button, down) in pressDown where !longHandled.contains(button) && time - down >= tuning.longPress {
            longHandled.insert(button)
            if button == .select, tuning.drawingMode != .off, !isDrawing {
                isDrawing = true
                drawingStrokes = []
                currentStroke = []
                drawState = tuning.drawingMode == .holdSelect ? .holding : .armed(until: nil)
                outputs.append(.drawingStarted)
            } else if !isDrawing {
                outputs.append(.gesture(.click(button, .long), inputTime: down + tuning.longPress, decidedTime: time))
            }
        }

        if let pending = pendingClick, time - pending.time > tuning.doubleWindow {
            pendingClick = nil
            outputs.append(.gesture(.click(pending.button, .single), inputTime: pending.time, decidedTime: time))
        }
        if let pending = pendingTap, time - pending.time > tuning.doubleWindow {
            pendingTap = nil
            outputs.append(.gesture(.tap(pending.side, double: false), inputTime: pending.time, decidedTime: time))
        }

        switch drawState {
        case let .armed(until?) where time > until:
            outputs += cancelDrawing()
        case let .strokes(lastEnd?) where !touchActive && time - lastEnd >= tuning.strokeGap:
            outputs += finishDrawing()
        default:
            break
        }
        return outputs
    }

    // MARK: - Drawing

    private func finishDrawing() -> [RecognizerOutput] {
        if !currentStroke.isEmpty {
            drawingStrokes.append(currentStroke)
            currentStroke = []
        }
        let strokes = drawingStrokes.filter { $0.count >= 2 }
        isDrawing = false
        drawState = .idle
        drawingStrokes = []
        guard !strokes.isEmpty else { return [.drawingCancelled] }
        let best = digits.recognize(strokes)
        let digit = best.flatMap { $0.score >= tuning.digitMinScore ? $0.digit : nil }
        return [.drawingFinished(DrawingResult(strokes: strokes, best: best, digit: digit))]
    }

    private func cancelDrawing() -> [RecognizerOutput] {
        isDrawing = false
        drawState = .idle
        drawingStrokes = []
        currentStroke = []
        return [.drawingCancelled]
    }
}
