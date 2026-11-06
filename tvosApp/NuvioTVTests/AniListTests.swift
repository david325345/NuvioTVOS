import ImageIO
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
        XCTAssertNil(variables["a"])
        XCTAssertEqual(variables["b"] as? Int, 2)
    }

    /// AniList reads `isAdult: null` as a filter that finds nothing, so "no filter" leaves the
    /// variable out, even when it arrives as an optional inside `Any?`.
    func testVariablesWithoutAValueAreLeftOut() throws {
        let showAdult: Bool? = nil
        let hideAdult: Bool? = false
        let season: String? = nil
        let body = try AniListClient.body(
            query: "query",
            variables: ["isAdult": showAdult, "season": season, "genre": nil, "perPage": 30]
        )
        let variables = try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["variables"] as? [String: Any])
        XCTAssertEqual(Set(variables.keys), ["perPage"])

        let hidden = try AniListClient.body(query: "query", variables: ["isAdult": hideAdult])
        let hiddenVariables = try XCTUnwrap((JSONSerialization.jsonObject(with: hidden) as? [String: Any])?["variables"] as? [String: Any])
        XCTAssertEqual(hiddenVariables["isAdult"] as? Bool, false)
        XCTAssertTrue(String(decoding: hidden, as: UTF8.self).contains("\"isAdult\":false"))
    }

    func testAnErrorAniListSendsAs200IsRecognised() {
        let onlyError = Data(#"{"errors":[{"message":"Max query complexity exceeded","status":400}],"data":null}"#.utf8)
        XCTAssertEqual(AniListClient.errorMessage(in: onlyError), "Max query complexity exceeded")
        XCTAssertFalse(AniListClient.hasData(onlyError))

        let partial = Data(#"{"errors":[{"message":"One page failed"}],"data":{"trending":{"media":[]},"top":null}}"#.utf8)
        XCTAssertEqual(AniListClient.errorMessage(in: partial), "One page failed")
        XCTAssertTrue(AniListClient.hasData(partial))

        let fine = Data(#"{"data":{"Page":{"media":[{"id":1}]}}}"#.utf8)
        XCTAssertNil(AniListClient.errorMessage(in: fine))
        XCTAssertEqual(
            AniListDiagnostics.describe(AniListClient.ClientError.answeredWithError("Max query complexity exceeded")),
            "AniList: Max query complexity exceeded"
        )
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

    func testSavedAnswersFromAnotherBuildAreDropped() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AniListTests-\(UUID().uuidString)")
        let cache = AniListDiskCache(directory: directory)
        defer { cache.removeAll() }
        cache.write(Data("old".utf8), key: "k")
        XCTAssertTrue(cache.removeAllIfWritten(byAnotherBuildThan: "2|1.0|7|100"))
        XCTAssertNil(cache.read(key: "k", maxAge: .infinity))

        cache.write(Data("new".utf8), key: "k")
        XCTAssertFalse(cache.removeAllIfWritten(byAnotherBuildThan: "2|1.0|7|100"))
        XCTAssertEqual(cache.read(key: "k", maxAge: .infinity), Data("new".utf8))

        XCTAssertTrue(cache.removeAllIfWritten(byAnotherBuildThan: "2|1.0|7|200"))
        XCTAssertNil(cache.read(key: "k", maxAge: .infinity))
        XCTAssertTrue(AniListDiskCache.currentBuild.hasPrefix("\(AniListDiskCache.formatVersion)|"))
    }

    // MARK: Pictures

    private let aniZipJSON = """
    {"episodes":{"1":{"title":{"en":"The Squad"},"image":"https://zip/1.jpg"}},
     "images":[{"coverType":"Banner","url":"https://tvdb/banner.jpg"},
               {"coverType":"Fanart","url":"http://tvdb/fanart.jpg"},
               {"coverType":"Clearlogo","url":"https://tvdb/logo.png"}],
     "mappings":{"anilist_id":101,"themoviedb_id":"8392","imdb_id":"tt1"}}
    """

    func testAniZipGivesTheTVDBBackgroundLogoAndTmdbID() throws {
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(aniZipJSON.utf8))
        XCTAssertEqual(response.fanart, "https://tvdb/fanart.jpg")
        XCTAssertEqual(response.clearLogo, "https://tvdb/logo.png")
        XCTAssertEqual(response.mappings?.themoviedbID, 8392)
        XCTAssertEqual(response.episodes?["1"]?.englishTitle, "The Squad")

        let numeric = try decoder.decode(AniZipMappingsResponse.self, from: Data(#"{"mappings":{"themoviedb_id":129}}"#.utf8))
        XCTAssertEqual(numeric.mappings?.themoviedbID, 129)
    }

    func testOnlyAWholeIMDbIDLeadsToMetahub() throws {
        let mapped = try decoder.decode(AniZipMappings.self, from: Data(#"{"imdb_id":" TT5370118 "}"#.utf8))
        XCTAssertEqual(mapped.imdbID, "tt5370118")
        XCTAssertNil(try decoder.decode(AniZipMappings.self, from: Data(#"{"imdb_id":"tt"}"#.utf8)).imdbID)
        XCTAssertNil(try decoder.decode(AniZipMappings.self, from: Data(#"{"imdb_id":null}"#.utf8)).imdbID)

        let metahub = try XCTUnwrap(AniListService.metahubArtwork(imdbID: "tt5370118"))
        XCTAssertEqual(metahub.logo.absoluteString, "https://images.metahub.space/logo/medium/tt5370118/img")
        XCTAssertEqual(metahub.background.absoluteString, "https://images.metahub.space/background/medium/tt5370118/img")
        XCTAssertNil(AniListService.metahubArtwork(imdbID: "anilist:21202"))
    }

    func testAnOddPartOfAniZipCostsOnlyThatPart() throws {
        let json = #"{"episodes":{"1":{"title":{"en":"The Squad"}}},"images":"none","mappings":[1]}"#
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.episodes?["1"]?.englishTitle, "The Squad")
        XCTAssertNil(response.fanart)
        XCTAssertNil(response.mappings)
    }

    func testTheBackgroundIsTheTVDBFanartBeforeAniListsBanner() throws {
        let entries = try entries()
        let tabs = [try XCTUnwrap(entries[101]), try XCTUnwrap(entries[102])]
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(aniZipJSON.utf8))

        // The second season's pictures serve when the first has none.
        let artwork = AniListMetaBuilder.Artwork(tabs: tabs, aniZip: [102: response])
        XCTAssertEqual(artwork, AniListMetaBuilder.Artwork(background: "https://tvdb/fanart.jpg", logo: "https://tvdb/logo.png"))
        let meta = try XCTUnwrap(AniListMetaBuilder.meta(tabs: tabs, episodes: [:], language: .romaji, artwork: artwork))
        XCTAssertEqual(meta.backgroundUrl, "https://tvdb/fanart.jpg")
        XCTAssertEqual(meta.logoUrl, "https://tvdb/logo.png")

        let withoutAniZip = try XCTUnwrap(AniListMetaBuilder.meta(tabs: tabs, episodes: [:], language: .romaji))
        XCTAssertEqual(withoutAniZip.backgroundUrl, "https://img/101b.jpg")
        XCTAssertNil(withoutAniZip.logoUrl)
        XCTAssertEqual(AniListMetaBuilder.Artwork(tabs: tabs, aniZip: [:]), .empty)
    }

    /// A picture `width`×`height`: letters on a see-through background, or a filled still.
    private func picture(width: Int, height: Int, seeThrough: Bool, type: String = "public.png") throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1)
        if seeThrough {
            context.fill(CGRect(x: width / 10, y: height / 3, width: width * 8 / 10, height: height / 3))
        } else {
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testOnlyALogoStandsInTheHerosTitle() throws {
        XCTAssertTrue(AniListClient.looksLikeLogo(try picture(width: 400, height: 150, seeThrough: true)))
        // A still or a poster, in a PNG or a JPEG.
        XCTAssertFalse(AniListClient.looksLikeLogo(try picture(width: 400, height: 225, seeThrough: false)))
        XCTAssertFalse(AniListClient.looksLikeLogo(try picture(width: 400, height: 225, seeThrough: false, type: "public.jpeg")))
        XCTAssertFalse(AniListClient.looksLikeLogo(try picture(width: 200, height: 400, seeThrough: true)))
        XCTAssertFalse(AniListClient.looksLikeLogo(Data("<html>Not Found</html>".utf8)))
    }

    func testASecondSeasonTakesItsPicturesFromTheSeasonBefore() throws {
        func node(_ id: Int, _ format: String, _ year: Int, type: String = "ANIME") -> AniListMedia {
            AniListMedia(id: id, type: type, format: format, startDate: AniListDate(year: year, month: 1, day: 1))
        }
        let season3 = AniListMedia(id: 3, format: "TV", relations: AniListRelationConnection(edges: [
            AniListRelationEdge(relationType: "PREQUEL", node: node(1, "TV", 2020)),
            AniListRelationEdge(relationType: "PREQUEL", node: node(2, "TV", 2022)),
            AniListRelationEdge(relationType: "PREQUEL", node: node(9, "MOVIE", 2023)),
            AniListRelationEdge(relationType: "SEQUEL", node: node(4, "TV", 2026)),
            AniListRelationEdge(relationType: "ADAPTATION", node: node(5, "MANGA", 2018, type: "MANGA")),
        ]))
        XCTAssertEqual(AniListMetaBuilder.previousSeason(of: season3), 2)

        // After a film, with no season before it.
        let afterFilm = AniListMedia(id: 10, format: "TV", relations: AniListRelationConnection(edges: [
            AniListRelationEdge(relationType: "PREQUEL", node: node(9, "MOVIE", 2023)),
        ]))
        XCTAssertNil(AniListMetaBuilder.previousSeason(of: afterFilm))
        XCTAssertNil(AniListMetaBuilder.previousSeason(of: AniListMedia(id: 1, format: "TV")))

        let own = AniListMetaBuilder.Artwork(background: nil, logo: "https://tvdb/s2-logo.png")
        let earlier = AniListMetaBuilder.Artwork(background: "https://tvdb/s1-fanart.jpg", logo: "https://tvdb/s1-logo.png")
        XCTAssertFalse(own.isComplete)
        XCTAssertEqual(own.filled(by: earlier), AniListMetaBuilder.Artwork(background: "https://tvdb/s1-fanart.jpg", logo: "https://tvdb/s2-logo.png"))
        XCTAssertTrue(own.filled(by: earlier).isComplete)
    }

    func testArmServerGivesTheIMDbIdAniZipLacks() {
        let json = #"{"anidb":17617,"anilist":163132,"imdb":"tt21209876","themoviedb":null,"thetvdb":424536}"#
        XCTAssertEqual(AniListService.armIMDbID(in: Data(json.utf8)), "tt21209876")
        XCTAssertNil(AniListService.armIMDbID(in: Data(#"{"anilist":1,"imdb":null}"#.utf8)))
        XCTAssertNil(AniListService.armIMDbID(in: Data("null".utf8)))
        XCTAssertNil(AniListService.armIMDbID(in: Data(#"{"imdb":"21209876"}"#.utf8)))
    }

    func testACardCarriesItsYouTubeTrailerForTheHero() {
        let onYouTube = AniListMedia(id: 7, type: "ANIME", format: "TV", trailer: AniListTrailer(id: " dQw4w9WgXcQ ", site: "youtube"))
        XCTAssertEqual(AniListMetaBuilder.card(onYouTube, language: .romaji).trailerYtIds, ["dQw4w9WgXcQ"])
        let onDailymotion = AniListMedia(id: 8, type: "ANIME", format: "TV", trailer: AniListTrailer(id: "x7abc", site: "dailymotion"))
        XCTAssertNil(AniListMetaBuilder.card(onDailymotion, language: .romaji).trailerYtIds)
        XCTAssertNil(AniListMetaBuilder.card(AniListMedia(id: 9, type: "ANIME", format: "TV"), language: .romaji).trailerYtIds)
    }

    func testTheHeroNamesTheSeasonUnderTheSeriesLogo() throws {
        let card = AniListMetaBuilder.card(try XCTUnwrap(try entries()[102]), language: .romaji)
        XCTAssertEqual(AniListMetaBuilder.nameUnderLogo(card), card.name)
        let other = NuvioMeta(id: "tt0903747", name: "Breaking Bad", type: "series")
        XCTAssertNil(AniListMetaBuilder.nameUnderLogo(other))
    }

    func testTheHeroTakesTheTVDBPicturesAndKeepsTheRest() throws {
        let card = AniListMetaBuilder.card(try XCTUnwrap(try entries()[101]), language: .english)
        let hero = AniListMetaBuilder.applying(AniListMetaBuilder.Artwork(background: "https://tvdb/fanart.jpg", logo: nil), to: card)
        XCTAssertEqual(hero.id, card.id)
        XCTAssertEqual(hero.name, card.name)
        XCTAssertEqual(hero.backgroundUrl, "https://tvdb/fanart.jpg")
        XCTAssertNil(hero.logoUrl)
        XCTAssertEqual(hero.externalRatings, card.externalRatings)
        XCTAssertEqual(AniListMetaBuilder.applying(.empty, to: card), card)
    }

    // MARK: Episode labels

    func testAniListEpisodesAreLabelledWithoutTheFirstSeason() {
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "anilist:101:1", season: 1, episode: 1), "E1")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "anilist:102:5", season: 2, episode: 5), "S2 E5")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "tt0903747:1:1", season: 1, episode: 1), "S1 E1")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "anilist:101", season: 1, episode: 3, separator: " · "), "E3")
        XCTAssertEqual(AniListMetaBuilder.episodeCode(id: "tt0903747", season: 5, episode: 14, separator: " · "), "S5 · E14")

        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S1, E1 • Episode 1", titleID: "anilist:101"), "E1 • Episode 1")
        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S2, E1 • Episode 1", titleID: "anilist:101"), "S2, E1 • Episode 1")
        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S1, E1 • Pilot", titleID: "tt0903747"), "S1, E1 • Pilot")
        XCTAssertEqual(AniListMetaBuilder.playerEpisodeLine("S1, E1 • Pilot", titleID: nil), "S1, E1 • Pilot")
    }

    // MARK: Search

    @MainActor
    func testSearchEnrichmentLeavesAniListCardsAsTheyAre() async throws {
        final class CountingRepository: MockCatalogRepository {
            var refreshed: [String] = []
            override func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
                refreshed.append(id)
                return NuvioMeta(id: id, name: "Naruto", backgroundUrl: "https://cinemeta/bg.jpg", imdbId: "tt0409591", type: "series", year: 2002)
            }
        }
        let aniList = NuvioMeta(id: "anilist:20", name: "Naruto", posterUrl: "https://img/20.jpg", type: "series", year: 2002)
        let cinemeta = NuvioMeta(id: "tt0409591", name: "Naruto", posterUrl: "https://cinemeta/20.jpg", imdbId: "tt0409591", type: "series", year: 2002)
        let repository = CountingRepository()

        XCTAssertFalse(SearchResultEnrichment.hasIncompleteLeadingResults([aniList]))
        XCTAssertTrue(SearchResultEnrichment.hasIncompleteLeadingResults([aniList, cinemeta]))

        let enriched = await SearchResultEnrichment.enrich([aniList, cinemeta], repository: repository)
        XCTAssertEqual(repository.refreshed, ["tt0409591"])
        XCTAssertEqual(enriched.map(\.id), ["anilist:20", "tt0409591"])
        XCTAssertEqual(enriched.first, aniList)
        XCTAssertNil(enriched.first?.imdbId)
    }

    func testASearchAniListDidNotAnswerIsMarked() {
        XCTAssertTrue(AniListService.SearchResult.failure.failed)
        XCTAssertFalse(AniListService.SearchResult.empty.failed)
    }

    // MARK: Status

    func testStatusTellsWhatHomeLastDidAndWhatReachedTheScreen() {
        AniListDiagnostics.reset()
        defer { AniListDiagnostics.reset() }
        let time: (Date) -> String = { _ in "21:38" }
        XCTAssertEqual(AniListDiagnostics.text(.home, timeStyle: time), "Not asked yet")

        let asked = Date(timeIntervalSince1970: 1_000)
        AniListDiagnostics.noteHomeOnScreen(rows: 2, at: asked.addingTimeInterval(-60))
        AniListDiagnostics.note(.home, "5 of 5 rows, 150 titles · from AniList", at: asked)
        // A count from an earlier load is left out.
        XCTAssertEqual(AniListDiagnostics.text(.home, timeStyle: time), "21:38 · 5 of 5 rows, 150 titles · from AniList")

        AniListDiagnostics.noteHomeOnScreen(rows: 5, at: asked.addingTimeInterval(2))
        XCTAssertEqual(AniListDiagnostics.text(.home, timeStyle: time), "21:38 · 5 of 5 rows, 150 titles · from AniList · 5 on screen")

        AniListDiagnostics.note(.search, "“naruto”: 12 results (9 series, 3 films) · saved answer", at: asked)
        XCTAssertEqual(AniListDiagnostics.text(.search, timeStyle: time), "21:38 · “naruto”: 12 results (9 series, 3 films) · saved answer")
        XCTAssertEqual(AniListDiagnostics.describe(AniListClient.ClientError.badResponse(400)), "HTTP 400")
    }

    // MARK: Home

    func testHomeTakesAniListsRowsOnlyWhenTheyAreReady() async {
        let ready = Task<[Int], Never> { [1, 2] }
        let readyValue = await CinemetaCatalogRepository.value(of: ready, within: 2)
        XCTAssertEqual(readyValue, [1, 2])

        let slow = Task<[Int], Never> {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return [3]
        }
        let started = Date()
        let slowValue = await CinemetaCatalogRepository.value(of: slow, within: 0.1)
        XCTAssertNil(slowValue)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        slow.cancel()
    }

    // MARK: Account

    func testThePastedTokenIsFoundInWhateverWasCopied() {
        XCTAssertEqual(AniListAccount.token(fromPasted: "  abc.def.ghi \n"), "abc.def.ghi")
        XCTAssertEqual(
            AniListAccount.token(fromPasted: "https://anilist.co/api/v2/oauth/pin#access_token=abc.def&token_type=Bearer&expires_in=31536000"),
            "abc.def"
        )
        XCTAssertEqual(AniListAccount.token(fromPasted: ""), "")
        XCTAssertEqual(
            AniListAccount.authorizeURL(clientID: " 12345 ")?.absoluteString,
            "https://anilist.co/api/v2/oauth/authorize?client_id=12345&response_type=token"
        )
        XCTAssertNil(AniListAccount.authorizeURL(clientID: "abc"))
        XCTAssertNil(AniListAccount.authorizeURL(clientID: ""))
        XCTAssertEqual(AniListAccount.token(fromPasted: "Bearer eyJabc.def.ghi"), "eyJabc.def.ghi")
    }

    func testThePhonesLoginReachesThisAppleTV() {
        func request(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

        // AniList sends the phone to the Redirect URL; the token is in the fragment, never sent.
        XCTAssertEqual(AniListLoginServer.parse(request("GET /anilist HTTP/1.1\nHost: 192.168.1.50:47811\n\n")), .page)
        XCTAssertEqual(AniListLoginServer.parse(request("GET /anilist?error=access_denied HTTP/1.1\n\n")), .page)
        XCTAssertEqual(AniListLoginServer.parse(request("GET /favicon.ico HTTP/1.1\n\n")), .notFound)
        XCTAssertEqual(AniListLoginServer.parse(Data("GET /anilist HTTP/1.1\r\nHost: x".utf8)), .incomplete)

        // The page posts the token back.
        let body = "access_token=eyJ0eXAi.eyJhdWQi.c2ln&state=abc123"
        let post = "POST /anilist/token HTTP/1.1\nContent-Type: application/x-www-form-urlencoded\nContent-Length: \(body.utf8.count)\n\n"
        XCTAssertEqual(AniListLoginServer.parse(request(post) + Data(body.utf8)), .token("eyJ0eXAi.eyJhdWQi.c2ln", state: "abc123"))
        XCTAssertEqual(AniListLoginServer.parse(request(post) + Data(body.prefix(10).utf8)), .incomplete)
        XCTAssertEqual(
            AniListLoginServer.parse(request("POST /anilist/token HTTP/1.1\nContent-Length: 14\n\n") + Data("access_token=a".utf8)),
            .token("a", state: nil)
        )
        XCTAssertEqual(AniListLoginServer.parse(request("POST /anilist/token HTTP/1.1\nContent-Length: 6\n\n") + Data("state=".utf8)), .invalid)
        XCTAssertEqual(AniListLoginServer.parse(request("POST /anilist/token HTTP/1.1\nTransfer-Encoding: chunked\n\n")), .invalid)
        XCTAssertEqual(AniListLoginServer.formFields("a=1%2B2&b=x+y&c"), ["a": "1+2", "b": "x y", "c": ""])

        XCTAssertTrue(AniListLoginServer.page.contains("fetch('/anilist/token'"))
        XCTAssertTrue(AniListLoginServer.page.contains("history.replaceState"))

        // The QR code's address carries the state the Apple TV waits for.
        XCTAssertEqual(
            AniListAccount.authorizeURL(clientID: "56063", state: "abc123")?.absoluteString,
            "https://anilist.co/api/v2/oauth/authorize?client_id=56063&response_type=token&state=abc123"
        )
        XCTAssertEqual(
            AniListAccount.authorizeURL(clientID: "56063", state: "a&b")?.absoluteString,
            "https://anilist.co/api/v2/oauth/authorize?client_id=56063&response_type=token"
        )
    }

    /// A token shaped like AniList's: an RS256 JWT with a 256-byte signature.
    private func jwt(aud: Any = "56063", sub: Any = "8395785", exp: Date = Date(timeIntervalSince1970: 1_825_000_000)) -> String {
        func part(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["typ": "JWT", "alg": "RS256", "jti": String(repeating: "a", count: 80)])
        let claims: [String: Any] = [
            "aud": aud, "jti": String(repeating: "b", count: 80), "iat": 1_760_000_000,
            "nbf": 1_760_000_000, "exp": exp.timeIntervalSince1970, "sub": sub, "scopes": [String](),
        ]
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let signature = Data((0..<256).map { UInt8($0 % 251) })
        return [part(header), part(payload), part(signature)].joined(separator: ".")
    }

    func testAWholeTokenIsReadWithoutAskingAniList() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let token = jwt()
        let (facts, problem) = AniListAccount.inspect(token, now: now)
        XCTAssertNil(problem)
        XCTAssertEqual(facts.parts, 3)
        XCTAssertEqual(facts.clientID, "56063")
        XCTAssertEqual(facts.userID, "8395785")
        XCTAssertEqual(facts.expires, Date(timeIntervalSince1970: 1_825_000_000))
        XCTAssertEqual(facts.summary, "token \(token.count) characters, 3 parts, client 56063")
        // Claims sent as numbers read the same.
        XCTAssertEqual(AniListAccount.inspect(jwt(aud: 56063, sub: 8395785), now: now).facts.clientID, "56063")
    }

    func testABrokenTokenIsCaughtBeforeAniListIsAsked() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let token = jwt()

        // Cut off inside the signature, inside the payload, or pasted twice.
        XCTAssertEqual(AniListAccount.inspect(String(token.dropLast(40)), now: now).problem, .incomplete(length: token.count - 40))
        XCTAssertEqual(AniListAccount.inspect(String(token.dropLast(37)), now: now).problem, .incomplete(length: token.count - 37))
        let firstTwo = token.split(separator: ".").prefix(2).joined(separator: ".")
        XCTAssertEqual(AniListAccount.inspect(firstTwo, now: now).problem, .incomplete(length: firstTwo.count))
        XCTAssertEqual(AniListAccount.inspect(token + token, now: now).problem, .incomplete(length: token.count * 2))

        // The Client Secret, or the Client ID.
        let secret = String(repeating: "x", count: 40)
        XCTAssertEqual(AniListAccount.inspect(secret, now: now).problem, .notAToken(length: 40))
        XCTAssertEqual(AniListAccount.inspect("56063", now: now).problem, .notAToken(length: 5))

        // Changed on the way: a dash made into "—", or an ellipsis where it was shortened.
        let dashed = token.replacingOccurrences(of: "-", with: "—")
        if dashed != token {
            XCTAssertEqual(AniListAccount.inspect(dashed, now: now).problem, .changed(length: dashed.count))
        }
        let shortened = String(token.prefix(500)) + "…"
        XCTAssertEqual(AniListAccount.inspect(shortened, now: now).problem, .changed(length: 501))

        // Past its year.
        let expired = jwt(exp: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(AniListAccount.inspect(expired, now: now).problem, .expired(Date(timeIntervalSince1970: 1_780_000_000)))
    }

    func testLoggingInWithABrokenTokenSaysWhyAndKeepsNothing() async {
        let saved = AniListAccount.storage
        AniListAccount.storage = AniListMemoryTokenStorage()
        defer { AniListAccount.storage = saved }
        let token = jwt()

        do {
            try await AniListAccount.logIn(pasted: String(token.prefix(600)), now: Date(timeIntervalSince1970: 1_790_000_000))
            XCTFail("A cut-off token must not be sent")
        } catch {
            XCTAssertEqual(error as? AniListAccount.AccountError, .badToken(.incomplete(length: 600)))
            XCTAssertEqual(error.localizedDescription, AniListAccount.TokenProblem.incomplete(length: 600).message)
        }
        XCTAssertNil(AniListAccount.storage.login(for: ProfileSettings.activeProfileScope))
        let note = AniListDiagnostics.entry(.account)?.text ?? ""
        XCTAssertTrue(note.hasPrefix("Log in stopped: The token arrived incomplete"), note)
        XCTAssertTrue(note.contains("· token 600 characters, 3 parts, client 56063"), note)
        XCTAssertFalse(note.contains(String(token.prefix(40))))
    }

    func testAniListsOwnWordsAreShownWithAFailure() {
        XCTAssertEqual(AniListDiagnostics.describe(AniListClient.ClientError.refused(404, "Not Found.")), "HTTP 404 · Not Found.")
        XCTAssertEqual(
            AniListAccount.AccountError.notAccepted("HTTP 400 · Invalid token").localizedDescription,
            "AniList didn't accept the token (HTTP 400 · Invalid token)."
        )
    }

    private func entry(_ status: String?, progress: Int = 0, repeatCount: Int = 0, started: Bool = true) -> AniListListEntry {
        AniListListEntry(id: 1, mediaId: 101, status: status, progress: progress, repeatCount: repeatCount,
                         startedAt: started ? AniListDate(year: 2026, month: 1, day: 1) : nil)
    }

    func testWatchingMovesProgressForwardOnly() {
        typealias Change = AniListAccount.Change
        // Not on a list: starts watching today.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 1, byPlaying: true), entry: nil, total: 12),
                       Change(status: "CURRENT", progress: 1, startsToday: true))
        // Planning: moves to Watching.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 3, byPlaying: true), entry: entry("PLANNING", started: false), total: 12),
                       Change(status: "CURRENT", progress: 3, startsToday: true))
        // Watching, an older episode again: nothing.
        XCTAssertNil(AniListAccount.change(for: .watched(episode: 4, byPlaying: true), entry: entry("CURRENT", progress: 5), total: 12))
        // Watching, the next one.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 6, byPlaying: true), entry: entry("CURRENT", progress: 5), total: 12),
                       Change(status: "CURRENT", progress: 6))
        // The last one completes it.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 12, byPlaying: true), entry: entry("CURRENT", progress: 11), total: 12),
                       Change(status: "COMPLETED", progress: 12, completesToday: true))
        // Airing with no known total never completes.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 30, byPlaying: true), entry: entry("CURRENT", progress: 29), total: nil),
                       Change(status: "CURRENT", progress: 30))
        // A film (one episode).
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 1, byPlaying: true), entry: nil, total: 1),
                       Change(status: "COMPLETED", progress: 1, startsToday: true, completesToday: true))
    }

    func testRewatchesAndCompletedEntries() {
        typealias Change = AniListAccount.Change
        // Playing the first episode of a completed series starts a rewatch; marking it doesn't.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 1, byPlaying: true), entry: entry("COMPLETED", progress: 12), total: 12),
                       Change(status: "REPEATING", progress: 1))
        XCTAssertNil(AniListAccount.change(for: .watched(episode: 1, byPlaying: false), entry: entry("COMPLETED", progress: 12), total: 12))
        XCTAssertNil(AniListAccount.change(for: .watched(episode: 5, byPlaying: true), entry: entry("COMPLETED", progress: 12), total: 12))
        // A rewatch counts on and ends as another completion.
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 2, byPlaying: true), entry: entry("REPEATING", progress: 1, repeatCount: 1), total: 12),
                       Change(progress: 2))
        XCTAssertEqual(AniListAccount.change(for: .watched(episode: 12, byPlaying: true), entry: entry("REPEATING", progress: 11, repeatCount: 1), total: 12),
                       Change(status: "COMPLETED", progress: 12, repeatCount: 2, completesToday: true))
    }

    func testUnwatchingGoesBackToTheEpisodeBefore() {
        typealias Change = AniListAccount.Change
        XCTAssertEqual(AniListAccount.change(for: .unwatched(episode: 5), entry: entry("CURRENT", progress: 7), total: 12),
                       Change(progress: 4))
        XCTAssertEqual(AniListAccount.change(for: .unwatched(episode: 12), entry: entry("COMPLETED", progress: 12), total: 12),
                       Change(status: "CURRENT", progress: 11))
        XCTAssertNil(AniListAccount.change(for: .unwatched(episode: 9), entry: entry("CURRENT", progress: 7), total: 12))
        XCTAssertNil(AniListAccount.change(for: .unwatched(episode: 1), entry: nil, total: 12))
    }

    func testEpisodeNumbersAndEntriesOfATitle() throws {
        XCTAssertEqual(AniListAccount.episodeNumber(in: "anilist:102:5"), 5)
        XCTAssertNil(AniListAccount.episodeNumber(in: "anilist:102"))
        XCTAssertNil(AniListAccount.episodeNumber(in: "tt0903747:1:1"))
        let meta = NuvioMeta(id: "anilist:101", name: "Kaiju Sentai", type: "series", videos: [
            NuvioVideo(id: "anilist:101:1", title: "1", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "anilist:102:1", title: "1", season: 2, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "anilist:102:2", title: "2", season: 2, episode: 2, thumbnail: nil, overview: nil, released: nil, rating: nil),
        ])
        XCTAssertEqual(AniListAccount.entryIDs(of: meta), [101, 102])
        XCTAssertEqual(AniListAccount.entryIDs(of: NuvioMeta(id: "anilist:555", name: "Film", type: "movie")), [555])
    }

    func testListEntriesDecodeWithTheirRewatchCount() throws {
        let json = #"{"data":{"Page":{"mediaList":[{"id":9,"mediaId":21202,"status":"CURRENT","progress":4,"repeat":1,"score":80,"startedAt":{"year":2026,"month":11,"day":1},"media":{"id":21202,"episodes":10,"isFavourite":true}}]}}}"#
        let list = try XCTUnwrap(decoder.decode(AniListEntryPageResponse.self, from: Data(json.utf8)).data?.Page?.mediaList)
        XCTAssertEqual(list.first?.repeatCount, 1)
        XCTAssertEqual(list.first?.progress, 4)
        XCTAssertEqual(list.first?.score, 80)
        XCTAssertEqual(list.first?.media?.isFavourite, true)
    }

    // MARK: Cinemeta anime on AniList

    func testAirDaysAreComparedAsDays() {
        XCTAssertEqual(AniListMatcher.day(of: "2016-01-14T00:00:00.000Z"), "2016-01-14")
        XCTAssertNil(AniListMatcher.day(of: "2016"))
        XCTAssertEqual(AniListMatcher.daysBetween("2016-01-14", "2016-01-15"), 1)
        XCTAssertEqual(AniListMatcher.daysBetween("2016-01-15", "2016-01-14"), -1)
    }

    func testACinemetaEpisodeIsMatchedByItsAirDayThenByTheTVDBNumbers() {
        typealias Candidate = AniListMatcher.Candidate
        // A split season: TheTVDB S1E13 is the first episode of the second AniList entry.
        let candidates = [
            Candidate(entryID: 1, episode: 12, airDay: "2026-03-27", tvdbSeason: 1, tvdbEpisode: 12),
            Candidate(entryID: 2, episode: 1, airDay: "2026-07-03", tvdbSeason: 1, tvdbEpisode: 13),
            Candidate(entryID: 2, episode: 2, airDay: "2026-07-10", tvdbSeason: 1, tvdbEpisode: 14),
        ]
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: "2026-07-03", season: 1, episode: 13)?.episode, 1)
        // A day off for time zones.
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: "2026-07-11", season: 1, episode: 14), candidates[2])
        // IMDb numbers it differently: the day still wins.
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: "2026-07-03", season: 2, episode: 1), candidates[1])
        // No day: TheTVDB's numbers.
        XCTAssertEqual(AniListMatcher.pick(from: candidates, airDay: nil, season: 1, episode: 12), candidates[0])
        // Nothing that day and no numbers: nothing.
        XCTAssertNil(AniListMatcher.pick(from: candidates, airDay: "2026-05-01", season: 3, episode: 1))

        // Two episodes the same day: the numbers tell them apart, or nothing is written.
        let premiere = [
            Candidate(entryID: 5, episode: 1, airDay: "2026-01-10", tvdbSeason: 1, tvdbEpisode: 1),
            Candidate(entryID: 5, episode: 2, airDay: "2026-01-10", tvdbSeason: 1, tvdbEpisode: 2),
        ]
        XCTAssertEqual(AniListMatcher.pick(from: premiere, airDay: "2026-01-10", season: 1, episode: 2), premiere[1])
        XCTAssertNil(AniListMatcher.pick(from: premiere, airDay: "2026-01-10", season: 3, episode: 7))
    }

    func testAniZipEpisodesKeepTheirTheTVDBNumbersAndDays() throws {
        let json = #"{"episodes":{"1":{"seasonNumber":1,"episodeNumber":"13","absoluteEpisodeNumber":13,"airdate":"2026-07-03","title":{"en":"Again"}}}}"#
        let response = try decoder.decode(AniZipMappingsResponse.self, from: Data(json.utf8))
        let episode = try XCTUnwrap(response.episodes?["1"])
        XCTAssertEqual(episode.seasonNumber, 1)
        XCTAssertEqual(episode.episodeNumber, 13)
        XCTAssertEqual(episode.airDay, "2026-07-03")
        XCTAssertEqual(episode.englishTitle, "Again")
    }
}
