import XCTest
@testable import NuvioTV

final class PlayerPanelTabsTests: XCTestCase {
    func testNothingSavedIsTheDefaultOrder() {
        let config = PlayerPanelTabs.decode(nil)
        XCTAssertEqual(config.order, [.chapters, .scene, .info, .upNext, .watchParty])
        XCTAssertTrue(config.hidden.isEmpty)
    }

    func testOrderAndHiddenTabsRoundTrip() {
        let raw = "info,-watchParty,chapters,scene,-upNext"
        let config = PlayerPanelTabs.decode(raw)
        XCTAssertEqual(config.order, [.info, .watchParty, .chapters, .scene, .upNext])
        XCTAssertEqual(config.hidden, [.watchParty, .upNext])
        XCTAssertEqual(PlayerPanelTabs.encode(config), raw)
    }

    func testUnknownAndRepeatedTabsAreIgnoredAndMissingOnesAdded() {
        let config = PlayerPanelTabs.decode("upNext, bogus,upNext,-scene")
        XCTAssertEqual(config.order, [.upNext, .scene, .chapters, .info, .watchParty])
        // InSight has its own setting: never hidden here.
        XCTAssertFalse(config.hidden.contains(.scene))
    }

    func testTheTabsShownHaveSomethingToShow() {
        let config = PlayerPanelTabs.decode("scene,chapters,info,-upNext,watchParty")
        XCTAssertEqual(
            PlayerPanelTabs.tabs(config: config, sceneEnabled: true, hasChapters: true,
                                 hasNextEpisode: true, watchPartyAvailable: true),
            [.scene, .chapters, .info, .watchParty])
        XCTAssertEqual(
            PlayerPanelTabs.tabs(config: config, sceneEnabled: false, hasChapters: false,
                                 hasNextEpisode: true, watchPartyAvailable: false),
            [.info])
        let allHidden = PlayerPanelTabs.decode("-chapters,scene,-info,-upNext,-watchParty")
        XCTAssertTrue(PlayerPanelTabs.tabs(config: allHidden, sceneEnabled: false, hasChapters: true,
                                           hasNextEpisode: true, watchPartyAvailable: true).isEmpty)
    }

    func testMovingATab() {
        let config = PlayerPanelTabs.decode(nil)
        XCTAssertEqual(PlayerPanelTabs.moving(.info, up: true, in: config).order,
                       [.chapters, .info, .scene, .upNext, .watchParty])
        XCTAssertEqual(PlayerPanelTabs.moving(.chapters, up: true, in: config), config, "the first stays first")
        XCTAssertEqual(PlayerPanelTabs.moving(.watchParty, up: false, in: config), config, "the last stays last")
    }
}
