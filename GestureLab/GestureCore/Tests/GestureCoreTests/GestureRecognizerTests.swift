import XCTest
@testable import GestureCore

final class GestureRecognizerTests: XCTestCase {
    private func gestures(_ outputs: [RecognizerOutput]) -> [RemoteGesture] {
        outputs.compactMap {
            if case let .gesture(gesture, _, _) = $0 { return gesture }
            return nil
        }
    }

    private func run(_ recognizer: GestureRecognizer, _ events: [InputEvent]) -> [RecognizerOutput] {
        events.flatMap { recognizer.handle($0) }
    }

    /// A finger moving in a straight line, with the system's movement in
    /// points (`points` per pad unit) and a short hold before lifting.
    private func stroke(from: PadPoint, to: PadPoint, start: TimeInterval, duration: TimeInterval,
                        points: Double = 600, steps: Int = 10) -> [InputEvent] {
        var events: [InputEvent] = [.touchBegan(start)]
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let time = start + duration * t
            events.append(.touchMoved(time, PadPoint(x: from.x + (to.x - from.x) * t + 0.011,
                                                     y: from.y + (to.y - from.y) * t + 0.013)))
            events.append(.touchTranslation(time, dx: (to.x - from.x) * t * points, dy: (to.y - from.y) * t * points))
        }
        events.append(.touchEnded(start + duration + 0.1))
        return events
    }

    // MARK: - Clicks

    func testSingleClickWaitsOnlyWhenTheDoubleIsUsed() {
        let waiting = GestureRecognizer(waitsForDouble: { _ in true })
        XCTAssertTrue(run(waiting, [.pressBegan(0, .right), .pressEnded(0.1, .right), .tick(0.2)]).isEmpty)
        let late = run(waiting, [.tick(0.5)])
        XCTAssertEqual(gestures(late), [.click(.right, .single)])
        if case let .gesture(_, input, decided) = late[0] {
            XCTAssertEqual(input, 0.1)
            XCTAssertEqual(decided, 0.5)
        }

        let immediate = GestureRecognizer(waitsForDouble: { _ in false })
        XCTAssertEqual(gestures(run(immediate, [.pressBegan(0, .right), .pressEnded(0.1, .right)])),
                       [.click(.right, .single)])
    }

    func testDoubleClick() {
        let recognizer = GestureRecognizer()
        let outputs = run(recognizer, [
            .pressBegan(0, .right), .pressEnded(0.08, .right), .tick(0.15),
            .pressBegan(0.2, .right), .pressEnded(0.28, .right), .tick(0.9),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.right, .double)])
    }

    func testSecondClickHeldPastTheWindowIsStillADouble() {
        let recognizer = GestureRecognizer()
        XCTAssertTrue(gestures(run(recognizer, [
            .pressBegan(0, .left), .pressEnded(0.1, .left), .pressBegan(0.3, .left), .tick(0.5),
        ])).isEmpty)
        XCTAssertEqual(gestures(run(recognizer, [.pressEnded(0.6, .left), .tick(1.2)])), [.click(.left, .double)])
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
        XCTAssertTrue(gestures(run(recognizer, [.pressEnded(1.0, .up), .tick(1.5)])).isEmpty)
    }

    // MARK: - Clicks on the edge (what the device does)

    func testClickOnTheEdgeIsNoSwipeEvenWhenTheTouchEndsFirst() {
        let recognizer = GestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.1, y: -0.2)),
            .touchMoved(0.06, PadPoint(x: 0.05, y: -0.95)), .touchTranslation(0.06, dx: 5, dy: -400),
            .touchEnded(0.08),
            .pressBegan(0.1, .down), .pressEnded(0.18, .down), .tick(0.6),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.down, .single)])
    }

    func testDoubleClickOnTheEdge() {
        let recognizer = GestureRecognizer()
        let outputs = run(recognizer, [
            .touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.05, y: -0.9)),
            .pressBegan(0.03, .down), .pressEnded(0.12, .down), .touchEnded(0.15),
            .touchBegan(0.25), .touchMoved(0.26, PadPoint(x: 0.04, y: -0.95)),
            .pressBegan(0.27, .down), .pressEnded(0.36, .down), .touchEnded(0.4), .tick(1.0),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.down, .double)])
    }

    // MARK: - Swipes

    func testSwipesFollowTheSystemMovement() {
        let recognizer = GestureRecognizer()
        var outputs = run(recognizer, stroke(from: PadPoint(x: -0.4, y: 0), to: PadPoint(x: 0.4, y: 0.05),
                                             start: 0, duration: 0.2))
        outputs += run(recognizer, [.tick(0.6)])
        XCTAssertEqual(gestures(outputs), [.swipe(.right, long: false)])

        outputs = run(recognizer, stroke(from: PadPoint(x: 0.8, y: 0.1), to: PadPoint(x: -0.7, y: 0),
                                         start: 1, duration: 0.3))
        outputs += run(recognizer, [.tick(1.8)])
        XCTAssertEqual(gestures(outputs), [.swipe(.left, long: true)])

        outputs = run(recognizer, stroke(from: PadPoint(x: 0, y: 0.5), to: PadPoint(x: 0.1, y: -0.4),
                                         start: 3, duration: 0.25))
        outputs += run(recognizer, [.tick(3.8)])
        XCTAssertEqual(gestures(outputs), [.swipe(.down, long: false)])
    }

    func testSlowOrDiagonalMovesAreNoSwipe() {
        let recognizer = GestureRecognizer()
        var outputs = run(recognizer, stroke(from: PadPoint(x: -0.5, y: 0), to: PadPoint(x: 0.5, y: 0),
                                             start: 0, duration: 2))
        outputs += run(recognizer, [.tick(2.6)])
        XCTAssertTrue(gestures(outputs).isEmpty)
        outputs = run(recognizer, stroke(from: PadPoint(x: -0.5, y: -0.5), to: PadPoint(x: 0.4, y: 0.4),
                                         start: 3, duration: 0.2))
        outputs += run(recognizer, [.tick(3.8)])
        XCTAssertTrue(gestures(outputs).isEmpty)
    }

    func testTouchWithAClickIsNoSwipeOrTap() {
        let recognizer = GestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchBegan(0), .touchMoved(0.01, PadPoint(x: 0.6, y: 0.02)),
            .pressBegan(0.02, .right), .pressEnded(0.1, .right),
            .touchMoved(0.12, PadPoint(x: 0.6, y: 0.02)), .touchEnded(0.15), .tick(0.6),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.right, .single)])
    }

    // MARK: - Light taps

    func testLightTapsBySideAndDoubleTap() {
        let recognizer = GestureRecognizer()
        let right = run(recognizer, [.touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.7, y: 0.1)),
                                     .touchEnded(0.1), .tick(0.6)])
        XCTAssertEqual(gestures(right), [.tap(.right, double: false)])

        let double = run(recognizer, [
            .touchBegan(1), .touchMoved(1.02, PadPoint(x: -0.6, y: 0.02)), .touchEnded(1.1),
            .touchBegan(1.25), .touchMoved(1.27, PadPoint(x: -0.65, y: 0.05)), .touchEnded(1.33), .tick(1.9),
        ])
        XCTAssertEqual(gestures(double), [.tap(.left, double: true)])
    }

    /// Seen on the device: a light touch on the left edge, the first position
    /// with y = 0, positions sliding to the middle on lift, (0, 0) before the
    /// touch ends. That is a tap on the left, not a swipe to the right.
    func testEdgeTouchSlidingToTheMiddleIsATap() {
        let recognizer = GestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchBegan(0),
            .touchMoved(0.008, PadPoint(x: -0.86, y: 0)),
            .touchMoved(0.03, PadPoint(x: -0.86, y: 0.02)),
            .touchMoved(0.1, PadPoint(x: -0.85, y: 0.01)),
            .touchTranslation(0.1, dx: 3, dy: -2),
            .touchMoved(0.17, PadPoint(x: -0.6, y: -0.1)),
            .touchMoved(0.2, PadPoint(x: -0.3, y: -0.3)),
            .touchMoved(0.215, PadPoint(x: 0, y: 0)),
            .touchEnded(0.224),
            .tick(0.5),
        ])
        XCTAssertEqual(gestures(outputs), [.tap(.left, double: false)])
        let summary = outputs.compactMap { output -> TouchSummary? in
            if case let .touchSummary(summary) = output { return summary }
            return nil
        }.first
        XCTAssertEqual(summary?.padStart, PadPoint(x: -0.86, y: 0.02))
        XCTAssertEqual(summary?.padEnd, PadPoint(x: -0.85, y: 0.01))
    }

    func testTapsOnTheTopAndBottomEdge() {
        let recognizer = GestureRecognizer(waitsForDouble: { _ in false })
        let bottom = run(recognizer, [.touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.08, y: -0.82)),
                                      .touchEnded(0.12), .tick(0.4)])
        XCTAssertEqual(gestures(bottom), [.tap(.bottom, double: false)])
        let top = run(recognizer, [.touchBegan(1), .touchMoved(1.02, PadPoint(x: -0.1, y: 0.75)),
                                   .touchEnded(1.12), .tick(1.4)])
        XCTAssertEqual(gestures(top), [.tap(.top, double: false)])
        let middle = run(recognizer, [.touchBegan(2), .touchMoved(2.02, PadPoint(x: 0.1, y: 0.12)),
                                      .touchEnded(2.12), .tick(2.4)])
        XCTAssertEqual(gestures(middle), [.tap(.center, double: false)])
    }

    func testSideIsTheNearestEdge() {
        XCTAssertEqual(GestureRecognizer.side(of: [PadPoint(x: -0.7, y: 0.5)], threshold: 0.3), .left)
        XCTAssertEqual(GestureRecognizer.side(of: [PadPoint(x: 0.4, y: -0.6)], threshold: 0.3), .bottom)
        XCTAssertEqual(GestureRecognizer.side(of: [PadPoint(x: 0.2, y: -0.25)], threshold: 0.3), .center)
        XCTAssertEqual(GestureRecognizer.side(of: [], threshold: 0.3), .center)
    }

    func testPadPositionsAloneNeverStartATouch() {
        let recognizer = GestureRecognizer()
        XCTAssertTrue(run(recognizer, [
            .touchMoved(0.1, PadPoint(x: 0.02, y: 0.01)), .touchMoved(0.2, PadPoint(x: -0.7, y: 0.03)),
            .tick(1.0),
        ]).isEmpty)
    }

    func testCircleDirection() {
        let recognizer = GestureRecognizer()
        // Counterclockwise in pad coordinates (y up): angle increases.
        var events: [InputEvent] = [.touchBegan(0)]
        for step in 0...36 {
            let angle = (Double(step) * 10 + 5) * .pi / 180
            events.append(.touchMoved(0.02 * Double(step), PadPoint(x: 0.8 * cos(angle), y: 0.8 * sin(angle))))
        }
        events += [.touchEnded(0.85), .tick(1.2)]
        XCTAssertEqual(gestures(run(recognizer, events)), [.circle(clockwise: false)])

        var clockwise: [InputEvent] = [.touchBegan(2)]
        for step in 0...36 {
            let angle = -(Double(step) * 10 + 5) * .pi / 180
            clockwise.append(.touchMoved(2 + 0.02 * Double(step), PadPoint(x: 0.8 * cos(angle), y: 0.8 * sin(angle))))
        }
        clockwise += [.touchEnded(2.85), .tick(3.2)]
        XCTAssertEqual(gestures(run(recognizer, clockwise)), [.circle(clockwise: true)])
    }

    // MARK: - Drawing

    private func digitStrokeEvents(_ template: DigitTemplate, start: TimeInterval) -> [InputEvent] {
        var events: [InputEvent] = []
        var time = start
        for stroke in template.strokes {
            events.append(.touchBegan(time))
            for point in stroke {
                time += 0.03
                events.append(.touchMoved(time, PadPoint(x: point.x + 0.011, y: point.y + 0.013)))
            }
            time += 0.1
            events.append(.touchEnded(time))
            time += 0.2
        }
        return events
    }

    private func endTime(_ events: [InputEvent]) -> TimeInterval {
        for event in events.reversed() {
            if case let .touchEnded(time) = event { return time }
        }
        return 0
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
        outputs = run(recognizer, [.tick(endTime(drawing) + 0.9)])
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
