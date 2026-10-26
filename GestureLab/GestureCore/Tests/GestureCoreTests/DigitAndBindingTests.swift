import XCTest
@testable import GestureCore

final class DigitRecognizerTests: XCTestCase {
    func testEveryBuiltInShapeIsItsOwnDigit() {
        let recognizer = DigitRecognizer()
        for template in DigitRecognizer.defaultTemplates {
            let match = recognizer.recognize(template.strokes)
            XCTAssertEqual(match?.digit, template.digit, "template \(template.digit)")
            XCTAssertEqual(match?.score ?? 0, 1, accuracy: 0.0001)
        }
    }

    func testSmallerShiftedAndShakyDrawingsStillMatch() {
        let recognizer = DigitRecognizer()
        for (index, template) in DigitRecognizer.defaultTemplates.enumerated() {
            var seed = Double(index + 1)
            let shaky = template.strokes.map { stroke in
                stroke.map { point -> PadPoint in
                    seed = (seed * 7.3).truncatingRemainder(dividingBy: 1)
                    let noise = (seed - 0.5) * 0.02
                    return PadPoint(x: point.x * 0.6 + 0.1 + noise, y: point.y * 0.6 - 0.2 - noise)
                }
            }
            XCTAssertEqual(recognizer.recognize(shaky)?.digit, template.digit, "template \(template.digit)")
        }
    }

    func testSixAndNineStayApart() {
        let recognizer = DigitRecognizer()
        let six = DigitRecognizer.defaultTemplates.first { $0.digit == 6 }!
        let match = recognizer.recognize(six.strokes)
        XCTAssertEqual(match?.digit, 6)
        XCTAssertNotNil(match?.runnerUp)
    }

    func testOwnSamplesAreUsed() {
        // Only an own "Z" for 2: a Z is recognized as 2.
        let z = DigitTemplate(digit: 2, strokes: [[PadPoint(x: -0.8, y: 0.8), PadPoint(x: 0.8, y: 0.8),
                                                   PadPoint(x: -0.8, y: -0.8), PadPoint(x: 0.8, y: -0.8)]])
        let recognizer = DigitRecognizer(userTemplates: [z], includeDefaults: false)
        XCTAssertEqual(recognizer.recognize(z.strokes)?.digit, 2)
        XCTAssertNil(DigitRecognizer(includeDefaults: false).recognize(z.strokes))
    }

    func testADotIsNoDrawing() {
        XCTAssertNil(DigitRecognizer.normalize([[PadPoint(x: 0.2, y: 0.2), PadPoint(x: 0.2, y: 0.2)]]))
        XCTAssertNil(DigitRecognizer().recognize([]))
    }

    func testScoreRange() {
        XCTAssertEqual(DigitRecognizer.score(forDistance: 0), 1)
        XCTAssertEqual(DigitRecognizer.score(forDistance: 1000), 0)
    }
}

final class BindingTests: XCTestCase {
    func testBindingTakesTheGestureFromAnotherAction() {
        var bindings = GestureBindings.defaults
        XCTAssertEqual(bindings.action(for: .swipe(.right, long: true)), .nextChapter)
        XCTAssertEqual(bindings.conflict(for: .swipe(.right, long: true), action: .skipIntro), .nextChapter)
        let previous = bindings.bind(.swipe(.right, long: true), to: .skipIntro)
        XCTAssertEqual(previous, .nextChapter)
        XCTAssertEqual(bindings.action(for: .swipe(.right, long: true)), .skipIntro)
        XCTAssertNil(bindings.gesture(for: .nextChapter))
    }

    func testAnActionHasOneGesture() {
        var bindings = GestureBindings.defaults
        bindings.bind(.tap(.right, double: true), to: .nextChapter)
        XCTAssertEqual(bindings.gesture(for: .nextChapter), .tap(.right, double: true))
        XCTAssertNil(bindings.action(for: .swipe(.right, long: true)))
    }

    func testDigitsAreNotBound() {
        var bindings = GestureBindings.defaults
        XCTAssertNil(bindings.bind(.digit(3), to: .nextChapter))
        XCTAssertEqual(bindings.gesture(for: .nextChapter), .swipe(.right, long: true))
    }

    func testSinglesWaitOnlyForABoundDouble() {
        var bindings = GestureBindings.defaults
        XCTAssertFalse(bindings.waitsForDouble(.click(.right, .double)))
        bindings.bind(.click(.right, .double), to: .nextChapter)
        XCTAssertTrue(bindings.waitsForDouble(.click(.right, .double)))
    }

    func testBindingsSurviveSaving() throws {
        var bindings = GestureBindings.defaults
        bindings.bind(.circle(clockwise: true), to: .faster)
        bindings.digitMode = .percent
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode(GestureBindings.self, from: data), bindings)
    }

    func testOlderSavedSettingsKeepWhatTheyHave() throws {
        // Saved by the first build: old names, no newer settings.
        let old = #"{"doubleWindow":0.5,"longPress":0.7,"swipeMin":0.6,"drawingMode":"off"}"#
        let tuning = try JSONDecoder().decode(Tuning.self, from: Data(old.utf8))
        XCTAssertEqual(tuning.doubleWindow, 0.5)
        XCTAssertEqual(tuning.longPress, 0.7)
        XCTAssertEqual(tuning.drawingMode, .off)
        XCTAssertEqual(tuning.swipeMinPoints, Tuning().swipeMinPoints)
        XCTAssertEqual(tuning.clickGuard, Tuning().clickGuard)

        var changed = Tuning()
        changed.swipeLongPoints = 700
        let roundTrip = try JSONDecoder().decode(Tuning.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(roundTrip, changed)
    }

    func testTitles() {
        XCTAssertEqual(RemoteGesture.click(.right, .double).title, "Dvojklik vpravo")
        XCTAssertEqual(RemoteGesture.swipe(.left, long: true).title, "Dlouhý tah doleva")
        XCTAssertEqual(RemoteGesture.tap(.left, double: true).title, "Dvojí dotyk vlevo")
        XCTAssertEqual(RemoteGesture.digit(3).title, "Číslice 3")
        XCTAssertEqual(RemoteGesture.hold(.bottomLeft).title, "Přidržení vlevo dole")
        XCTAssertEqual(RemoteGesture.tap(.topRight, double: true).title, "Dvojí dotyk vpravo nahoře")
    }
}

final class LabTimelineTests: XCTestCase {
    func testChapterJumps() {
        var timeline = LabTimeline()
        timeline.position = 200
        XCTAssertEqual(timeline.perform(.nextChapter), "Kapitola 4: Část B")
        XCTAssertEqual(timeline.position, 720)
        timeline.position = 730
        XCTAssertEqual(timeline.perform(.previousChapter), "Znovu kapitola 4: Část B")
        XCTAssertEqual(timeline.position, 720)
        XCTAssertEqual(timeline.perform(.previousChapter), "Kapitola 3: Část A")
        XCTAssertEqual(timeline.position, 180)
    }

    func testSkipIntroOnlyInTheOpening() {
        var timeline = LabTimeline()
        timeline.position = 100
        XCTAssertEqual(timeline.perform(.skipIntro), "Úvod přeskočen")
        XCTAssertEqual(timeline.position, 180)
        XCTAssertEqual(timeline.perform(.skipIntro), "Tady není úvod")
    }

    func testDigitJumps() {
        var timeline = LabTimeline()
        XCTAssertEqual(timeline.jump(toDigit: 3, mode: .chapter), "Kapitola 3: Část A")
        XCTAssertEqual(timeline.jump(toDigit: 9, mode: .chapter), "Kapitola 9 neexistuje")
        timeline.jump(toDigit: 5, mode: .percent)
        XCTAssertEqual(timeline.position, 710)
    }

    func testSeekAndSpeed() {
        var timeline = LabTimeline()
        timeline.position = 5
        XCTAssertEqual(timeline.perform(.back10), "−10 s → 0:00")
        XCTAssertEqual(timeline.perform(.faster), "Rychlost 1.25×")
        timeline.advance(by: 4)
        XCTAssertEqual(timeline.position, 5)
    }
}
