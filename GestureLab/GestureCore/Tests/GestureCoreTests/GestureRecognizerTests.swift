import XCTest
@testable import GestureCore

final class GestureRecognizerTests: XCTestCase {
    private func gestures(_ outputs: [RecognizerOutput]) -> [Gesture] {
        outputs.compactMap {
            if case let .gesture(gesture, _, _) = $0 { return gesture }
            return nil
        }
    }

    private func run(_ recognizer: GestureRecognizer, _ events: [InputEvent]) -> [RecognizerOutput] {
        events.flatMap { recognizer.handle($0) }
    }

    /// A finger moving in a straight line from `from` to `to`.
    private func stroke(from: PadPoint, to: PadPoint, start: TimeInterval, duration: TimeInterval,
                        steps: Int = 10) -> [InputEvent] {
        var events: [InputEvent] = [.touchBegan(start)]
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            events.append(.touchMoved(start + duration * t,
                                      PadPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
        }
        events.append(.touchEnded(start + duration))
        return events
    }

    func testSingleClickWaitsOnlyWhenTheDoubleIsUsed() {
        let waiting = GestureRecognizer(waitsForDouble: { _ in true })
        XCTAssertTrue(run(waiting, [.pressBegan(0, .right), .pressEnded(0.1, .right), .tick(0.2)]).isEmpty)
        let late = run(waiting, [.tick(0.45)])
        XCTAssertEqual(gestures(late), [.click(.right, .single)])
        if case let .gesture(_, input, decided) = late[0] {
            XCTAssertEqual(input, 0.1)
            XCTAssertEqual(decided, 0.45)
        }

        let immediate = GestureRecognizer(waitsForDouble: { _ in false })
        XCTAssertEqual(gestures(run(immediate, [.pressBegan(0, .right), .pressEnded(0.1, .right)])),
                       [.click(.right, .single)])
    }

    func testDoubleClick() {
        let recognizer = GestureRecognizer()
        let outputs = run(recognizer, [
            .pressBegan(0, .right), .pressEnded(0.08, .right), .tick(0.15),
            .pressBegan(0.2, .right), .pressEnded(0.28, .right), .tick(0.7),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.right, .double)])
    }

    func testTwoClicksTooFarApartAreTwoSingles() {
        let recognizer = GestureRecognizer()
        let outputs = run(recognizer, [
            .pressBegan(0, .left), .pressEnded(0.1, .left), .tick(0.5),
            .pressBegan(0.6, .left), .pressEnded(0.7, .left), .tick(1.2),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.left, .single), .click(.left, .single)])
    }

    func testLongPressFiresWhileHeldAndNotAgainOnRelease() {
        var tuning = Tuning()
        tuning.drawingMode = .off
        let recognizer = GestureRecognizer(tuning: tuning)
        XCTAssertTrue(run(recognizer, [.pressBegan(0, .up), .tick(0.3)]).isEmpty)
        XCTAssertEqual(gestures(run(recognizer, [.tick(0.55)])), [.click(.up, .long)])
        XCTAssertTrue(run(recognizer, [.pressEnded(1.0, .up), .tick(1.5)]).isEmpty)
    }

    func testSwipes() {
        let recognizer = GestureRecognizer()
        let short = run(recognizer, stroke(from: PadPoint(x: -0.4, y: 0), to: PadPoint(x: 0.4, y: 0.05),
                                           start: 0, duration: 0.2))
        XCTAssertEqual(gestures(short), [.swipe(.right, long: false)])
        let long = run(recognizer, stroke(from: PadPoint(x: 0.8, y: 0.1), to: PadPoint(x: -0.7, y: 0),
                                          start: 1, duration: 0.3))
        XCTAssertEqual(gestures(long), [.swipe(.left, long: true)])
        let down = run(recognizer, stroke(from: PadPoint(x: 0, y: 0.5), to: PadPoint(x: 0.1, y: -0.4),
                                          start: 2, duration: 0.25))
        XCTAssertEqual(gestures(down), [.swipe(.down, long: false)])
    }

    func testSlowOrDiagonalMovesAreNoSwipe() {
        let recognizer = GestureRecognizer()
        XCTAssertTrue(gestures(run(recognizer, stroke(from: PadPoint(x: -0.5, y: 0), to: PadPoint(x: 0.5, y: 0),
                                                      start: 0, duration: 2))).isEmpty)
        XCTAssertTrue(gestures(run(recognizer, stroke(from: PadPoint(x: -0.5, y: -0.5), to: PadPoint(x: 0.4, y: 0.4),
                                                      start: 3, duration: 0.2))).isEmpty)
    }

    func testTouchWithAClickIsNoSwipeOrTap() {
        let recognizer = GestureRecognizer(waitsForDouble: { _ in false })
        var events: [InputEvent] = [.touchBegan(0), .touchMoved(0.01, PadPoint(x: 0.6, y: 0)),
                                    .pressBegan(0.02, .right), .pressEnded(0.1, .right)]
        events += [.touchMoved(0.12, PadPoint(x: 0.6, y: 0)), .touchEnded(0.15)]
        XCTAssertEqual(gestures(run(recognizer, events)), [.click(.right, .single)])
    }

    func testLightTapsBySideAndDoubleTap() {
        let recognizer = GestureRecognizer()
        let right = run(recognizer, [.touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.7, y: 0.1)),
                                     .touchEnded(0.1), .tick(0.6)])
        XCTAssertEqual(gestures(right), [.tap(.right, double: false)])

        let double = run(recognizer, [
            .touchBegan(1), .touchMoved(1.02, PadPoint(x: -0.6, y: 0)), .touchEnded(1.1),
            .touchBegan(1.25), .touchMoved(1.27, PadPoint(x: -0.65, y: 0.05)), .touchEnded(1.33), .tick(1.8),
        ])
        XCTAssertEqual(gestures(double), [.tap(.left, double: true)])
    }

    func testPositionsRightAfterALiftDontStartATouch() {
        let recognizer = GestureRecognizer()
        _ = run(recognizer, [.touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.7, y: 0)), .touchEnded(0.1)])
        // A late position from the pad, then the real next touch.
        XCTAssertTrue(run(recognizer, [.touchMoved(0.12, PadPoint(x: 0.69, y: 0))]).isEmpty)
        let outputs = run(recognizer, [.tick(0.7)])
        XCTAssertEqual(gestures(outputs), [.tap(.right, double: false)])
    }

    func testCircleDirection() {
        let recognizer = GestureRecognizer()
        // Counterclockwise in pad coordinates (y up): angle increases.
        var events: [InputEvent] = [.touchBegan(0)]
        for step in 0...36 {
            let angle = Double(step) * 10 * .pi / 180
            events.append(.touchMoved(0.02 * Double(step), PadPoint(x: 0.8 * cos(angle), y: 0.8 * sin(angle))))
        }
        events.append(.touchEnded(0.8))
        XCTAssertEqual(gestures(run(recognizer, events)), [.circle(clockwise: false)])

        var clockwise: [InputEvent] = [.touchBegan(2)]
        for step in 0...36 {
            let angle = -Double(step) * 10 * .pi / 180
            clockwise.append(.touchMoved(2 + 0.02 * Double(step), PadPoint(x: 0.8 * cos(angle), y: 0.8 * sin(angle))))
        }
        clockwise.append(.touchEnded(2.8))
        XCTAssertEqual(gestures(run(recognizer, clockwise)), [.circle(clockwise: true)])
    }

    // MARK: - Drawing

    private func digitStrokeEvents(_ template: DigitTemplate, start: TimeInterval) -> [InputEvent] {
        var events: [InputEvent] = []
        var time = start
        for stroke in template.strokes {
            events.append(.touchBegan(time))
            for point in stroke {
                time += 0.01
                events.append(.touchMoved(time, point))
            }
            time += 0.01
            events.append(.touchEnded(time))
            time += 0.2
        }
        return events
    }

    func testLongPressThenDrawRecognizesTheDigit() {
        var tuning = Tuning()
        tuning.drawingMode = .longPressThenDraw
        let recognizer = GestureRecognizer(tuning: tuning)
        var outputs = run(recognizer, [.pressBegan(0, .select), .tick(0.6)])
        XCTAssertEqual(outputs, [.drawingStarted])
        XCTAssertTrue(recognizer.isDrawing)
        outputs = run(recognizer, [.pressEnded(0.8, .select)])
        XCTAssertTrue(outputs.isEmpty)

        let seven = DigitRecognizer.defaultTemplates.first { $0.digit == 7 }!
        let drawing = digitStrokeEvents(seven, start: 1.0)
        outputs = run(recognizer, drawing)
        XCTAssertTrue(outputs.isEmpty)
        let end = drawing.last.map { event -> TimeInterval in
            if case let .touchEnded(t) = event { return t }
            return 0
        } ?? 0
        outputs = run(recognizer, [.tick(end + 0.9)])
        guard case let .drawingFinished(result) = outputs.first else {
            return XCTFail("expected a finished drawing, got \(outputs)")
        }
        XCTAssertEqual(result.digit, 7)
        XCTAssertFalse(recognizer.isDrawing)
    }

    func testArmedDrawingWithoutStrokesCancels() {
        let recognizer = GestureRecognizer()
        _ = run(recognizer, [.pressBegan(0, .select), .tick(0.6), .pressEnded(0.7, .select)])
        XCTAssertEqual(run(recognizer, [.tick(3.0)]), [.drawingCancelled])
    }

    func testHoldToDrawFinishesOnRelease() {
        var tuning = Tuning()
        tuning.drawingMode = .holdSelect
        let recognizer = GestureRecognizer(tuning: tuning)
        XCTAssertEqual(run(recognizer, [.pressBegan(0, .select), .tick(0.6)]), [.drawingStarted])
        let one = DigitRecognizer.defaultTemplates.first { $0.digit == 1 }!
        _ = run(recognizer, digitStrokeEvents(one, start: 0.7))
        let outputs = run(recognizer, [.pressEnded(2.0, .select)])
        guard case let .drawingFinished(result) = outputs.first else {
            return XCTFail("expected a finished drawing, got \(outputs)")
        }
        XCTAssertEqual(result.digit, 1)
    }

    func testDrawingOffMakesALongPress() {
        var tuning = Tuning()
        tuning.drawingMode = .off
        let recognizer = GestureRecognizer(tuning: tuning)
        XCTAssertEqual(gestures(run(recognizer, [.pressBegan(0, .select), .tick(0.6)])), [.click(.select, .long)])
    }
}
