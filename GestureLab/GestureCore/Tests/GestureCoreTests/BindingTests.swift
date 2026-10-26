import XCTest
@testable import GestureCore

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

    func testSinglesWaitOnlyForABoundDouble() {
        var bindings = GestureBindings.defaults
        XCTAssertFalse(bindings.waitsForDouble(.click(.right, .double)))
        bindings.bind(.click(.right, .double), to: .nextChapter)
        XCTAssertTrue(bindings.waitsForDouble(.click(.right, .double)))
    }

    func testBindingsSurviveSaving() throws {
        var bindings = GestureBindings.defaults
        bindings.bind(.circle(clockwise: true), to: .faster)
        bindings.bind(.swipeBack(.up), to: .skipIntro)
        let data = try JSONEncoder().encode(bindings)
        XCTAssertEqual(try JSONDecoder().decode(GestureBindings.self, from: data), bindings)
    }

    func testOlderSavedSettingsKeepWhatTheyHave() throws {
        // Saved by older builds: old names, settings that are gone, no newer ones.
        let old = #"{"doubleWindow":0.5,"longPress":0.7,"swipeMin":0.6,"drawingMode":"off","sideThreshold":0.3}"#
        let tuning = try JSONDecoder().decode(Tuning.self, from: Data(old.utf8))
        XCTAssertEqual(tuning.doubleWindow, 0.5)
        XCTAssertEqual(tuning.longPress, 0.7)
        XCTAssertEqual(tuning.swipeMinPoints, Tuning().swipeMinPoints)
        XCTAssertEqual(tuning.clickGuard, Tuning().clickGuard)
        // The middle got smaller: the old saved size doesn't carry over.
        XCTAssertEqual(tuning.sideThreshold, 0.20)

        var changed = Tuning()
        changed.swipeLongPoints = 700
        let roundTrip = try JSONDecoder().decode(Tuning.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(roundTrip, changed)
    }

    func testTitles() {
        XCTAssertEqual(RemoteGesture.click(.right, .double).title, "Dvojklik vpravo")
        XCTAssertEqual(RemoteGesture.swipe(.left, long: true).title, "Dlouhý tah doleva")
        XCTAssertEqual(RemoteGesture.tap(.left, double: true).title, "Dvojí dotyk vlevo")
        XCTAssertEqual(RemoteGesture.swipeBack(.right).title, "Tah doprava a zpět")
        XCTAssertEqual(RemoteGesture.swipeBack(.down).title, "Tah dolů a zpět")
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

    func testSeekAndSpeed() {
        var timeline = LabTimeline()
        timeline.position = 5
        XCTAssertEqual(timeline.perform(.back10), "−10 s → 0:00")
        XCTAssertEqual(timeline.perform(.faster), "Rychlost 1.25×")
        timeline.advance(by: 4)
        XCTAssertEqual(timeline.position, 5)
    }
}
