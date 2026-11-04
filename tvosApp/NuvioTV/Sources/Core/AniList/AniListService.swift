import Foundation

/// AniList inside Nuvio: Home rows, See All, Search and the details of `anilist:` titles,
/// all asked from this Apple TV. See `AniListMetaBuilder` for how entries become titles.
enum AniListService {
    static let addonID = "anilist"
    static let addonName = "AniList"
    /// Content type of the Home rows ("Trending Now - Anime").
    static let homeContentType = "anime"

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

    /// The AniList rows that Layout doesn't hide, in one request.
    static func homeCatalogs() async -> [NuvioCatalog] {
        guard AniListSettings.showsHomeRows else { return [] }
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
        let rows = AniListHomeRow.all.filter { !disabled.contains(catalogSettingsKey($0)) }
        guard !rows.isEmpty else { return [] }

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

        guard let data = try? await AniListClient.shared.query(
            AniListQueries.homeRows(rows), variables: variables, ttl: catalogTTL
        ),
            let pages = try? decoder.decode(AniListAliasedPagesResponse.self, from: data).data else {
            return []
        }

        let language = AniListSettings.titleLanguage
        return rows.compactMap { row in
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
    }

    /// See All for an AniList row.
    static func browse(catalogId: String, skip: Int, genre: String? = nil) async -> CatalogPage {
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

        static let empty = SearchResult(items: [], names: [])

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
        guard AniListSettings.searchesAniList else { return .empty }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = try? await AniListClient.shared.query(
                  AniListQueries.search,
                  variables: ["search": trimmed, "perPage": 30, "isAdult": isAdultVariable],
                  ttl: searchTTL
              ),
              let media = try? decoder.decode(AniListPageResponse.self, from: data).data?.Page?.media else {
            return .empty
        }
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

        let useAniZip = AniListSettings.usesEpisodeDetails && !(tabs.count == 1 && AniListMetaBuilder.isMovie(tabs[0]))
        var aniZip: [Int: [String: AniZipEpisode]] = [:]
        if useAniZip {
            await withTaskGroup(of: (Int, [String: AniZipEpisode]).self) { group in
                for tab in tabs {
                    group.addTask {
                        let episodes = await Self.aniZipEpisodes(for: tab)
                        return (tab.id, episodes)
                    }
                }
                for await (id, episodes) in group {
                    aniZip[id] = episodes
                }
            }
        }

        var episodes: [Int: [NuvioVideo]] = [:]
        for (index, tab) in tabs.enumerated() {
            episodes[tab.id] = AniListMetaBuilder.episodes(of: tab, season: index + 1, aniZip: aniZip[tab.id] ?? [:])
        }

        guard let meta = AniListMetaBuilder.meta(tabs: tabs, episodes: episodes, language: language) else {
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

    private static func aniZipEpisodes(for media: AniListMedia) async -> [String: AniZipEpisode] {
        guard let url = URL(string: "https://api.ani.zip/mappings?anilist_id=\(media.id)") else { return [:] }
        let ttl = media.status == "FINISHED" ? finishedTTL : aniZipTTL
        guard let data = try? await AniListClient.shared.get(url, ttl: ttl),
              let response = try? decoder.decode(AniZipMappingsResponse.self, from: data) else { return [:] }
        return response.episodes ?? [:]
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
