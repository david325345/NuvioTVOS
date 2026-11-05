import Foundation

/// AniList inside Nuvio: Home rows, See All, Search and the details of `anilist:` titles,
/// all asked from this Apple TV. See `AniListMetaBuilder` for how entries become titles.
enum AniListService {
    static let addonID = "anilist"
    static let addonName = "AniList"
    /// Content type of the Home rows ("Trending Now - Anime").
    static let homeContentType = "anime"

    /// The round AniList mark on Search's cards, drawn like the service logos on Home's cards.
    static let searchBadge = CollectionOriginPresentation(
        reference: CollectionOriginReference(collectionID: addonID, folderID: addonID),
        title: addonName,
        imageURLs: [AniListMetaBuilder.ratingIcon],
        emoji: nil
    )

    static let catalogTTL: TimeInterval = 6 * 3600
    static let searchTTL: TimeInterval = 3600
    /// Entries still airing (or not yet) are asked again after an hour, finished ones after a week.
    static let airingTTL: TimeInterval = 3600
    static let finishedTTL: TimeInterval = 7 * 24 * 3600
    static let aniZipTTL: TimeInterval = 24 * 3600
    static let pageSize = 50
    static let homeRowSize = 30

    private static let decoder = JSONDecoder()

    static func isAniListTitle(_ id: String) -> Bool {
        AniListSettings.isEnabled && AniListMetaBuilder.isAniListID(id)
    }

    private static var isAdultVariable: Bool? {
        AniListSettings.showsAdult ? nil : false
    }

    // MARK: Home

    static func catalogSettingsKey(_ row: AniListHomeRow) -> String {
        TVHomeCatalogOrder.catalogSettingsKey(addonId: addonID, contentType: homeContentType, catalogId: row.id)
    }

    static func catalogRowID(_ row: AniListHomeRow) -> String {
        "addon_\(addonID)_\(homeContentType)_\(row.id)"
    }

    static func catalogDisplayTitle(_ row: AniListHomeRow) -> String {
        let showType = ProfileSettings.current.object(forKey: SettingsKey.homeCatalogShowType) as? Bool ?? true
        return TVHomeCatalogOrder.catalogDisplayTitle(
            row.title,
            contentType: homeContentType,
            showType: showType,
            addonName: addonName,
            customTitle: TVHomeCatalogOrder.customCatalogTitles()[catalogSettingsKey(row)]
        )
    }

    /// The viewer's lists first (when logged in), then the AniList rows that Layout doesn't hide.
    static func homeCatalogs() async -> [NuvioCatalog] {
        guard AniListSettings.isEnabled else { return [] }
        guard AniListSettings.showsHomeRows else {
            AniListDiagnostics.note(.home, "Off: AniList Rows on Home is off")
            return []
        }
        async let lists = listCatalogs()
        let rows = await browseCatalogs()
        return await lists + rows
    }

    static func listSettingsKey(_ rowID: String) -> String {
        TVHomeCatalogOrder.catalogSettingsKey(addonId: addonID, contentType: homeContentType, catalogId: rowID)
    }

    static func listRowID(_ rowID: String) -> String {
        "addon_\(addonID)_\(homeContentType)_\(rowID)"
    }

    static func listDisplayTitle(_ rowID: String, title: String) -> String {
        let showType = ProfileSettings.current.object(forKey: SettingsKey.homeCatalogShowType) as? Bool ?? true
        return TVHomeCatalogOrder.catalogDisplayTitle(
            "My \(title)",
            contentType: homeContentType,
            showType: showType,
            addonName: addonName,
            customTitle: TVHomeCatalogOrder.customCatalogTitles()[listSettingsKey(rowID)]
        )
    }

    /// The viewer's Watching, Planning and Paused lists, one request (kept five minutes).
    static func listCatalogs() async -> [NuvioCatalog] {
        guard AniListSettings.showsListRows else { return [] }
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
        let rows = AniListAccount.listRows.filter { !disabled.contains(listSettingsKey($0.id)) }
        guard !rows.isEmpty, let byRow = await AniListAccount.listEntries() else { return [] }
        let language = AniListSettings.titleLanguage
        return rows.compactMap { row in
            let items = (byRow[row.id] ?? []).compactMap(\.media).map { AniListMetaBuilder.card($0, language: language) }
            guard !items.isEmpty else { return nil }
            let title = listDisplayTitle(row.id, title: row.title)
            return NuvioCatalog(
                id: listRowID(row.id),
                name: title,
                description: title,
                itemIds: items.map(\.id),
                items: items,
                contentType: homeContentType,
                catalogId: row.id,
                addonId: addonID,
                addonName: addonName
            )
        }
    }

    /// The AniList rows that Layout doesn't hide, in one request.
    private static func browseCatalogs() async -> [NuvioCatalog] {
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
        let rows = AniListHomeRow.all.filter { !disabled.contains(catalogSettingsKey($0)) }
        guard !rows.isEmpty else {
            AniListDiagnostics.note(.home, "Every AniList row is hidden in Layout")
            return []
        }

        let current = AniListSeason.current()
        let next = AniListSeason.next()
        var variables: [String: Any?] = ["perPage": homeRowSize, "isAdult": isAdultVariable]
        if rows.contains(where: \.usesSeason) {
            variables["season"] = current.season
            variables["seasonYear"] = current.year
        }
        if rows.contains(where: \.usesNextSeason) {
            variables["nextSeason"] = next.season
            variables["nextSeasonYear"] = next.year
        }

        let answer: AniListClient.Answer
        do {
            answer = try await AniListClient.shared.answer(
                AniListQueries.homeRows(rows), variables: variables, ttl: catalogTTL
            )
        } catch {
            AniListDiagnostics.note(.home, "Failed: \(AniListDiagnostics.describe(error))")
            return []
        }
        let pages: [String: AniListPage]
        do {
            pages = try decoder.decode(AniListAliasedPagesResponse.self, from: answer.data).data ?? [:]
        } catch {
            await AniListClient.shared.noteFailure("Unreadable Home answer: \(error)")
            AniListDiagnostics.note(.home, "Unreadable answer · \(AniListDiagnostics.source(answer))")
            return []
        }

        let language = AniListSettings.titleLanguage
        let catalogs: [NuvioCatalog] = rows.compactMap { row in
            let items = (pages[row.id]?.media ?? []).map { AniListMetaBuilder.card($0, language: language) }
            guard !items.isEmpty else { return nil }
            let title = catalogDisplayTitle(row)
            return NuvioCatalog(
                id: catalogRowID(row),
                name: title,
                description: title,
                itemIds: items.map(\.id),
                items: items,
                contentType: homeContentType,
                catalogId: row.id,
                addonId: addonID,
                addonName: addonName
            )
        }
        let titles = catalogs.reduce(0) { $0 + ($1.items?.count ?? 0) }
        AniListDiagnostics.note(
            .home,
            catalogs.isEmpty
                ? "AniList answered with no titles · \(AniListDiagnostics.source(answer))"
                : "\(catalogs.count) of \(rows.count) rows, \(titles) titles · \(AniListDiagnostics.source(answer))"
        )
        return catalogs
    }

    /// See All for an AniList row.
    static func browse(catalogId: String, skip: Int, genre: String? = nil) async -> CatalogPage {
        if let listRow = AniListAccount.listRows.first(where: { $0.id == catalogId }) {
            // One of the viewer's lists: all of it at once.
            guard skip == 0, let byRow = await AniListAccount.listEntries() else {
                return CatalogPage(items: [], hasMore: false, page: 1)
            }
            let language = AniListSettings.titleLanguage
            let items = (byRow[listRow.id] ?? []).compactMap(\.media).map { AniListMetaBuilder.card($0, language: language) }
            return CatalogPage(items: items, hasMore: false, page: 1, nextSkip: items.count)
        }
        guard AniListSettings.isEnabled, let row = AniListHomeRow.row(id: catalogId) else {
            return CatalogPage(items: [], hasMore: false, page: 1)
        }
        let page = max(skip, 0) / pageSize + 1
        var variables: [String: Any?] = [
            "page": page,
            "perPage": pageSize,
            "sort": row.sort,
            "season": nil,
            "seasonYear": nil,
            "genre": genre,
            "isAdult": isAdultVariable,
        ]
        if row.usesSeason {
            let current = AniListSeason.current()
            variables["season"] = current.season
            variables["seasonYear"] = current.year
        } else if row.usesNextSeason {
            let next = AniListSeason.next()
            variables["season"] = next.season
            variables["seasonYear"] = next.year
        }
        guard let data = try? await AniListClient.shared.query(AniListQueries.catalog, variables: variables, ttl: catalogTTL),
              let result = try? decoder.decode(AniListPageResponse.self, from: data).data?.Page else {
            return CatalogPage(items: [], hasMore: false, page: page)
        }
        let language = AniListSettings.titleLanguage
        let items = (result.media ?? []).map { AniListMetaBuilder.card($0, language: language) }
        return CatalogPage(
            items: items,
            hasMore: result.pageInfo?.hasNextPage ?? false,
            page: page,
            nextSkip: skip + items.count
        )
    }

    // MARK: Search

    struct SearchResult {
        let items: [NuvioMeta]
        /// Every title of every result (romaji, English, native, synonyms) and its year,
        /// to recognise the same anime among Cinemeta's results.
        let names: [(name: String, year: Int?)]
        /// AniList was asked and didn't answer. Search then doesn't keep the results it shows,
        /// so the same search asks again instead of showing them without AniList.
        var failed = false

        static let empty = SearchResult(items: [], names: [])
        static let failure = SearchResult(items: [], names: [], failed: true)

        func matches(_ meta: NuvioMeta) -> Bool {
            let name = AniListService.matchKey(meta.name)
            guard !name.isEmpty else { return false }
            return names.contains { candidate in
                guard candidate.name == name else { return false }
                guard let year = candidate.year, let other = meta.year else { return true }
                return abs(year - other) <= 1
            }
        }
    }

    static func search(_ query: String) async -> SearchResult {
        guard AniListSettings.isEnabled else { return .empty }
        guard AniListSettings.searchesAniList else {
            AniListDiagnostics.note(.search, "Off: Search AniList is off")
            return .empty
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let quoted = "“\(trimmed)”"
        let answer: AniListClient.Answer
        do {
            answer = try await AniListClient.shared.answer(
                AniListQueries.search,
                variables: ["search": trimmed, "perPage": 30, "isAdult": isAdultVariable],
                ttl: searchTTL
            )
        } catch {
            AniListDiagnostics.note(.search, "\(quoted): failed: \(AniListDiagnostics.describe(error))")
            return .failure
        }
        let media: [AniListMedia]
        do {
            media = try decoder.decode(AniListPageResponse.self, from: answer.data).data?.Page?.media ?? []
        } catch {
            await AniListClient.shared.noteFailure("Unreadable search answer: \(error)")
            AniListDiagnostics.note(.search, "\(quoted): unreadable answer · \(AniListDiagnostics.source(answer))")
            return .failure
        }
        let films = media.filter(AniListMetaBuilder.isMovie).count
        AniListDiagnostics.note(
            .search,
            "\(quoted): \(media.count) results (\(media.count - films) series, \(films) films) · \(AniListDiagnostics.source(answer))"
        )
        let language = AniListSettings.titleLanguage
        var names: [(name: String, year: Int?)] = []
        for entry in media {
            let year = AniListMetaBuilder.year(entry)
            for title in [entry.title?.romaji, entry.title?.english, entry.title?.native] + (entry.synonyms ?? []).map(Optional.some) {
                let key = matchKey(title ?? "")
                if !key.isEmpty { names.append((name: key, year: year)) }
            }
        }
        return SearchResult(items: media.map { AniListMetaBuilder.card($0, language: language) }, names: names)
    }

    static func matchKey(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var key = ""
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            key.unicodeScalars.append(scalar)
        }
        return key
    }

    // MARK: Details

    enum DetailsError: Error {
        case notFound
    }

    /// The whole title for `anilist:ID`. With "One Title", an entry inside a series gives the
    /// series under its first entry's id.
    static func metadata(id: String) async throws -> NuvioMeta? {
        guard AniListSettings.isEnabled, let startID = AniListMetaBuilder.aniListID(from: id) else { return nil }
        let merge = AniListSettings.seasonMode == .merged
        let language = AniListSettings.titleLanguage

        var entries: [Int: AniListMedia] = [:]
        var pending = [startID]
        var chainIDs = [startID]
        var rounds = 0
        while !pending.isEmpty, rounds < 16 {
            rounds += 1
            for media in try await fetchEntries(pending) {
                entries[media.id] = media
            }
            guard entries[startID] != nil else { throw DetailsError.notFound }
            guard merge else { break }
            let chain = AniListMetaBuilder.chain(from: startID, entries: entries)
            chainIDs = chain.ids
            pending = chain.missing.filter { entries[$0] == nil }
        }

        let tabs = (merge ? chainIDs : [startID]).compactMap { entries[$0] }
        guard !tabs.isEmpty else { throw DetailsError.notFound }

        // api.ani.zip: titles and pictures of episodes, and TheTVDB's background and logo of
        // the series. It has no AniList rate limit.
        var aniZip: [Int: AniZipMappingsResponse] = [:]
        if AniListSettings.usesEpisodeDetails {
            await withTaskGroup(of: (Int, AniZipMappingsResponse?).self) { group in
                for tab in tabs {
                    group.addTask {
                        let response = await Self.aniZipMappings(entryID: tab.id, finished: tab.status == "FINISHED")
                        return (tab.id, response)
                    }
                }
                for await (id, response) in group {
                    aniZip[id] = response
                }
            }
        }

        var episodes: [Int: [NuvioVideo]] = [:]
        for (index, tab) in tabs.enumerated() {
            episodes[tab.id] = AniListMetaBuilder.episodes(of: tab, season: index + 1, aniZip: aniZip[tab.id]?.episodes ?? [:])
        }

        // Pictures of the first entry that has them, in tab order; with "Each Entry", a second
        // season without pictures takes its first season's.
        let isFilm = tabs.count == 1 && AniListMetaBuilder.isMovie(tabs[0])
        var artwork = AniListMetaBuilder.Artwork.empty
        if AniListSettings.usesEpisodeDetails {
            for tab in tabs where !artwork.isComplete {
                artwork = artwork.filled(by: await Self.entryArtwork(entryID: tab.id, aniZip: aniZip[tab.id], isFilm: isFilm))
            }
            if !isFilm {
                artwork = await Self.borrowingFromEarlierSeasons(artwork, entryID: tabs[0].id, known: tabs[0])
            }
        }

        guard let meta = AniListMetaBuilder.meta(tabs: tabs, episodes: episodes, language: language, artwork: artwork) else {
            throw DetailsError.notFound
        }
        AniListTitleIndex.store(
            metaID: meta.id,
            tabTitles: tabs.count > 1 ? AniListMetaBuilder.tabTitles(tabs, language: language) : [:],
            seasonByEntry: Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0 + 1) }),
            related: AniListMetaBuilder.related(tabs: tabs, language: language)
        )
        return meta
    }

    /// Entries by id, from disk while they are fresh: finished ones keep a week, airing ones an hour.
    private static func fetchEntries(_ ids: [Int]) async throws -> [AniListMedia] {
        let variables: [String: Any?] = ["ids": ids, "perPage": max(ids.count, 1)]
        if let cached = await AniListClient.shared.cached(AniListQueries.entries, variables: variables),
           let media = try? decoder.decode(AniListPageResponse.self, from: cached.data).data?.Page?.media,
           !media.isEmpty {
            let finished = media.allSatisfy { $0.status == "FINISHED" || $0.status == "CANCELLED" }
            if cached.age < (finished ? finishedTTL : airingTTL) {
                return media
            }
        }
        let data = try await AniListClient.shared.query(AniListQueries.entries, variables: variables, ttl: 0)
        return try decoder.decode(AniListPageResponse.self, from: data).data?.Page?.media ?? []
    }

    /// What api.ani.zip knows about one AniList entry: its episodes, TheTVDB's pictures of the
    /// series and its TMDB id. Kept a week for finished entries, a day for the rest.
    static func aniZipMappings(entryID: Int, finished: Bool) async -> AniZipMappingsResponse? {
        guard let url = URL(string: "https://api.ani.zip/mappings?anilist_id=\(entryID)"),
              let data = try? await AniListClient.shared.get(url, ttl: finished ? finishedTTL : aniZipTTL) else { return nil }
        return try? decoder.decode(AniZipMappingsResponse.self, from: data)
    }

    // MARK: Pictures

    /// The pictures of one entry: TheTVDB's by way of ani.zip, then what is missing from TMDB
    /// (with TMDB on in Settings, its key and artwork) and from Metahub, where Cinemeta takes
    /// its pictures. Both are found by ids, never by name: ani.zip's, or arm-server's IMDb id
    /// when ani.zip has none. A logo is taken only when it is one (`AniListClient.isLogo`), so
    /// a still never stands in the hero's title; with no logo, the title's name stays.
    static func entryArtwork(
        entryID: Int,
        aniZip: AniZipMappingsResponse?,
        isFilm: Bool
    ) async -> AniListMetaBuilder.Artwork {
        var artwork = AniListMetaBuilder.Artwork(background: aniZip?.fanart)
        artwork.logo = await checkedLogo(aniZip?.clearLogo)
        guard !artwork.isComplete else { return artwork }

        let mappings = aniZip?.mappings
        if let tmdbID = mappings?.themoviedbID,
           let found = await TmdbDetailsService.artwork(tmdbId: tmdbID, mediaType: isFilm ? "movie" : "tv") {
            artwork.background = artwork.background ?? found.background
            if artwork.logo == nil { artwork.logo = await checkedLogo(found.logo) }
        }
        guard !artwork.isComplete else { return artwork }

        var imdbID = mappings?.imdbID
        if imdbID == nil { imdbID = await armIMDbID(aniListID: entryID) }
        guard let imdbID, let metahub = metahubArtwork(imdbID: imdbID) else { return artwork }
        if artwork.logo == nil { artwork.logo = await checkedLogo(metahub.logo.absoluteString) }
        if artwork.background == nil, await AniListClient.shared.imageExists(metahub.background) {
            artwork.background = metahub.background.absoluteString
        }
        return artwork
    }

    private static func checkedLogo(_ candidate: String?) async -> String? {
        guard let candidate, let url = URL(string: candidate), await AniListClient.shared.isLogo(url) else { return nil }
        return candidate
    }

    /// What an entry still lacks, from its earlier seasons, at most three back: a second season
    /// new on ani.zip has no pictures yet, but its first has. `known` is the entry when its
    /// relations are at hand; otherwise each step asks AniList once and keeps the answer a week.
    static func borrowingFromEarlierSeasons(
        _ artwork: AniListMetaBuilder.Artwork,
        entryID: Int,
        known: AniListMedia?
    ) async -> AniListMetaBuilder.Artwork {
        var artwork = artwork
        var current = known?.id == entryID ? known : nil
        var currentID = entryID
        var seen: Set<Int> = [entryID]
        var steps = 0
        while steps < 3, !artwork.isComplete, !Task.isCancelled {
            steps += 1
            let media: AniListMedia?
            if let current, current.relations != nil {
                media = current
            } else {
                media = await prequels(of: currentID)
            }
            guard let media, let previousID = AniListMetaBuilder.previousSeason(of: media),
                  seen.insert(previousID).inserted else { break }
            let zip = await aniZipMappings(entryID: previousID, finished: true)
            artwork = artwork.filled(by: await entryArtwork(entryID: previousID, aniZip: zip, isFilm: false))
            current = nil
            currentID = previousID
        }
        return artwork
    }

    private static func prequels(of id: Int) async -> AniListMedia? {
        guard let data = try? await AniListClient.shared.query(
            AniListQueries.prequels, variables: ["id": id], ttl: finishedTTL, notesStatus: false
        ) else { return nil }
        return try? decoder.decode(AniListMediaResponse.self, from: data).data?.Media
    }

    /// The IMDb id arm-server has for an AniList entry. Kept a week.
    static func armIMDbID(aniListID: Int) async -> String? {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/ids?source=anilist&id=\(aniListID)"),
              let data = try? await AniListClient.shared.get(url, ttl: finishedTTL) else { return nil }
        return armIMDbID(in: data)
    }

    static func armIMDbID(in data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let imdb = object["imdb"] as? String else { return nil }
        let id = imdb.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("tt"), id.count > 2, id.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return id
    }

    /// Metahub's logo and background of an IMDb title, as Cinemeta gives them.
    static func metahubArtwork(imdbID: String) -> (logo: URL, background: URL)? {
        let id = imdbID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("tt"), id.count > 2, id.dropFirst(2).allSatisfy(\.isNumber),
              let logo = URL(string: "https://images.metahub.space/logo/medium/\(id)/img"),
              let background = URL(string: "https://images.metahub.space/background/medium/\(id)/img") else { return nil }
        return (logo, background)
    }

    /// The background and logo for Home's hero while an AniList card is focused, from ani.zip,
    /// TMDB and Metahub only, so moving along a row costs no AniList requests.
    static func heroArtwork(for card: NuvioMeta) async -> AniListMetaBuilder.Artwork? {
        guard AniListSettings.isEnabled, AniListSettings.usesEpisodeDetails,
              let entryID = AniListMetaBuilder.aniListID(from: card.id) else { return nil }
        let isFilm = card.type == "movie"
        let response = await aniZipMappings(entryID: entryID, finished: card.status == AniListMetaBuilder.status("FINISHED"))
        var artwork = await entryArtwork(entryID: entryID, aniZip: response, isFilm: isFilm)
        if !isFilm {
            artwork = await borrowingFromEarlierSeasons(artwork, entryID: entryID, known: nil)
        }
        return artwork == .empty ? nil : artwork
    }

    /// Characters with their Japanese voice actors, and AniList's recommendations.
    static func extras(metaID: String) async -> (people: [TmdbPersonMetadata], recommendations: [RelatedTitle]) {
        guard AniListSettings.isEnabled, let id = AniListMetaBuilder.aniListID(from: metaID),
              let data = try? await AniListClient.shared.query(AniListQueries.extras, variables: ["id": id], ttl: finishedTTL),
              let media = try? decoder.decode(AniListMediaResponse.self, from: data).data?.Media else {
            return ([], [])
        }
        let language = AniListSettings.titleLanguage
        let people = (media.characters?.edges ?? []).compactMap { edge -> TmdbPersonMetadata? in
            guard let name = edge.node?.name?.full, !name.isEmpty else { return nil }
            let voice = edge.voiceActors?.first?.name?.full
            let role = voice ?? (edge.role == "MAIN" ? "Main" : edge.role == "SUPPORTING" ? "Supporting" : nil)
            return TmdbPersonMetadata(name: name, role: role, profileURL: edge.node?.image?.large, tmdbId: nil)
        }
        let recommendations = (media.recommendations?.nodes ?? [])
            .filter { ($0.rating ?? 0) > 0 }
            .compactMap { $0.mediaRecommendation }
            .filter { $0.type == nil || $0.type == "ANIME" }
            .map { AniListMetaBuilder.relatedTitle($0, relation: nil, language: language) }
        return (people, recommendations)
    }

    static func clearCache() async {
        await AniListClient.shared.clearCache()
    }

    /// Asks AniList for "Frieren" right now, past the saved answers: "OK · 5 results" or why not.
    /// It leaves the status alone, so an earlier failure stays readable there.
    static func testConnection() async -> String {
        let variables: [String: Any?] = ["search": "Frieren", "perPage": 5, "isAdult": false]
        do {
            let answer = try await AniListClient.shared.answer(AniListQueries.search, variables: variables, ttl: 0, notesStatus: false)
            let media = try decoder.decode(AniListPageResponse.self, from: answer.data).data?.Page?.media ?? []
            let result = media.isEmpty ? "AniList answered with no results" : "OK · \(media.count) results"
            return answer.isSaved ? "\(result) · saved answer, AniList didn't answer now" : result
        } catch let error as DecodingError {
            return "Unreadable answer: \(error)"
        } catch {
            return "Failed: \(AniListDiagnostics.describe(error))"
        }
    }

    /// What Home's AniList rows last did, for Settings.
    static func homeStatusText() -> String {
        AniListSettings.isEnabled ? AniListDiagnostics.text(.home) : "Off"
    }

    /// What the last search did with AniList, for Settings.
    static func searchStatusText() -> String {
        AniListSettings.isEnabled ? AniListDiagnostics.text(.search) : "Off"
    }

    /// The service's own view, for Settings: is it on, and the last answer from AniList.
    static func statusText() async -> String {
        guard AniListSettings.isEnabled else { return "Off" }
        let status = await AniListClient.shared.status
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        func at(_ date: Date) -> String {
            DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        if let failure = status.lastFailure, failure > (status.lastSuccess ?? .distantPast) {
            return "Error at \(at(failure)): \(status.lastFailureMessage ?? "unknown")"
        }
        if let success = status.lastSuccess {
            return "OK · last answer at \(at(success))"
        }
        return "On · no request yet (\(time))"
    }
}

/// What the details screen needs about an AniList title beyond `NuvioMeta`: the names of its
/// tabs, the tab of each entry, and its Related row. Filled when the title loads.
enum AniListTitleIndex {
    private struct Entry {
        let tabTitles: [Int: String]
        let seasonByEntry: [Int: Int]
        let related: [RelatedTitle]
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    static func store(metaID: String, tabTitles: [Int: String], seasonByEntry: [Int: Int], related: [RelatedTitle]) {
        lock.lock()
        defer { lock.unlock() }
        entries[metaID.lowercased()] = Entry(tabTitles: tabTitles, seasonByEntry: seasonByEntry, related: related)
    }

    static func tabTitle(metaID: String, season: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[metaID.lowercased()]?.tabTitles[season]
    }

    /// The tab an entry opened from a card shows first: `anilist:182255` inside `anilist:154587`.
    static func season(ofEntry entryID: String, inMeta metaID: String) -> Int? {
        guard let entry = AniListMetaBuilder.aniListID(from: entryID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[metaID.lowercased()]?.seasonByEntry[entry]
    }

    static func related(metaID: String) -> [RelatedTitle] {
        lock.lock()
        defer { lock.unlock() }
        return entries[metaID.lowercased()]?.related ?? []
    }
}
