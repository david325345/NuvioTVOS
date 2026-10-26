import Foundation

/// What the remote sent, with `ProcessInfo.systemUptime` times (the clock
/// UITouch and UIPress timestamps use).
public enum InputEvent: Equatable, Sendable {
    /// The system (UIKit) says a finger is on the touch surface. Only this
    /// starts a touch; pad positions alone never do.
    case touchBegan(TimeInterval)
    /// Absolute finger position from GameController.
    case touchMoved(TimeInterval, PadPoint)
    /// The system's own movement since the touch began, in points, y up.
    /// Swipes and taps are measured with it: it has none of the pad's jumps.
    case touchTranslation(TimeInterval, dx: Double, dy: Double)
    case touchEnded(TimeInterval)
    case pressBegan(TimeInterval, RemoteButton)
    case pressEnded(TimeInterval, RemoteButton)
    /// Sent regularly (every frame), so pending decisions resolve.
    case tick(TimeInterval)
}

public struct DrawingResult: Equatable, Sendable {
    public let strokes: [[PadPoint]]
    /// The best match, whatever its score.
    public let best: DigitMatch?
    /// The digit, when the best match reaches `Tuning.digitMinScore`.
    public let digit: Int?
}

/// The system's movement of a touch, in points, y up.
public struct TouchMovement: Equatable, Sendable {
    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// How a touch went, for the log.
public struct TouchSummary: Equatable, Sendable {
    public let duration: TimeInterval
    /// Nil when the system reported no movement at all.
    public let movement: TouchMovement?
    /// Cleaned pad positions: first and last.
    public let padStart: PadPoint?
    public let padEnd: PadPoint?
    /// A click came with the touch, so it is no swipe or tap.
    public let withClick: Bool
}

public enum RecognizerOutput: Equatable, Sendable {
    /// `inputTime` is when the deciding input happened (release, lift);
    /// `decidedTime - inputTime` is the delay the recognizer added.
    case gesture(RemoteGesture, inputTime: TimeInterval, decidedTime: TimeInterval)
    case touchSummary(TouchSummary)
    case drawingStarted
    case drawingFinished(DrawingResult)
    case drawingCancelled
}

/// Turns raw remote input into gestures. One instance per test screen; feed
/// every event to `handle` and act on what it returns.
///
/// What the Siri Remote does that this has to cope with (seen on a device):
/// the first pad position of a touch has y exactly 0 (x arrives first); when
/// the finger lifts, positions slide towards the middle and (0, 0) may come
/// before the touch ends; a click on the edge makes the position jump to the
/// edge, and the system may end the touch around the click.
public final class GestureRecognizer {
    public var tuning: Tuning
    public var digits: DigitRecognizer
    /// Whether a single click or tap has to wait `doubleWindow` for a second
    /// one: true when its double is in use. Otherwise singles come at once.
    public var waitsForDouble: (RemoteGesture) -> Bool

    public private(set) var isDrawing = false
    /// Strokes of the drawing in progress (finished ones, then the current one).
    public private(set) var drawingStrokes: [[PadPoint]] = []
    public private(set) var currentStroke: [PadPoint] = []

    // Touch
    private struct Sample {
        let time: TimeInterval
        let point: PadPoint
    }
    private var touchActive = false
    private var touchStart: TimeInterval = 0
    private var samples: [Sample] = []
    /// The pad reported (0, 0): later positions of this touch are noise.
    private var padLiftTime: TimeInterval?
    private var movement: TouchMovement?
    /// When the current drawing stroke started collecting positions.
    private var strokeStart: TimeInterval?
    private var pressDuringTouch = false
    private var lastPressEvent: TimeInterval = -.infinity

    /// A finished touch waiting `clickGuard` in case a click turns up.
    private enum TouchKind {
        case swipe(SwipeDirection, long: Bool)
        case tap(PadSide)
        case circle(clockwise: Bool)
    }
    private var pendingTouch: (kind: TouchKind, start: TimeInterval, end: TimeInterval)?

    // Presses
    private var pressDown: [RemoteButton: TimeInterval] = [:]
    private var longHandled: Set<RemoteButton> = []
    /// A single click waiting for a possible second one; `time` is its release.
    private var pendingClick: (button: RemoteButton, time: TimeInterval)?
    /// A single tap waiting for a possible second one; `time` is its lift.
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
                waitsForDouble: @escaping (RemoteGesture) -> Bool = { _ in true }) {
        self.tuning = tuning
        self.digits = digits
        self.waitsForDouble = waitsForDouble
    }

    /// Drops everything in progress (leaving the screen).
    public func reset() {
        touchActive = false
        samples = []
        padLiftTime = nil
        movement = nil
        pendingTouch = nil
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
            return touchActive ? [] : beginTouch(at: time)
        case let .touchMoved(time, point):
            return move(to: point, at: time)
        case let .touchTranslation(_, dx, dy):
            if touchActive { movement = TouchMovement(dx: dx, dy: dy) }
            return []
        case let .touchEnded(time):
            return endTouch(at: time)
        case let .pressBegan(time, button):
            pressDown[button] = time
            lastPressEvent = time
            if touchActive { pressDuringTouch = true }
            // A click right after a touch: that touch was part of the click.
            if pendingTouch != nil { pendingTouch = nil }
            return []
        case let .pressEnded(time, button):
            lastPressEvent = time
            return endPress(button, at: time)
        case let .tick(time):
            return tick(at: time)
        }
    }

    // MARK: - Touch

    private func beginTouch(at time: TimeInterval) -> [RecognizerOutput] {
        touchActive = true
        touchStart = time
        samples = []
        padLiftTime = nil
        movement = nil
        pressDuringTouch = !pressDown.isEmpty
        switch drawState {
        case .armed, .strokes:
            drawState = .strokes(lastEnd: nil)
            currentStroke = []
            strokeStart = time
        case .holding:
            currentStroke = []
            strokeStart = time
        case .idle:
            strokeStart = nil
        }
        return []
    }

    private func move(to point: PadPoint, at time: TimeInterval) -> [RecognizerOutput] {
        guard touchActive, padLiftTime == nil else { return [] }
        if point.x == 0, point.y == 0 {
            padLiftTime = time
            return []
        }
        // The first position has only x: skip it until y arrives too.
        if samples.isEmpty, point.x == 0 || point.y == 0 { return [] }
        samples.append(Sample(time: time, point: point))
        if isDrawing, drawState != .idle {
            if case .armed = drawState { drawState = .strokes(lastEnd: nil) }
            if strokeStart == nil { strokeStart = time }
            currentStroke.append(point)
        }
        return []
    }

    /// Positions of the touch without the lift slide, from `from` on.
    private func cleanedPoints(liftAt lift: TimeInterval, from: TimeInterval = -.infinity) -> [PadPoint] {
        let cutoff = min(lift, padLiftTime ?? lift) - tuning.liftTrim
        let range = samples.filter { $0.time >= from }
        let kept = range.filter { $0.time <= cutoff }.map(\.point)
        // A very short touch may have nothing left: keep its first position.
        return kept.isEmpty ? Array(range.prefix(1).map(\.point)) : kept
    }

    private func endTouch(at time: TimeInterval) -> [RecognizerOutput] {
        guard touchActive else { return [] }
        touchActive = false
        let duration = time - touchStart
        let points = cleanedPoints(liftAt: time)

        if isDrawing {
            if let strokeStart {
                let stroke = cleanedPoints(liftAt: time, from: strokeStart)
                if stroke.count >= 2 { drawingStrokes.append(stroke) }
            }
            currentStroke = []
            strokeStart = nil
            if case .strokes = drawState { drawState = .strokes(lastEnd: time) }
            return []
        }

        let withClick = pressDuringTouch || !pressDown.isEmpty || touchStart - lastPressEvent < tuning.clickGuard
        var outputs: [RecognizerOutput] = [.touchSummary(TouchSummary(
            duration: duration, movement: movement,
            padStart: points.first, padEnd: points.last, withClick: withClick))]
        guard !withClick, let kind = classify(duration: duration, points: points) else { return outputs }
        // A quick second touch: the first one goes out now.
        if let previous = pendingTouch {
            outputs += emitTouch(previous.kind, start: previous.start, end: previous.end, at: time)
        }
        pendingTouch = (kind, touchStart, time)
        return outputs
    }

    private func classify(duration: TimeInterval, points: [PadPoint]) -> TouchKind? {
        if let clockwise = circle(points) { return .circle(clockwise: clockwise) }

        let moved = movement ?? padMovement(points)
        let dx = moved.dx, dy = moved.dy
        let major = max(abs(dx), abs(dy)), minor = min(abs(dx), abs(dy))
        if major >= tuning.swipeMinPoints, duration <= tuning.swipeMaxDuration, major >= minor * 1.5 {
            let direction: SwipeDirection = abs(dx) >= abs(dy)
                ? (dx > 0 ? .right : .left)
                : (dy > 0 ? .up : .down)
            return .swipe(direction, long: major >= tuning.swipeLongPoints)
        }
        if duration <= tuning.tapMaxDuration, major <= tuning.tapMaxMovePoints {
            return .tap(side(of: points))
        }
        return nil
    }

    /// Without any system movement: the pad's own, at a rough 500 points per pad unit.
    private func padMovement(_ points: [PadPoint]) -> TouchMovement {
        guard let first = points.first, let last = points.last else { return TouchMovement(dx: 0, dy: 0) }
        return TouchMovement(dx: (last.x - first.x) * 500, dy: (last.y - first.y) * 500)
    }

    /// The edge nearest to where the finger rested, or the middle when it
    /// stayed within `sideThreshold` of it both ways.
    static func side(of points: [PadPoint], threshold: Double) -> PadSide {
        guard !points.isEmpty else { return .center }
        let xs = points.map(\.x).sorted(), ys = points.map(\.y).sorted()
        let x = xs[xs.count / 2], y = ys[ys.count / 2]
        guard max(abs(x), abs(y)) > threshold else { return .center }
        if abs(y) > abs(x) { return y > 0 ? .top : .bottom }
        return x < 0 ? .left : .right
    }

    private func side(of points: [PadPoint]) -> PadSide {
        Self.side(of: points, threshold: tuning.sideThreshold)
    }

    /// Clockwise or not, when the finger went far enough round the middle.
    private func circle(_ points: [PadPoint]) -> Bool? {
        var turned = 0.0
        var lastAngle: Double?
        for point in points {
            let radius = (point.x * point.x + point.y * point.y).squareRoot()
            guard radius >= tuning.circleMinRadius else {
                lastAngle = nil
                continue
            }
            let angle = atan2(point.y, point.x)
            if let lastAngle {
                var delta = angle - lastAngle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                turned += delta
            }
            lastAngle = angle
        }
        guard abs(turned) >= tuning.circleDegrees * .pi / 180 else { return nil }
        return turned < 0
    }

    private func emitTouch(_ kind: TouchKind, start: TimeInterval, end: TimeInterval, at time: TimeInterval) -> [RecognizerOutput] {
        switch kind {
        case let .swipe(direction, long):
            return [.gesture(.swipe(direction, long: long), inputTime: end, decidedTime: time)]
        case let .circle(clockwise):
            return [.gesture(.circle(clockwise: clockwise), inputTime: end, decidedTime: time)]
        case let .tap(side):
            return tap(side, start: start, end: end, at: time)
        }
    }

    private func tap(_ side: PadSide, start: TimeInterval, end: TimeInterval, at time: TimeInterval) -> [RecognizerOutput] {
        var outputs: [RecognizerOutput] = []
        if let pending = pendingTap {
            if pending.side == side, start - pending.time <= tuning.doubleWindow {
                pendingTap = nil
                return [.gesture(.tap(side, double: true), inputTime: end, decidedTime: time)]
            }
            outputs.append(.gesture(.tap(pending.side, double: false), inputTime: pending.time, decidedTime: time))
            pendingTap = nil
        }
        let single = RemoteGesture.tap(side, double: false)
        if let double = single.doubled, waitsForDouble(double) {
            pendingTap = (side, end)
        } else {
            outputs.append(.gesture(single, inputTime: end, decidedTime: time))
        }
        return outputs
    }

    // MARK: - Presses

    private func endPress(_ button: RemoteButton, at time: TimeInterval) -> [RecognizerOutput] {
        guard let down = pressDown.removeValue(forKey: button) else { return [] }
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
            // Double: the second press began soon after the first was released.
            if pending.button == button, down - pending.time <= tuning.doubleWindow {
                pendingClick = nil
                return [.gesture(.click(button, .double), inputTime: time, decidedTime: time)]
            }
            outputs.append(.gesture(.click(pending.button, .single), inputTime: pending.time, decidedTime: time))
            pendingClick = nil
        }
        let single = RemoteGesture.click(button, .single)
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
                strokeStart = touchActive ? time : nil
                pendingClick = nil
                drawState = tuning.drawingMode == .holdSelect ? .holding : .armed(until: nil)
                outputs.append(.drawingStarted)
            } else if !isDrawing {
                outputs.append(.gesture(.click(button, .long), inputTime: down + tuning.longPress, decidedTime: time))
            }
        }

        if let pending = pendingTouch, time - pending.end >= tuning.clickGuard {
            pendingTouch = nil
            outputs += emitTouch(pending.kind, start: pending.start, end: pending.end, at: time)
        }

        // A single goes out once no second one can come: not while the same
        // button is down again (or a touch is under way) inside the window.
        if let pending = pendingClick, time - pending.time > tuning.doubleWindow {
            let secondUnderWay = pressDown[pending.button].map { $0 - pending.time <= tuning.doubleWindow } ?? false
            if !secondUnderWay {
                pendingClick = nil
                outputs.append(.gesture(.click(pending.button, .single), inputTime: pending.time, decidedTime: time))
            }
        }
        if let pending = pendingTap, time - pending.time > tuning.doubleWindow {
            let secondUnderWay = (touchActive && touchStart - pending.time <= tuning.doubleWindow)
                || (pendingTouch.map { $0.start - pending.time <= tuning.doubleWindow } ?? false)
            if !secondUnderWay {
                pendingTap = nil
                outputs.append(.gesture(.tap(pending.side, double: false), inputTime: pending.time, decidedTime: time))
            }
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
        // Hold-to-draw ends with the finger still down: the stroke so far counts.
        if currentStroke.count >= 2 { drawingStrokes.append(currentStroke) }
        currentStroke = []
        strokeStart = nil
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
        strokeStart = nil
        isDrawing = false
        drawState = .idle
        drawingStrokes = []
        currentStroke = []
        return [.drawingCancelled]
    }
}
