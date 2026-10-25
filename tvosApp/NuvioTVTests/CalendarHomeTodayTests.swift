import Foundation
import XCTest
@testable import NuvioTV

private let homeToday = CalendarDay(year: 2026, month: 10, day: 25)

private func makeEntry(
    _ itemId: String,
    kind: CalendarMediaKind = .series,
    tmdbId: Int,
    release: CalendarReleaseKind = .episode,
    season: Int? = 1,
    episode: Int? = 1,
    airTime: Date? = nil,
    on day: CalendarDay = homeToday
) -> CalendarEntry {
    var entry = CalendarEntry(
        itemId: itemId,
        itemType: kind == .series ? "series" : "movie",
        kind: kind,
        tmdbId: tmdbId,
        title: "Title \(itemId)",
        date: day,
        releaseKind: release,
        seasonNumber: kind == .series ? season : nil,
        episodeNumber: kind == .series ? episode : nil,
        episodeName: kind == .series ? "Episode name" : nil,
        posterURL: URL(string: "https://img/\(itemId).jpg"),
        stillURL: kind == .series ? URL(string: "https://img/\(itemId)-still.jpg") : nil
    )
    entry.airTime = airTime
    return entry
}

private func makeResult(_ entries: [CalendarEntry]) -> CalendarResult {
    let days = Dictionary(grouping: entries, by: \.date)
        .map { CalendarDaySection(date: $0.key, entries: $0.value) }
        .sorted { $0.date < $1.date }
    return CalendarResult(
        firstDay: homeToday.adding(days: -30),
        lastDay: homeToday.adding(days: 60),
        days: days,
        skipped: []
    )
}

final class CalendarHomeTodayTests: XCTestCase {
    private let time: (Date) -> String = { _ in "21:00" }

    func testOneCardPerTitleInTheCalendarsOrder() {
        let at = Date(timeIntervalSince1970: 1_792_950_000)
        let row = CalendarHomeToday.build(
            from: makeResult([
                makeEntry("tt1", tmdbId: 1, episode: 5, airTime: at),
                // The second half of a double episode.
                makeEntry("tt1", tmdbId: 1, episode: 6, airTime: at),
                makeEntry("kitsu:7", tmdbId: 7, season: 2, episode: 3),
                makeEntry("tt9", kind: .movie, tmdbId: 9, release: .digital),
                makeEntry("tt8", tmdbId: 8, on: homeToday.adding(days: 1)),
            ]),
            today: homeToday,
            hideSpoilers: false,
            time: time
        )
        XCTAssertEqual(row.metas.map(\.id), ["tt1", "kitsu:7", "tt9"])
        XCTAssertEqual(row.entries["tt1"]?.episodeNumber, 5)

        XCTAssertEqual(row.labels["tt1"], .init(
            episode: "S1E5", episodeTitle: "Episode name", badge: "21:00", artworkURL: "https://img/tt1-still.jpg"
        ))
        XCTAssertEqual(row.labels["kitsu:7"]?.episode, "S2E3")
        XCTAssertEqual(row.labels["kitsu:7"]?.badge, "AIRING TODAY")
        XCTAssertNil(row.labels["tt9"]?.episode)
        XCTAssertEqual(row.labels["tt9"]?.badge, CalendarFormat.releaseLabel(.digital))
    }

    func testCardsOpenTheLibraryTitle() {
        let row = CalendarHomeToday.build(
            from: makeResult([makeEntry("tt1", tmdbId: 1), makeEntry("tt9", kind: .movie, tmdbId: 9, release: .digital)]),
            today: homeToday,
            hideSpoilers: false,
            time: time
        )
        let series = row.metas[0]
        XCTAssertEqual(series.type, "series")
        XCTAssertEqual(series.imdbId, "tt1")
        XCTAssertEqual(series.tmdbId, 1)
        XCTAssertEqual(series.posterUrl, "https://img/tt1.jpg")
        // The episode's picture stays on the card, not in the hero.
        XCTAssertNil(series.backgroundUrl)
        XCTAssertEqual(row.metas[1].type, "movie")
    }

    func testCinemaReleasesAreLeftOut() {
        let row = CalendarHomeToday.build(
            from: makeResult([makeEntry("tt9", kind: .movie, tmdbId: 9, release: .theatrical)]),
            today: homeToday,
            hideSpoilers: false,
            time: time
        )
        XCTAssertTrue(row.isEmpty)
    }

    func testHiddenSpoilersDropTheEpisodesNameAndPicture() {
        let row = CalendarHomeToday.build(
            from: makeResult([makeEntry("tt1", tmdbId: 1)]),
            today: homeToday,
            hideSpoilers: true,
            time: time
        )
        XCTAssertEqual(row.labels["tt1"]?.episode, "S1E1")
        XCTAssertNil(row.labels["tt1"]?.episodeTitle)
        XCTAssertNil(row.labels["tt1"]?.artworkURL)
    }

    func testNoCalendarMeansNoRow() {
        XCTAssertTrue(CalendarHomeToday.build(from: nil, today: homeToday, hideSpoilers: false, time: time).isEmpty)
    }

    func testWaitsUntilJustAfterMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Prague"))
        let lateEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 50)))
        XCTAssertEqual(CalendarHomeToday.secondsUntilTomorrow(from: lateEvening, calendar: calendar), 605, accuracy: 0.001)
        let almostMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 59, second: 59)))
        XCTAssertEqual(CalendarHomeToday.secondsUntilTomorrow(from: almostMidnight, calendar: calendar), 60, accuracy: 0.001)
        // The night the clocks go back has 25 hours.
        let dstNight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 0)))
        XCTAssertEqual(CalendarHomeToday.secondsUntilTomorrow(from: dstNight, calendar: calendar), 25 * 3600 + 5, accuracy: 0.001)
    }
}

final class CalendarSnapshotTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-snapshot-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func sample() -> CalendarResult {
        var timed = makeEntry("tt1", tmdbId: 1, airTime: Date(timeIntervalSince1970: 1_792_950_000))
        timed.airTimeSource = .tvmaze
        timed.isAnime = true
        var result = makeResult([timed, makeEntry("tt9", kind: .movie, tmdbId: 9, release: .digital)])
        result = CalendarResult(
            firstDay: result.firstDay,
            lastDay: result.lastDay,
            days: result.days,
            skipped: [
                CalendarSkippedItem(item: CalendarItem(id: "x:1", kind: .series), reason: .unsupportedId),
                CalendarSkippedItem(item: CalendarItem(id: "tt5", kind: .movie, name: "Five"), reason: .failed("timeout")),
            ],
            libraryKeys: ["series:1", "movie:9"],
            libraryItems: ["series:1": CalendarItem(id: "tt1", kind: .series, type: "series", name: "One")]
        )
        return result
    }

    func testRoundTrip() async throws {
        let store = CalendarSnapshotStore(url: url)
        let loadedAt = Date(timeIntervalSince1970: 1_792_900_000)
        let snapshot = CalendarSnapshot(settings: "profile|key", day: homeToday, loadedAt: loadedAt, result: sample())
        await store.write(snapshot, sequence: 1)

        let stored = await CalendarSnapshotStore(url: url).read()
        let read = try XCTUnwrap(stored)
        XCTAssertEqual(read.day, homeToday)
        XCTAssertEqual(read.loadedAt, loadedAt)
        XCTAssertEqual(read.result.days, sample().days)
        XCTAssertEqual(read.result.skipped, sample().skipped)
        XCTAssertEqual(read.result.libraryKeys, ["series:1", "movie:9"])
        XCTAssertEqual(read.result.libraryItems["series:1"]?.name, "One")
        XCTAssertEqual(read.result.allEntries.first?.airTimeSource, .tvmaze)
    }

    func testSettingsAreNeverWrittenAsTheyAre() throws {
        let snapshot = CalendarSnapshot(settings: "profile|secret-tmdb-key", day: homeToday, loadedAt: Date(), result: sample())
        let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(text.contains("secret-tmdb-key"))
        XCTAssertEqual(snapshot.settingsDigest.count, 64)
    }

    func testOnlyARecentSnapshotWithTheSameSettingsIsUsed() {
        let now = Date(timeIntervalSince1970: 1_792_950_000)
        func snapshot(age: TimeInterval) -> CalendarSnapshot {
            CalendarSnapshot(settings: "a", day: homeToday, loadedAt: now.addingTimeInterval(-age), result: sample())
        }
        XCTAssertTrue(snapshot(age: 3600).isUsable(settings: "a", now: now))
        XCTAssertFalse(snapshot(age: 3600).isUsable(settings: "b", now: now))
        XCTAssertFalse(snapshot(age: CalendarSnapshot.maxAge + 1).isUsable(settings: "a", now: now))
        // Made "in the future": the clock was set back.
        XCTAssertFalse(snapshot(age: -3600).isUsable(settings: "a", now: now))
        var old = snapshot(age: 60)
        old.version = CalendarSnapshot.currentVersion + 1
        XCTAssertFalse(old.isUsable(settings: "a", now: now))
    }

    func testAnOlderSaveDoesNotReplaceANewerOne() async throws {
        let store = CalendarSnapshotStore(url: url)
        let newer = CalendarSnapshot(settings: "a", day: homeToday, loadedAt: Date(timeIntervalSince1970: 2), result: sample())
        let older = CalendarSnapshot(settings: "a", day: homeToday, loadedAt: Date(timeIntervalSince1970: 1), result: sample())
        await store.write(newer, sequence: 2)
        await store.write(older, sequence: 1)
        let stored = await store.read()
        let read = try XCTUnwrap(stored)
        XCTAssertEqual(read.loadedAt, Date(timeIntervalSince1970: 2))
    }

    func testMissingOrBrokenFileReadsAsNothing() async throws {
        let store = CalendarSnapshotStore(url: url)
        let missing = await store.read()
        XCTAssertNil(missing)
        try Data("{".utf8).write(to: url)
        let broken = await store.read()
        XCTAssertNil(broken)
    }
}
