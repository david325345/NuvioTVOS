import XCTest
@testable import NuvioTV

final class StreamListStyleTests: XCTestCase {
    func testTheDefaultsAreTheListAsItWas() {
        let style = StreamListStyle()
        let layout = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(layout.summaryWidth, 620)
        XCTAssertEqual(layout.panelWidth, 1920 * 0.56, accuracy: 0.001)
        XCTAssertEqual(layout.panelHeight, 720)
        XCTAssertEqual(layout.stackHeight, 838)
        XCTAssertTrue(layout.showsSummary)
        XCTAssertFalse(layout.showsHeader)
        XCTAssertEqual(style.font(34), 34)
        XCTAssertEqual(style.nameLines, 2)
        XCTAssertEqual(style.descriptionLines, 6)
        XCTAssertEqual(style.metrics.minHeight, 250)
        XCTAssertEqual(style.metrics.cardSpacing, 28)
    }

    func testWideNarrowsTheSummary() {
        var style = StreamListStyle()
        style.width = .wide
        let layout = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(layout.panelWidth, 1344)
        XCTAssertEqual(layout.summaryWidth, 376)
        XCTAssertTrue(layout.showsSummary)
    }

    func testFullPutsTheEpisodeAboveTheList() {
        var style = StreamListStyle()
        style.width = .full
        let layout = style.layout(width: 1920, height: 1080)
        XCTAssertEqual(layout.panelWidth, 1792)
        XCTAssertFalse(layout.showsSummary)
        XCTAssertTrue(layout.showsHeader)
        XCTAssertEqual(layout.panelHeight, 750)
        XCTAssertEqual(layout.stackHeight, 90 + 112 + 750 + 40)
        XCTAssertLessThanOrEqual(layout.stackHeight, 1080 - 88)

        style.episodeHeader = false
        let plain = style.layout(width: 1920, height: 1080)
        XCTAssertFalse(plain.showsHeader)
        XCTAssertFalse(plain.showsSummary)
        XCTAssertEqual(plain.panelHeight, 720)
    }

    func testTheTextScales() {
        var style = StreamListStyle()
        style.textScale = 60
        XCTAssertEqual(style.font(34), 20)
        style.textScale = 130
        XCTAssertEqual(style.font(34), 44)
    }

    func testStoredValuesOutsideTheChoicesFallBack() {
        let style = StreamListStyle(
            textScale: 75, cardSize: "huge", width: "giant",
            nameLines: 0, descriptionLines: 0, episodeHeader: false, expandFocused: true)
        XCTAssertEqual(style.textScale, 100)
        XCTAssertEqual(style.cardSize, .standard)
        XCTAssertEqual(style.width, .standard)
        XCTAssertNil(style.nameLines)
        XCTAssertNil(style.descriptionLines)
        XCTAssertTrue(style.expandFocused)
    }

    func testCompactCardsHaveNoMinimumHeight() {
        var style = StreamListStyle()
        style.cardSize = .compact
        XCTAssertEqual(style.metrics.minHeight, 0)
        XCTAssertLessThan(style.metrics.cardSpacing, StreamListStyle().metrics.cardSpacing)
    }

    func testTheSettingsLabelsGoBothWays() {
        XCTAssertEqual(StreamListStyle.textScaleLabel(115), "115 %")
        XCTAssertEqual(StreamListStyle.textScale(fromLabel: "115 %"), 115)
        XCTAssertEqual(StreamListStyle.linesLabel(0), "All")
        XCTAssertEqual(StreamListStyle.linesLabel(10), "10")
        XCTAssertEqual(StreamListStyle.lines(fromLabel: "All"), 0)
        XCTAssertEqual(StreamListStyle.lines(fromLabel: "3"), 3)
    }

    func testTheStyleIsReadFromTheProfileSettings() throws {
        let name = "StreamListStyleTests"
        let settings = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { settings.removePersistentDomain(forName: name) }
        XCTAssertEqual(StreamListStyle.current(in: settings), StreamListStyle())

        settings.set(80, forKey: SettingsKey.streamListTextScale)
        settings.set("compact", forKey: SettingsKey.streamListCardSize)
        settings.set("full", forKey: SettingsKey.streamListWidth)
        settings.set(0, forKey: SettingsKey.streamListDescriptionLines)
        settings.set(false, forKey: SettingsKey.streamListEpisodeHeader)
        let style = StreamListStyle.current(in: settings)
        XCTAssertEqual(style.textScale, 80)
        XCTAssertEqual(style.cardSize, .compact)
        XCTAssertEqual(style.width, .full)
        XCTAssertEqual(style.nameLines, 2)
        XCTAssertNil(style.descriptionLines)
        XCTAssertFalse(style.episodeHeader)
    }
}
