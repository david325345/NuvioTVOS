import XCTest
@testable import NuvioTV

final class AniListTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func page(_ json: String) throws -> [AniListMedia] {
        try XCTUnwrap(decoder.decode(AniListPageResponse.self, from: Data(json.utf8)).data?.Page?.media)
    }

    /// Season 1 (TV) → Season 2 (TV) → Season 3 (TV, not fetched yet), with an OVA, a film
    /// and the manga around them.
    private let franchise = """
    {"data":{"Page":{"media":[
      {"id":101,"type":"ANIME","format":"TV","status":"FINISHED","episodes":2,"seasonYear":2020,
       "title":{"romaji":"Kaiju Sentai","english":"Monster Squad","native":"怪獣戦隊"},
       "coverImage":{"extraLarge":"https://img/101.jpg"},"bannerImage":"https://img/101b.jpg",
       "description":"A squad.<br><br><i>(Source: AniList)</i> &amp; more","averageScore":82,"genres":["Action"],
       "startDate":{"year":2020,"month":4,"day":3},"endDate":{"year":2020,"month":6,"day":19},"duration":24,
       "trailer":{"id":"abc123","site":"youtube"},
       "airingSchedule":{"nodes":[{"episode":1,"airingAt":1585900800},{"episode":2,"airingAt":1586505600}]},
       "streamingEpisodes":[{"title":"Episode 2 - The Return","thumbnail":"https://img/e2.jpg"},{"title":"Episode 1 - The Squad","thumbnail":"https://img/e1.jpg"}],
       "relations":{"edges":[
         {"relationType":"SEQUEL","node":{"id":102,"type":"ANIME","format":"TV","startDate":{"year":2021,"month":1}}},
         {"relationType":"SIDE_STORY","node":{"id":150,"type":"ANIME","format":"OVA","seasonYear":2020,"title":{"romaji":"Kaiju Sentai OVA"},"startDate":{"year":2020,"month":9}}},
         {"relationType":"ADAPTATION","node":{"id":900,"type":"MANGA","format":"MANGA","title":{"romaji":"Kaiju Sentai"}}}
       ]}},
      {"id":102,"type":"ANIME","format":"TV","status":"FINISHED","episodes":3,"seasonYear":2021,
       "title":{"romaji":"Kaiju Sentai 2nd Season"},"coverImage":{"large":"https://img/102.jpg"},
       "startDate":{"year":2021,"month":1,"day":8},"endDate":{"year":2021,"month":3,"day":26},
       "relations":{"edges":[
         {"relationType":"PREQUEL","node":{"id":101,"type":"ANIME","format":"TV","startDate":{"year":2020,"month":4}}},
         {"relationType":"SEQUEL","node":{"id":103,"type":"ANIME","format":"TV","startDate":{"year":2023,"month":7}}},
         {"relationType":"SEQUEL","node":{"id":160,"type":"ANIME","format":"MOVIE","seasonYear":2022,"title":{"romaji":"Kaiju Sentai: The Movie"},"startDate":{"year":2022,"month":5}}}
       ]}}
    ]}}}
    """

    private func entries() throws -> [Int: AniListMedia] {
        Dictionary(uniqueKeysWithValues: try page(franchise).map { ($0.id, $0) })
    }

    // MARK: Ids

    func testTheAniListIDIsReadFromTitleAndEpisodeIDs() {
        XCTAssertEqual(AniListMetaBuilder.aniListID(from: "anilist:154587"), 154587)
        XCTAssertEqual(AniListMetaBuilder.aniListID(from: "anilist:154587:5"), 154587)
        XCTAssertEqual(AniListMetaBuilder.aniListID(from: " ANILIST:12 "), 12)
        XCTAssertNil(AniListMetaBuilder.aniListID(from: "tt0903747"))
        XCTAssertNil(AniListMetaBuilder.aniListID(from: "anilist:"))
        XCTAssertNil(AniListMetaBuilder.aniListID(from: "kitsu:12"))
        XCTAssertEqual(AniListMetaBuilder.episodeID(entry: 182255, episode: 5), "anilist:182255:5")
    }

    // MARK: Text

    func testTitlesFollowTheChosenLanguageWithFallbacks() {
        let full = AniListTitle(romaji: "Sousou no Frieren", english: "Frieren: Beyond Journey's End", native: "葬送のフリーレン")
        XCTAssertEqual(AniListMetaBuilder.title(full, language: .romaji), "Sousou no Frieren")
        XCTAssertEqual(AniListMetaBuilder.title(full, language: .english), "Frieren: Beyond Journey's End")
        XCTAssertEqual(AniListMetaBuilder.title(full, language: .native), "葬送のフリーレン")
        let romajiOnly = AniListTitle(romaji: "Kaiju Sentai", english: " ", native: nil)
        XCTAssertEqual(AniListMetaBuilder.title(romajiOnly, language: .english), "Kaiju Sentai")
        XCTAssertEqual(AniListMetaBuilder.title(nil, language: .romaji), "Unknown")
    }

    func testDescriptionsLoseTheirHTML() {
        XCTAssertEqual(
            AniListMetaBuilder.plainText("A squad.<br><br><i>(Source: AniList)</i> &amp; more"),
            "A squad.\n\n(Source: AniList) & more"
        )
        XCTAssertNil(AniListMetaBuilder.plainText("<br>"))
        XCTAssertNil(AniListMetaBuilder.plainText(nil))
    }

    // MARK: Franchise

    func testPrequelsAndSequelsBecomeTabsAndFilmsDoNot() throws {
        let entries = try entries()
        let fromSecond = AniListMetaBuilder.chain(from: 102, entries: entries)
        XCTAssertEqual(fromSecond.ids, [101, 102])
        XCTAssertEqual(fromSecond.missing, [103])

        let fromFirst = AniListMetaBuilder.chain(from: 101, entries: entries)
        XCTAssertEqual(fromFirst.ids, [101, 102])
        XCTAssertEqual(fromFirst.missing, [103])
    }

    func testAnOVAOrAFilmIsATitleOfItsOwn() throws {
        var entries = try entries()
        let ova = AniListMedia(id: 150, type: "ANIME", format: "OVA")
        entries[150] = ova
        XCTAssertEqual(AniListMetaBuilder.chain(from: 150, entries: entries).ids, [150])
        XCTAssertTrue(AniListMetaBuilder.chain(from: 150, entries: entries).missing.isEmpty)
    }

    // MARK: Episodes

    func testEpisodesKeepAniListNumbersAndTheirEntryID() throws {
        let second = try XCTUnwrap(try entries()[102])
        let episodes = AniListMetaBuilder.episodes(of: second, season: 2)
        XCTAssertEqual(episodes.map(\.id), ["anilist:102:1", "anilist:102:2", "anilist:102:3"])
        XCTAssertEqual(episodes.map(\.season), [2, 2, 2])
        XCTAssertEqual(episodes.map(\.episode), [1, 2, 3])
        XCTAssertEqual(episodes.first?.title, "Episode 1")
        XCTAssertEqual(episodes.first?.released, "2021-01-08T00:00:00Z")
    }

    func testEpisodeTitlesComeFromAniZipThenFromStreamingEpisodes() throws {
        let first = try XCTUnwrap(try entries()[101])
        let aniZip = ["2": AniZipEpisode(title: ["en": "Homecoming"], image: "https://zip/2.jpg", overview: "They return.")]
        let episodes = AniListMetaBuilder.episodes(of: first, season: 1, aniZip: aniZip)
        XCTAssertEqual(episodes.map(\.title), ["The Squad", "Homecoming"])
        XCTAssertEqual(episodes[0].thumbnail, "https://img/e1.jpg")
        XCTAssertEqual(episodes[1].thumbnail, "https://zip/2.jpg")
        XCTAssertEqual(episodes[1].overview, "They return.")
        XCTAssertEqual(episodes[0].released, AniListMetaBuilder.isoDate(airingAt: 1585900800))
    }

    func testAnAiringSeriesWithoutATotalShowsUpToTheNextEpisode() {
        let airing = AniListMedia(
            id: 300, type: "ANIME", format: "TV", status: "RELEASING",
            nextAiringEpisode: AniListAiring(episode: 6, airingAt: 1_900_000_000)
        )
        let episodes = AniListMetaBuilder.episodes(of: airing, season: 1, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(episodes.count, 6)
        XCTAssertEqual(episodes.last?.released, AniListMetaBuilder.isoDate(airingAt: 1_900_000_000))
    }

    func testAnAnnouncedTitleWithoutEpisodesHasNone() {
        let announced = AniListMedia(id: 301, type: "ANIME", format: "TV", status: "NOT_YET_RELEASED")
        XCTAssertTrue(AniListMetaBuilder.episodes(of: announced, season: 1).isEmpty)
    }

    func testStreamingEpisodeTitlesAreReadInAnyOrder() {
        let parsed = AniListMetaBuilder.streamingEpisodes([
            AniListStreamingEpisode(title: "Episode 12 - Finale", thumbnail: "t12"),
            AniListStreamingEpisode(title: "Episode 3", thumbnail: "t3"),
            AniListStreamingEpisode(title: "Recap", thumbnail: "x"),
        ])
        XCTAssertEqual(parsed[12]?.title, "Finale")
        XCTAssertNil(parsed[3]?.title ?? nil)
        XCTAssertEqual(parsed[3]?.thumbnail, "t3")
        XCTAssertEqual(parsed.count, 2)
    }

    // MARK: Titles

    func testOneTitleCarriesEveryTabAndAsksAddOnsWithAniListIDs() throws {
        let entries = try entries()
        let tabs = [try XCTUnwrap(entries[101]), try XCTUnwrap(entries[102])]
        let episodes: [Int: [NuvioVideo]] = [
            101: AniListMetaBuilder.episodes(of: tabs[0], season: 1),
            102: AniListMetaBuilder.episodes(of: tabs[1], season: 2),
        ]
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: tabs, episodes: episodes, language: .romaji))
        XCTAssertEqual(meta.id, "anilist:101")
        XCTAssertEqual(meta.type, "series")
        XCTAssertEqual(meta.name, "Kaiju Sentai")
        XCTAssertEqual(meta.releaseInfo, "2020–2021")
        XCTAssertEqual(meta.runtime, "24 min")
        XCTAssertEqual(meta.trailerYtIds, ["abc123"])
        XCTAssertNil(meta.imdbId)
        XCTAssertNil(meta.rating)
        XCTAssertEqual(meta.externalRatings?.first?.source, "anilist")
        XCTAssertEqual(meta.externalRatings?.first?.max, 100)
        XCTAssertEqual(meta.videos?.count, 5)
        XCTAssertTrue(meta.isAnime)

        XCTAssertEqual(meta.streamId, "anilist:101")
        let secondSeasonFirst = try XCTUnwrap(meta.videos?.first { $0.season == 2 && $0.episode == 1 })
        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: secondSeasonFirst), "anilist:102:1")

        XCTAssertEqual(AniListMetaBuilder.tabTitles(tabs, language: .romaji), [1: "Kaiju Sentai", 2: "Kaiju Sentai 2nd Season"])
    }

    func testAFilmIsAMovieWithoutAnEpisodeNumber() throws {
        let film = AniListMedia(id: 160, type: "ANIME", format: "MOVIE", status: "FINISHED", seasonYear: 2022,
                                title: AniListTitle(romaji: "Kaiju Sentai: The Movie"))
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: [film], episodes: [:], language: .romaji))
        XCTAssertEqual(meta.type, "movie")
        XCTAssertNil(meta.videos)
        XCTAssertEqual(meta.streamId, "anilist:160")
        XCTAssertEqual(meta.releaseInfo, "2022")
    }

    func testASingleEpisodeOVAIsASeriesWithEpisodeOne() throws {
        let ova = AniListMedia(id: 150, type: "ANIME", format: "OVA", status: "FINISHED", episodes: 1)
        let episodes = [150: AniListMetaBuilder.episodes(of: ova, season: 1)]
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: [ova], episodes: episodes, language: .romaji))
        XCTAssertEqual(meta.type, "series")
        let only = try XCTUnwrap(meta.videos?.first)
        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: only), "anilist:150:1")
    }

    func testAnEntryWhoseIDEqualsItsSeasonKeepsItsEpisodeID() throws {
        // Cowboy Bebop is AniList 1: "anilist:1:5" also ends in ":1:5" (season 1, episode 5).
        let bebop = AniListMedia(id: 1, type: "ANIME", format: "TV", status: "FINISHED", episodes: 26)
        let episodes = [1: AniListMetaBuilder.episodes(of: bebop, season: 1)]
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: [bebop], episodes: episodes, language: .romaji))
        let fifth = try XCTUnwrap(meta.videos?.first { $0.episode == 5 })
        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: fifth), "anilist:1:5")
    }

    func testTheRelatedRowSkipsTabsAndManga() throws {
        let entries = try entries()
        let tabs = [try XCTUnwrap(entries[101]), try XCTUnwrap(entries[102])]
        let related = AniListMetaBuilder.related(tabs: tabs, language: .romaji)
        XCTAssertEqual(related.map(\.id), ["anilist:160", "anilist:103", "anilist:150"])
        XCTAssertEqual(related.first?.type, "movie")
        XCTAssertEqual(related.first?.year, "Sequel · 2022")
        XCTAssertEqual(related.last?.year, "Side Story · 2020")
    }

    // MARK: Home, Search

    func testSeasonsFollowTheMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4))!
        XCTAssertEqual(AniListSeason.current(at: november, calendar: calendar).season, "FALL")
        XCTAssertEqual(AniListSeason.next(at: november, calendar: calendar).season, "WINTER")
        XCTAssertEqual(AniListSeason.next(at: november, calendar: calendar).year, 2027)
        let february = calendar.date(from: DateComponents(year: 2027, month: 2, day: 1))!
        XCTAssertEqual(AniListSeason.current(at: february, calendar: calendar).season, "WINTER")
        XCTAssertEqual(AniListSeason.next(at: february, calendar: calendar).season, "SPRING")
        XCTAssertEqual(AniListSeason.next(at: february, calendar: calendar).year, 2027)
    }

    func testTheHomeQueryDeclaresOnlyTheVariablesItsRowsUse() {
        let trendingOnly = AniListQueries.homeRows([AniListHomeRow.row(id: "trending")!])
        XCTAssertTrue(trendingOnly.contains("trending: Page"))
        XCTAssertFalse(trendingOnly.contains("$season"))
        XCTAssertFalse(trendingOnly.contains("$nextSeason"))

        let all = AniListQueries.homeRows(AniListHomeRow.all)
        XCTAssertTrue(all.contains("$season: MediaSeason"))
        XCTAssertTrue(all.contains("$nextSeason: MediaSeason"))
        XCTAssertEqual(AniListHomeRow.all.map(\.id), ["trending", "season", "nextseason", "popular", "top"])
    }

    func testCinemetaDuplicatesAreRecognisedByNameAndYear() {
        let result = AniListService.SearchResult(
            items: [],
            names: [(name: AniListService.matchKey("Sousou no Frieren"), year: 2023),
                    (name: AniListService.matchKey("Frieren: Beyond Journey's End"), year: 2023)]
        )
        XCTAssertTrue(result.matches(NuvioMeta(id: "tt22248376", name: "Frieren: Beyond Journey's End", type: "series", year: 2023)))
        XCTAssertTrue(result.matches(NuvioMeta(id: "tt22248376", name: "FRIEREN - beyond journeys end", type: "series", year: 2024)))
        XCTAssertFalse(result.matches(NuvioMeta(id: "tt1", name: "Frieren", type: "series", year: 2023)))
        XCTAssertFalse(result.matches(NuvioMeta(id: "tt2", name: "Sousou no Frieren", type: "series", year: 2010)))
    }

    func testCardsKeepTheirAniListIDAndScore() throws {
        let first = try XCTUnwrap(try entries()[101])
        let card = AniListMetaBuilder.card(first, language: .english)
        XCTAssertEqual(card.id, "anilist:101")
        XCTAssertEqual(card.name, "Monster Squad")
        XCTAssertEqual(card.posterUrl, "https://img/101.jpg")
        XCTAssertEqual(card.backgroundUrl, "https://img/101b.jpg")
        XCTAssertNil(card.imdbId)
        XCTAssertEqual(card.externalRatings?.first?.value, 82)
    }

    // MARK: Client

    func testRequestBodiesAndCacheKeysAreStable() throws {
        let first = try AniListClient.body(query: "query", variables: ["b": 2, "a": nil])
        let second = try AniListClient.body(query: "query", variables: ["a": nil, "b": 2])
        XCTAssertEqual(first, second)
        XCTAssertEqual(AniListClient.cacheKey(for: first), AniListClient.cacheKey(for: second))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let variables = try XCTUnwrap(json["variables"] as? [String: Any])
        XCTAssertTrue(variables["a"] is NSNull)
    }

    func testTheDiskCacheHonoursItsAge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AniListTests-\(UUID().uuidString)")
        let cache = AniListDiskCache(directory: directory)
        defer { cache.removeAll() }
        cache.write(Data("hello".utf8), key: "k")
        XCTAssertEqual(cache.read(key: "k", maxAge: 60), Data("hello".utf8))
        XCTAssertNotNil(cache.readWithAge(key: "k"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: directory.appendingPathComponent("k").path
        )
        XCTAssertNil(cache.read(key: "k", maxAge: 60))
        XCTAssertEqual(cache.read(key: "k", maxAge: .infinity), Data("hello".utf8))
    }
}
