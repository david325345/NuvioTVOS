import XCTest
@testable import CalendarCore

// MARK: - Helpers

final class MockHTTP: HTTPClient, @unchecked Sendable {
    /// path fragment → (status, json body). Longest matching fragment wins.
    var routes: [String: (Int, String)]
    private let lock = NSLock()
    private(set) var requested: [URL] = []

    init(_ routes: [String: (Int, String)]) { self.routes = routes }

    func get(_ url: URL) async throws -> (Data, Int) {
        lock.lock(); requested.append(url); lock.unlock()
        let path = url.path
        let match = routes.keys
            .filter { path.hasSuffix($0) }
            .max { $0.count < $1.count }
        guard let key = match, let route = routes[key] else {
            return (Data("{}".utf8), 404)
        }
        return (Data(route.1.utf8), route.0)
    }

    func count(containing fragment: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requested.filter { $0.path.contains(fragment) }.count
    }
}

let today = DayKey(year: 2026, month: 10, day: 19)
let lastDay = today.adding(days: 90)

func ep(_ season: Int, _ number: Int, _ date: String?, type: String? = nil) -> TmdbEpisode {
    TmdbEpisode(airDate: date, episodeNumber: number, seasonNumber: season, name: "E\(number)", episodeType: type)
}

// MARK: - DayKey

final class DayKeyTests: XCTestCase {
    func testParsesPlainAndIsoDates() {
        XCTAssertEqual(DayKey(iso: "2026-10-19"), today)
        XCTAssertEqual(DayKey(iso: "2026-10-30T00:00:00.000Z"), DayKey(year: 2026, month: 10, day: 30))
        XCTAssertNil(DayKey(iso: ""))
        XCTAssertNil(DayKey(iso: nil))
        XCTAssertNil(DayKey(iso: "2026-02-30"))
        XCTAssertNil(DayKey(iso: "garbage!!!"))
    }

    func testAddingDaysCrossesMonthsAndYears() {
        XCTAssertEqual(today.adding(days: 90), DayKey(year: 2027, month: 1, day: 17))
        XCTAssertEqual(DayKey(year: 2026, month: 12, day: 31).adding(days: 1), DayKey(year: 2027, month: 1, day: 1))
        XCTAssertEqual(today.days(until: today.adding(days: 90)), 90)
    }

    func testDayOfDateUsesGivenTimeZone() {
        // 2026-10-19 23:30 UTC is already the 20th in Prague.
        let date = ISO8601DateFormatter().date(from: "2026-10-19T23:30:00Z")!
        XCTAssertEqual(DayKey(date: date, timeZone: TimeZone(identifier: "UTC")!), today)
        XCTAssertEqual(DayKey(date: date, timeZone: TimeZone(identifier: "Europe/Prague")!), today.adding(days: 1))
    }
}

// MARK: - Id resolution

final class IdResolverTests: XCTestCase {
    func testDirectIds() {
        XCTAssertEqual(IdResolver.directTmdbId(from: "tmdb:1396"), 1396)
        XCTAssertEqual(IdResolver.directTmdbId(from: "TMDB:1396:1:2"), 1396)
        XCTAssertEqual(IdResolver.directTmdbId(from: "1396"), 1396)
        XCTAssertNil(IdResolver.directTmdbId(from: "tmdb:abc"))
        XCTAssertNil(IdResolver.directTmdbId(from: "tt0903747"))
        XCTAssertEqual(IdResolver.imdbId(from: "tt0903747:1:2"), "tt0903747")
        XCTAssertNil(IdResolver.imdbId(from: "kitsu:123"))
        XCTAssertNil(IdResolver.imdbId(from: "tt"))
    }

    func testImdbLookupIsCached() async throws {
        let http = MockHTTP(["/find/tt0903747": (200, #"{"movie_results":[],"tv_results":[{"id":1396}]}"#)])
        let resolver = IdResolver(client: TmdbClient(apiKey: "k", http: http))
        let item = LibraryItem(id: "tt0903747", kind: .series)
        let first = try await resolver.resolve(item)
        let second = try await resolver.resolve(item)
        XCTAssertEqual(first, .resolved(1396))
        XCTAssertEqual(second, .resolved(1396))
        XCTAssertEqual(http.count(containing: "/find/"), 1)
    }

    func testUnsupportedAndNotFound() async throws {
        let http = MockHTTP(["/find/tt0000001": (200, #"{"movie_results":[],"tv_results":[]}"#)])
        let resolver = IdResolver(client: TmdbClient(apiKey: "k", http: http))
        let kitsu = try await resolver.resolve(LibraryItem(id: "kitsu:42", kind: .series))
        let missing = try await resolver.resolve(LibraryItem(id: "tt0000001", kind: .series))
        XCTAssertEqual(kitsu, .unsupported)
        XCTAssertEqual(missing, .notFound)
    }
}

// MARK: - Series building

final class SeriesBuilderTests: XCTestCase {
    func testSeasonsToFetch() {
        let details = TmdbTvDetails(
            id: 1, name: "Show",
            nextEpisodeToAir: ep(2, 5, "2026-10-25"),
            seasons: [
                TmdbSeasonSummary(seasonNumber: 0, airDate: "2026-11-01"),   // specials ignored
                TmdbSeasonSummary(seasonNumber: 1, airDate: "2024-01-01"),   // old
                TmdbSeasonSummary(seasonNumber: 2, airDate: "2026-09-01"),
                TmdbSeasonSummary(seasonNumber: 3, airDate: "2026-12-20"),   // premieres in window
                TmdbSeasonSummary(seasonNumber: 4, airDate: "2027-06-01"),   // outside window
            ]
        )
        XCTAssertEqual(CalendarBuilder.seasonsToFetch(for: details, today: today, lastDay: lastDay), [2, 3])
    }

    func testNextEpisodeBeyondWindowFetchesNothing() {
        let details = TmdbTvDetails(id: 1, name: "Show", nextEpisodeToAir: ep(5, 1, "2027-05-01"))
        XCTAssertEqual(CalendarBuilder.seasonsToFetch(for: details, today: today, lastDay: lastDay), [])
    }

    func testEpisodeWindowIsInclusiveAndSkipsUndated() {
        let item = LibraryItem(id: "tt1", kind: .series)
        let details = TmdbTvDetails(id: 7, name: "Show", posterPath: "/p.jpg")
        let episodes = [
            ep(2, 1, "2026-10-18"),            // yesterday
            ep(2, 2, "2026-10-19"),            // today
            ep(2, 3, lastDay.iso),             // last day
            ep(2, 4, lastDay.adding(days: 1).iso),
            ep(2, 5, nil),                     // no date yet
            ep(2, 2, "2026-10-19"),            // duplicate
        ]
        let entries = CalendarBuilder.episodeEntries(item: item, details: details, episodes: episodes, today: today, lastDay: lastDay)
        XCTAssertEqual(entries.map(\.episodeNumber), [2, 3])
        XCTAssertEqual(entries.first?.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w342/p.jpg")
    }

    func testReleaseKinds() {
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(1, 1, nil), season: 1, number: 1), .seriesPremiere)
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(3, 1, nil), season: 3, number: 1), .seasonPremiere)
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(3, 8, nil, type: "finale"), season: 3, number: 8), .seasonFinale)
        XCTAssertEqual(CalendarBuilder.releaseKind(for: ep(3, 4, nil, type: "standard"), season: 3, number: 4), .episode)
    }

    func testGroupingSortsDaysAndTitles() {
        let a = CalendarEntry(itemId: "a", kind: .series, tmdbId: 1, title: "Zeta", date: today.adding(days: 1), releaseKind: .episode, seasonNumber: 1, episodeNumber: 2)
        let b = CalendarEntry(itemId: "b", kind: .series, tmdbId: 2, title: "alpha", date: today.adding(days: 1), releaseKind: .episode, seasonNumber: 1, episodeNumber: 1)
        let c = CalendarEntry(itemId: "c", kind: .movie, tmdbId: 3, title: "Film", date: today, releaseKind: .digital)
        let d = CalendarEntry(itemId: "b", kind: .series, tmdbId: 2, title: "alpha", date: today.adding(days: 1), releaseKind: .episode, seasonNumber: 1, episodeNumber: 2)
        let days = CalendarBuilder.groupByDay([a, d, b, c])
        XCTAssertEqual(days.map(\.date), [today, today.adding(days: 1)])
        XCTAssertEqual(days[1].entries.map(\.itemId), ["b", "b", "a"])
        XCTAssertEqual(days[1].entries.map(\.episodeNumber), [1, 2, 2])
    }
}

// MARK: - Movie building

final class MovieBuilderTests: XCTestCase {
    let item = LibraryItem(id: "tmdb:9", kind: .movie)

    func testUsesRegionReleases() {
        let details = TmdbMovieDetails(id: 9, title: "Film", releaseDate: "2026-11-01", countries: [
            TmdbCountryReleases(country: "CZ", releaseDates: [
                TmdbReleaseDate(releaseDate: "2026-11-05T00:00:00.000Z", type: 3),
                TmdbReleaseDate(releaseDate: "2026-12-20T00:00:00.000Z", type: 4),
                TmdbReleaseDate(releaseDate: "2026-10-01T00:00:00.000Z", type: 1),   // festival premiere, ignored
            ]),
            TmdbCountryReleases(country: "US", releaseDates: [
                TmdbReleaseDate(releaseDate: "2026-10-30T00:00:00.000Z", type: 3),
            ]),
        ])
        let entries = CalendarBuilder.movieEntries(item: item, details: details, region: "CZ", today: today, lastDay: lastDay)
        XCTAssertEqual(entries.map(\.releaseKind), [.theatrical, .digital])
        XCTAssertEqual(entries.map(\.date.iso), ["2026-11-05", "2026-12-20"])
    }

    func testFallsBackToUSThenPrimaryDate() {
        let us = TmdbMovieDetails(id: 9, title: "Film", releaseDate: "2026-11-01", countries: [
            TmdbCountryReleases(country: "US", releaseDates: [TmdbReleaseDate(releaseDate: "2026-11-20T00:00:00.000Z", type: 4)]),
        ])
        XCTAssertEqual(
            CalendarBuilder.movieEntries(item: item, details: us, region: "CZ", today: today, lastDay: lastDay).map(\.releaseKind),
            [.digital]
        )

        let bare = TmdbMovieDetails(id: 9, title: "Film", releaseDate: "2026-11-01")
        let entries = CalendarBuilder.movieEntries(item: item, details: bare, region: "CZ", today: today, lastDay: lastDay)
        XCTAssertEqual(entries.map(\.releaseKind), [.release])
        XCTAssertEqual(entries.first?.date.iso, "2026-11-01")
    }

    func testPastReleasesAreHidden() {
        let details = TmdbMovieDetails(id: 9, title: "Film", releaseDate: "2025-01-01", countries: [
            TmdbCountryReleases(country: "CZ", releaseDates: [TmdbReleaseDate(releaseDate: "2025-02-01T00:00:00.000Z", type: 3)]),
        ])
        XCTAssertTrue(CalendarBuilder.movieEntries(item: item, details: details, region: "CZ", today: today, lastDay: lastDay).isEmpty)
    }
}

// MARK: - Decoding real-shaped payloads

final class DecodingTests: XCTestCase {
    func testDecodesTvDetails() throws {
        let json = #"""
        {"id":1396,"name":"Breaking Bad","poster_path":"/x.jpg","status":"Returning Series",
         "next_episode_to_air":{"air_date":"2026-10-25","episode_number":5,"season_number":2,"name":"Ep","overview":"","still_path":null,"episode_type":"standard","id":1,"vote_average":0},
         "last_episode_to_air":null,
         "seasons":[{"air_date":"2026-09-01","episode_count":10,"season_number":2,"id":5,"name":"S2"}],
         "unknown_field":true}
        """#
        let details = try JSONDecoder().decode(TmdbTvDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.nextEpisodeToAir?.episodeNumber, 5)
        XCTAssertEqual(details.seasons?.first?.seasonNumber, 2)
        XCTAssertNil(details.lastEpisodeToAir)
    }

    func testDecodesMovieWithReleaseDates() throws {
        let json = #"""
        {"id":9,"title":"Film","release_date":"2026-11-01","status":"Post Production","overview":"x","poster_path":null,
         "release_dates":{"results":[{"iso_3166_1":"CZ","release_dates":[{"certification":"","iso_639_1":"","note":"","release_date":"2026-11-05T00:00:00.000Z","type":3}]}]}}
        """#
        let details = try JSONDecoder().decode(TmdbMovieDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.releaseDates?.results?.first?.releaseDates?.first?.type, 3)
    }
}

// MARK: - Service

final class CalendarServiceTests: XCTestCase {
    func service(_ http: MockHTTP) -> CalendarService {
        CalendarService(client: TmdbClient(apiKey: "k", http: http), maxConcurrent: 2, region: "CZ")
    }

    func testLoadsShowsMoviesAndReportsSkips() async throws {
        let http = MockHTTP([
            "/find/tt0903747": (200, #"{"movie_results":[],"tv_results":[{"id":1396}]}"#),
            "/tv/1396": (200, #"{"id":1396,"name":"Show A","next_episode_to_air":{"air_date":"2026-10-20","episode_number":3,"season_number":2},"seasons":[{"season_number":2,"air_date":"2026-10-06"}]}"#),
            "/tv/1396/season/2": (200, #"{"episodes":[{"air_date":"2026-10-13","episode_number":2,"season_number":2},{"air_date":"2026-10-20","episode_number":3,"season_number":2},{"air_date":"2026-10-27","episode_number":4,"season_number":2,"episode_type":"finale"}]}"#),
            "/tv/2": (200, #"{"id":2,"name":"Ended","status":"Ended","next_episode_to_air":null,"seasons":[]}"#),
            "/tv/3": (500, "oops"),
            "/movie/9": (200, #"{"id":9,"title":"Film","release_date":"2026-11-01","release_dates":{"results":[]}}"#),
        ])
        let items = [
            LibraryItem(id: "tt0903747", kind: .series),
            LibraryItem(id: "tmdb:1396", kind: .series),   // duplicate of the first
            LibraryItem(id: "tmdb:2", kind: .series),
            LibraryItem(id: "tmdb:3", kind: .series),
            LibraryItem(id: "kitsu:5", kind: .series),
            LibraryItem(id: "tmdb:9", kind: .movie),
        ]
        let result = try await service(http).load(items: items, today: today)

        XCTAssertEqual(result.days.map(\.date.iso), ["2026-10-20", "2026-10-27", "2026-11-01"])
        XCTAssertEqual(result.days[1].entries.first?.releaseKind, .seasonFinale)
        XCTAssertEqual(result.entryCount, 3)

        let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.item.id, $0.reason) })
        XCTAssertEqual(reasons["tmdb:2"], .nothingUpcoming)
        XCTAssertEqual(reasons["tmdb:3"], .failed("HTTP 500"))
        XCTAssertEqual(reasons["kitsu:5"], .unsupportedId)
        XCTAssertNil(reasons["tmdb:1396"], "duplicate is dropped silently")
        XCTAssertEqual(http.count(containing: "/tv/1396/season/2"), 1)
    }

    func testInvalidKeyFailsWholeLoad() async {
        let http = MockHTTP(["/tv/1": (401, #"{"status_code":7}"#)])
        do {
            _ = try await service(http).load(items: [LibraryItem(id: "tmdb:1", kind: .series)], today: today)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? CalendarLoadError, .invalidApiKey)
        }
    }

    func testMissingKey() async {
        let s = CalendarService(client: TmdbClient(apiKey: "  ", http: MockHTTP([:])))
        do {
            _ = try await s.load(items: [], today: today)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? CalendarLoadError, .missingApiKey)
        }
    }

    func testSeasonPageFailureFallsBackToNextEpisode() async throws {
        let http = MockHTTP([
            "/tv/4": (200, #"{"id":4,"name":"Show","next_episode_to_air":{"air_date":"2026-10-22","episode_number":7,"season_number":1}}"#),
            "/tv/4/season/1": (500, ""),
        ])
        let result = try await service(http).load(items: [LibraryItem(id: "tmdb:4", kind: .series)], today: today)
        XCTAssertEqual(result.days.first?.entries.first?.episodeNumber, 7)
    }

    func testConcurrentMapKeepsOrder() async {
        let s = service(MockHTTP([:]))
        let out = await s.concurrentMap(Array(0..<20)) { value -> Int in
            try? await Task.sleep(nanoseconds: UInt64((20 - value) * 1_000_000))
            return value * 2
        }
        XCTAssertEqual(out, (0..<20).map { $0 * 2 })
    }
}
