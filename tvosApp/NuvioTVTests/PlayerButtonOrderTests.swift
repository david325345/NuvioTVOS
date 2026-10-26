import XCTest
@testable import NuvioTV

final class PlayerButtonOrderTests: XCTestCase {
    func testNothingStoredIsTheDefaultOrder() {
        XCTAssertEqual(PlayerButtonOrder.parse(""), [.pip, .chapters, .episodes, .sources, .subtitles, .audio])
    }

    func testStoredOrderSkipsUnknownNamesAndRepeats() {
        XCTAssertEqual(
            PlayerButtonOrder.parse("audio, subtitles,scene,audio,pip,chapters,episodes,sources"),
            [.audio, .subtitles, .pip, .chapters, .episodes, .sources]
        )
    }

    func testAMissingButtonGoesAfterTheOneItFollowsByDefault() {
        // Saved before the Chapters button existed: it lands right after PiP.
        XCTAssertEqual(
            PlayerButtonOrder.parse("subtitles,pip,episodes,sources,audio"),
            [.subtitles, .pip, .chapters, .episodes, .sources, .audio]
        )
        // Nothing before it by default: it goes first.
        XCTAssertEqual(
            PlayerButtonOrder.parse("audio,chapters,episodes,sources,subtitles"),
            [.pip, .audio, .chapters, .episodes, .sources, .subtitles]
        )
    }

    func testMovingStaysInsideTheRow() {
        let order = PlayerButtonOrder.defaultOrder
        XCTAssertEqual(PlayerButtonOrder.moving(.subtitles, by: -1, in: order), [.pip, .chapters, .episodes, .subtitles, .sources, .audio])
        XCTAssertEqual(PlayerButtonOrder.moving(.pip, by: 1, in: order), [.chapters, .pip, .episodes, .sources, .subtitles, .audio])
        XCTAssertEqual(PlayerButtonOrder.moving(.pip, by: -1, in: order), order)
        XCTAssertEqual(PlayerButtonOrder.moving(.audio, by: 1, in: order), order)
    }

    func testSettingsKeysAreProfileSettings() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowChapters))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerButtonOrder))
    }

    func testStoredTextRoundTrips() {
        let order: [PlayerButtonKind] = [.audio, .pip, .subtitles, .chapters, .sources, .episodes]
        XCTAssertEqual(PlayerButtonOrder.parse(PlayerButtonOrder.serialize(order)), order)
        XCTAssertEqual(PlayerButtonOrder.serialize(PlayerButtonOrder.defaultOrder), "pip,chapters,episodes,sources,subtitles,audio")
    }
}
