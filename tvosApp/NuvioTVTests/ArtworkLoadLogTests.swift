import XCTest
@testable import NuvioTV

/// Test build diagnostics: the artwork and redraw lines of the test log.
final class ArtworkLoadLogTests: XCTestCase {
    func testTheArtworkLineSaysWhereThePostersCameFromAndHowLongCardsWaited() {
        var window = ArtworkLoadLog.Window()
        window.sources[.memory] = 30
        window.sources[.disk] = 2
        window.sources[.network] = 1
        window.diskRead.add(4)
        window.diskRead.add(6)
        window.download.add(410)
        window.downloadBytes = 1_572_864
        window.decode.add(20)
        window.decode.add(30)
        window.decode.add(61)
        window.decodeWait.add(140)
        window.longestSide.add(500)
        window.longestSide.add(540)
        window.longestSide.add(520)
        window.decodedBytes = 3 * 943_718
        window.placeholderWait.add(80)
        window.placeholderWait.add(160)
        window.placeholderWaitsOver100 = 1
        let line = ArtworkLoadLog.line(
            .poster,
            window,
            screen: "main · home",
            memory: (count: 160, totalBytes: 92 * 1_048_576, maxCost: 140 * 1_048_576)
        )
        XCTAssertTrue(line.hasPrefix("art: 33 posters in 5 s on main · home — 30 from memory, 2 from disk (read avg 5 ms"), line)
        XCTAssertTrue(line.contains("1 downloaded (avg 410 ms, longest 410 ms, 1.5 MB)"), line)
        XCTAssertTrue(line.contains("decoded 3 (avg 37 ms, longest 61 ms; 1 waited for a slot, longest 140 ms), 520 px, 921 KB each"), line)
        XCTAssertTrue(line.contains("2 cards showed a placeholder (avg 120 ms, longest 160 ms, 1 over 100 ms)"), line)
        XCTAssertTrue(line.hasSuffix("in memory 160 images, 92 of 140 MB"), line)
    }

    func testAWindowWithOnlyMemoryHitsStaysShort() {
        var window = ArtworkLoadLog.Window()
        window.sources[.memory] = 1
        let line = ArtworkLoadLog.line(.backdrop, window, screen: "details(tt1, movie)", memory: (count: 3, totalBytes: 0, maxCost: 96 * 1_048_576))
        XCTAssertEqual(line, "art: 1 backdrop in 5 s on details(tt1, movie) — 1 from memory · in memory 3 images, 0 of 96 MB")
    }

    func testARedrawCauseNamesWhatChanged() {
        XCTAssertEqual(RedrawCause.label("Home", changed: ["focus moved", "hero title"]), "Home because focus moved + hero title")
        XCTAssertEqual(RedrawCause.label("Home", changed: []), "Home because of nothing it holds")
    }

    func testTheRedrawLineListsTheMostRedrawnFirst() {
        let line = RedrawLog.line(["Home": 3, "Home row": 56, "tabs": 3], screen: "main · home")
        XCTAssertEqual(line, "ui: redrawn in 5 s on main · home: Home row ×56, Home ×3, tabs ×3")
    }
}
