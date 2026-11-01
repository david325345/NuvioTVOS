import XCTest
@testable import NuvioTV

final class PlayerGestureBindingTests: XCTestCase {
    func testLongSwipesJumpChaptersByDefault() {
        let bindings = PlayerGestureBindings.defaults
        XCTAssertEqual(bindings.action(for: .swipe(.right, long: true)), .nextChapter)
        XCTAssertEqual(bindings.action(for: .swipe(.left, long: true)), .previousChapter)
        XCTAssertNil(bindings.action(for: .click(.right, .single)))
    }

    func testBindingTakesTheGestureFromAnotherAction() {
        var bindings = PlayerGestureBindings.defaults
        let previous = bindings.bind(.swipe(.right, long: true), to: .skipIntro)
        XCTAssertEqual(previous, .nextChapter)
        XCTAssertEqual(bindings.action(for: .swipe(.right, long: true)), .skipIntro)
        XCTAssertNil(bindings.gesture(for: .nextChapter))
    }

    func testAnActionHasOneGesture() {
        var bindings = PlayerGestureBindings.defaults
        bindings.bind(.click(.right, .double), to: .nextChapter)
        XCTAssertEqual(bindings.gesture(for: .nextChapter), .click(.right, .double))
        XCTAssertNil(bindings.action(for: .swipe(.right, long: true)))
        bindings.unbind(.nextChapter)
        XCTAssertNil(bindings.gesture(for: .nextChapter))
    }

    func testBindingsAreKeptInTheProfile() throws {
        let suite = "PlayerGestureBindingTests.saved"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PlayerGestureSettings.isEnabled(in: settings))
        XCTAssertEqual(PlayerGestureSettings.bindings(in: settings), .defaults)

        var bindings = PlayerGestureBindings.defaults
        bindings.bind(.circle(clockwise: true), to: .faster)
        bindings.bind(.click(.up, .long), to: .toggleSubtitles)
        PlayerGestureSettings.save(bindings, in: settings)
        PlayerGestureSettings.setEnabled(true, in: settings)
        XCTAssertEqual(PlayerGestureSettings.bindings(in: settings), bindings)
        XCTAssertTrue(PlayerGestureSettings.isEnabled(in: settings))
    }

    func testUnboundGesturesKeepThePlayersOwnMeaning() {
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.right, .single)), .seekForward)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.left, .long)), .holdSeekBack)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.select, .single)), .select)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.down, .single)), .openPanel)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .swipe(.up, long: false)), .revealControls)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .tap(.bottomLeft, double: false)), .seekBack)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .tap(.center, double: false)), .peek)
        // Free while playing: nothing happens unless a gesture is bound.
        XCTAssertNil(PlayerBuiltInGesture.action(for: .swipe(.right, long: true)))
        XCTAssertNil(PlayerBuiltInGesture.action(for: .circle(clockwise: true)))
        XCTAssertNil(PlayerBuiltInGesture.action(for: .hold(.left)))
    }

    func testTitles() {
        XCTAssertEqual(RemoteGesture.click(.right, .double).title, "Dvojklik vpravo")
        XCTAssertEqual(RemoteGesture.swipe(.left, long: true).title, "Dlouhý tah doleva")
        XCTAssertEqual(RemoteGesture.swipeBack(.right).title, "Tah doprava a zpět")
        XCTAssertEqual(PlayerGestureAction.nextChapter.title, "Další kapitola")
    }
}
