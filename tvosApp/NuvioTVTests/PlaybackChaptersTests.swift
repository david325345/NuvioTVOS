import XCTest
@testable import NuvioTV

final class PlaybackChaptersTests: XCTestCase {
    private func chapter(_ id: Int, _ name: String, _ start: Double, _ end: Double) -> PlaybackChapter {
        PlaybackChapter(id: id, name: name, startSeconds: start, endSeconds: end)
    }

    func testChaptersAreSortedAndEndWhereTheNextStarts() {
        let chapters = PlaybackChapters.chapters(
            from: [
                (id: 2, name: "Part B", start: 600, duration: 0),
                (id: 0, name: "Opening", start: 0, duration: 90),
                (id: 1, name: "Part A", start: 90, duration: 0),
            ],
            totalDuration: 1420
        )
        XCTAssertEqual(chapters.map(\.id), [0, 1, 2])
        XCTAssertEqual(chapters.map(\.endSeconds), [90, 600, 1420])
        // A length past the next chapter is cut at it.
        let overlapping = PlaybackChapters.chapters(
            from: [(id: 0, name: "", start: 0, duration: 200), (id: 1, name: "", start: 120, duration: 0)],
            totalDuration: 300
        )
        XCTAssertEqual(overlapping.map(\.endSeconds), [120, 300])
    }

    func testASingleChapterIsNoChapterList() {
        XCTAssertTrue(PlaybackChapters.chapters(from: [(id: 0, name: "Movie", start: 0, duration: 0)], totalDuration: 5400).isEmpty)
        XCTAssertTrue(PlaybackChapters.chapters(from: [], totalDuration: 5400).isEmpty)
        XCTAssertEqual(
            PlaybackChapters.chapters(
                from: [(id: 0, name: "A", start: 0, duration: 0), (id: 1, name: "B", start: 600, duration: 0)],
                totalDuration: 5400
            ).count,
            2
        )
    }

    func testGenericNamesBecomeChapterNumbers() {
        XCTAssertEqual(PlaybackChapters.displayName(chapter(0, "Opening", 0, 90), index: 0), "Opening")
        XCTAssertEqual(PlaybackChapters.displayName(chapter(1, "Chapter 03", 90, 200), index: 2), "Chapter 3")
        XCTAssertEqual(PlaybackChapters.displayName(chapter(2, "  ", 90, 200), index: 4), "Chapter 5")
        XCTAssertEqual(PlaybackChapters.displayName(chapter(3, "00:12:30.000", 750, 900), index: 1), "Chapter 2")
    }

    func testChapterAtThePlayhead() {
        let chapters = [chapter(0, "A", 0, 90), chapter(1, "B", 90, 600), chapter(2, "C", 600, 1420)]
        XCTAssertEqual(PlaybackChapters.index(at: 0, in: chapters), 0)
        XCTAssertEqual(PlaybackChapters.index(at: 89.5, in: chapters), 0)
        XCTAssertEqual(PlaybackChapters.index(at: 300, in: chapters), 1)
        XCTAssertEqual(PlaybackChapters.index(at: 1500, in: chapters), 2)
        XCTAssertNil(PlaybackChapters.index(at: 10, in: []))
    }

    func testMarkersLeaveOutTheFirstChapter() {
        let chapters = [chapter(0, "A", 0, 90), chapter(1, "B", 90, 600), chapter(2, "C", 600, 1200)]
        XCTAssertEqual(PlaybackChapters.markers(chapters, duration: 1200), [0.075, 0.5])
        XCTAssertEqual(PlaybackChapters.markers([chapter(0, "A", 0, 1200)], duration: 1200), [])
        XCTAssertEqual(PlaybackChapters.markers(chapters, duration: 0), [])
    }

    func testChapterNamesForOpeningAndEnding() {
        for name in ["Opening", "OP", "OP2", "op 2", "Intro", "Opening Credits", "Opening Song", "OP - 1"] {
            XCTAssertEqual(PlaybackChapters.kind(ofName: name), .opening, name)
        }
        for name in ["Ending", "ED", "ED1", "Credits", "End Credits", "Outro", "Ending Song"] {
            XCTAssertEqual(PlaybackChapters.kind(ofName: name), .ending, name)
        }
        for name in ["Part A", "Prologue", "Preview", "Chapter 3", "Opera", "Edge", "Intro Scene", "Avant", ""] {
            XCTAssertNil(PlaybackChapters.kind(ofName: name), name)
        }
    }

    func testSkipOnlyFromShortNamedChapters() {
        let anime = [
            chapter(0, "Prologue", 0, 75),
            chapter(1, "Opening", 75, 165),
            chapter(2, "Part A", 165, 700),
            chapter(3, "Ending", 1290, 1380),
            chapter(4, "Preview", 1380, 1420),
        ]
        let intervals = PlaybackChapters.skipIntervals(from: anime)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertTrue(intervals[0].isIntro)
        XCTAssertEqual(intervals[0].startTime, 75)
        XCTAssertEqual(intervals[0].endTime, 165)
        XCTAssertTrue(intervals[1].isEnding)
        XCTAssertEqual(intervals[1].startTime, 1290)
        XCTAssertEqual(intervals[1].provider, "chapters")

        // Too long to be an opening, or too short to be one: no button.
        XCTAssertTrue(PlaybackChapters.skipIntervals(from: [chapter(0, "Intro", 0, 600)]).isEmpty)
        XCTAssertTrue(PlaybackChapters.skipIntervals(from: [chapter(0, "OP", 0, 5)]).isEmpty)
    }

    func testOpeningAndEndingOnTheTimeline() {
        let segments = PlaybackChapters.timelineSegments([
            SkipInterval(startTime: 60, endTime: 150, type: "intro", provider: "introdb"),
            SkipInterval(startTime: 0, endTime: 30, type: "recap", provider: "introdb"),
            SkipInterval(startTime: 1290, endTime: 1500, type: "outro", provider: "chapters"),
        ], duration: 1400)
        XCTAssertEqual(segments.map(\.kind), [.opening, .ending])
        XCTAssertEqual(segments[0].start, 60.0 / 1400, accuracy: 0.0001)
        XCTAssertEqual(segments[0].end, 150.0 / 1400, accuracy: 0.0001)
        // Past the end of the video: cut at the end.
        XCTAssertEqual(segments[1].end, 1)
        XCTAssertTrue(PlaybackChapters.timelineSegments(
            [SkipInterval(startTime: 60, endTime: 150, type: "intro", provider: "introdb")], duration: 0
        ).isEmpty)
    }

    func testChapterBadgeFromNameOrFromTheMatchingSegment() {
        let introDB = [SkipInterval(startTime: 61, endTime: 151, type: "intro", provider: "introdb")]
        XCTAssertEqual(PlaybackChapters.kind(of: chapter(0, "Opening", 300, 390), segments: []), .opening)
        XCTAssertEqual(PlaybackChapters.kind(of: chapter(1, "Chapter 2", 60, 150), segments: introDB), .opening)
        XCTAssertNil(PlaybackChapters.kind(of: chapter(2, "Chapter 3", 150, 600), segments: introDB))
    }

    func testThumbnailIsAFewSecondsIntoTheChapter() {
        XCTAssertEqual(PlaybackChapters.thumbnailTime(for: chapter(0, "A", 100, 400)), 105)
        XCTAssertEqual(PlaybackChapters.thumbnailTime(for: chapter(1, "B", 100, 108)), 102)
        XCTAssertEqual(PlaybackChapters.thumbnailTime(for: chapter(2, "C", 100, 100)), 100)
    }

    func testALengthThatMovesSlightlyKeepsTheSameChapterList() {
        let items: [(id: Int, name: String, start: Double, duration: Double)] = [
            (id: 0, name: "Opening", start: 0, duration: 0),
            (id: 1, name: "Part A", start: 90, duration: 0),
        ]
        let first = PlaybackChapters.chapters(from: items, totalDuration: 1420.0)
        let moved = PlaybackChapters.chapters(from: items, totalDuration: 1420.4)
        XCTAssertNotEqual(first, moved)
        XCTAssertTrue(PlaybackChapters.isSameList(first, moved))
        let renamed = PlaybackChapters.chapters(
            from: [(id: 0, name: "OP", start: 0, duration: 0), (id: 1, name: "Part A", start: 90, duration: 0)],
            totalDuration: 1420.0)
        XCTAssertFalse(PlaybackChapters.isSameList(first, renamed))
        XCTAssertFalse(PlaybackChapters.isSameList(first, Array(first.prefix(1))))
    }

    func testTheFocusedChapterLoadsNextThenTheClosest() {
        XCTAssertEqual(PlaybackChapters.nextThumbnailIndex(missing: [0, 3, 7, 12], anchor: 7), 7)
        XCTAssertEqual(PlaybackChapters.nextThumbnailIndex(missing: [0, 5, 9, 12], anchor: 7), 9, "a tie goes to the later chapter")
        XCTAssertEqual(PlaybackChapters.nextThumbnailIndex(missing: [0, 2, 30], anchor: 20), 30)
        XCTAssertNil(PlaybackChapters.nextThumbnailIndex(missing: [], anchor: 4))
    }

    func testThumbnailsLoadFromThePlayingChapterOutward() {
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 6, from: 2), [2, 3, 1, 4, 0, 5])
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 4, from: 0), [0, 1, 2, 3])
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 3, from: 9), [2, 1, 0])
        XCTAssertEqual(PlaybackChapters.thumbnailOrder(count: 0, from: 0), [])
    }

    func testIntroDBComesFirstAndChaptersFillTheRest() {
        let introDB = [SkipInterval(startTime: 80, endTime: 168, type: "intro", provider: "introdb")]
        let fromChapters = [
            SkipInterval(startTime: 75, endTime: 165, type: "intro", provider: "chapters"),
            SkipInterval(startTime: 1290, endTime: 1380, type: "outro", provider: "chapters"),
        ]
        let merged = PlaybackChapters.merged(introDB: introDB, chapters: fromChapters)
        XCTAssertEqual(merged.map(\.provider), ["introdb", "chapters"])
        XCTAssertEqual(merged.map(\.startTime), [80, 1290])
        XCTAssertEqual(PlaybackChapters.merged(introDB: [], chapters: fromChapters), fromChapters)
        XCTAssertEqual(PlaybackChapters.merged(introDB: introDB, chapters: []), introDB)
    }
}
