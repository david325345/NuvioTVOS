import Foundation

extension SettingsKey {
    static let aniListReviews = "nuvio.tv.settings.integrations.aniListReviews"
    static let malReviews = "nuvio.tv.settings.integrations.malReviews"
}

/// Reviews of an anime from AniList and MAL in details (Settings → AniList → AniList Reviews,
/// Settings → MAL → MAL Reviews), for any anime the offline tables map, whichever source the
/// title is from: an AniList, MAL or Kitsu title, or one from Cinemeta or an add-on. Each works
/// with its integration off and without logging in; never switched, it follows the integration
/// being on. The most liked first, kept a day.
enum AnimeReviews {
    static let limit = 10
    static let ttl: TimeInterval = 24 * 3600

    static var showsAniList: Bool { shows(SettingsKey.aniListReviews, AniListSettings.isEnabled(in:)) }
    static var showsMAL: Bool { shows(SettingsKey.malReviews, MALSettings.isEnabled(in:)) }

    static func shows(_ key: String, _ followsEnabled: (UserDefaults) -> Bool, in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.object(forKey: key) == nil ? followsEnabled(store) : store.bool(forKey: key)
    }

    // MARK: Which entry

    /// The AniList entry of an anime: its own, or the one its MAL, Kitsu, Cinemeta or TMDB id maps
    /// to (offline tables only). A series with One Title is its first season.
    static func aniListEntry(for meta: NuvioMeta) async -> Int? {
        let maps = AniListOfflineMaps.shared
        guard let own = AnimeSource.entry(from: meta.id) else { return await AniListService.mappedEntry(for: meta) }
        switch own.source {
        case .anilist: return own.id
        case .mal: return await maps.aniListID(mal: own.id)
        case .kitsu: return await maps.aniListID(kitsu: own.id)
        }
    }

    /// The MAL entry of an anime: a MAL title's own, else the one of its AniList entry.
    static func malEntry(for meta: NuvioMeta) async -> Int? {
        if let own = AnimeSource.entry(from: meta.id), own.source == .mal { return own.id }
        guard let aniList = await aniListEntry(for: meta),
              let mal = await AniListOfflineMaps.shared.entry(aniListID: aniList)?.mal, mal > 0 else { return nil }
        return mal
    }

    // MARK: AniList

    static let aniListQuery = """
    query ($id: Int, $perPage: Int) {
      Media(id: $id, type: ANIME) {
        id
        reviews(sort: [RATING_DESC], perPage: $perPage) {
          nodes { id summary body score rating ratingAmount createdAt user { name } }
        }
      }
    }
    """

    /// AniList's reviews of the anime (AniList Reviews on); none when it isn't mapped or AniList
    /// can't answer.
    static func aniList(for meta: NuvioMeta) async -> [TraktCommentReview] {
        guard showsAniList, let id = await aniListEntry(for: meta),
              let data = try? await AniListClient.shared.query(
                  aniListQuery, variables: ["id": id, "perPage": limit], ttl: ttl, notesStatus: false
              ) else { return [] }
        return aniListReviews(from: data)
    }

    static func aniListReviews(from data: Data) -> [TraktCommentReview] {
        struct Answer: Decodable {
            struct DataField: Decodable { let Media: MediaField? }
            struct MediaField: Decodable { let reviews: Reviews? }
            struct Reviews: Decodable { let nodes: [Review]? }
            struct Review: Decodable {
                let id: Int
                var summary: String? = nil
                var body: String? = nil
                var score: Int? = nil
                var rating: Int? = nil
                var createdAt: Int? = nil
                var user: User? = nil
            }
            struct User: Decodable { var name: String? = nil }
            let data: DataField?
        }
        let reviews = (try? JSONDecoder().decode(Answer.self, from: data))?.data?.Media?.reviews?.nodes ?? []
        return reviews.compactMap { review -> TraktCommentReview? in
            let body = aniListText(review.body ?? "")
            let summary = review.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty || summary?.isEmpty == false else { return nil }
            var item = TraktCommentReview(
                id: Int64(review.id),
                author: review.user?.name ?? "AniList",
                comment: body.isEmpty ? (summary ?? "") : body,
                likes: max(review.rating ?? 0, 0),
                spoiler: false,
                rating: nil,
                createdAt: review.createdAt.map(isoDay)
            )
            item.summary = summary?.isEmpty == false ? summary : nil
            item.scoreText = review.score.flatMap { $0 > 0 ? "\($0)%" : nil }
            return item
        }
    }

    /// AniList's review text (its own markdown with a little HTML) as plain text: pictures and
    /// videos out, spoilers as "[Spoiler]", formatting gone, links as their text.
    static func aniListText(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rules: [(String, String)] = [
            (#"(?i)img\d*%?\s*\([^)]*\)"#, ""),
            (#"(?i)(youtube|webm)\s*\([^)]*\)"#, ""),
            (#"(?s)~!.*?!~"#, "[Spoiler]"),
            (#"~~~"#, ""),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"~~(.+?)~~"#, "$1"),
            (#"(?m)^\s*[-*_]{3,}\s*$"#, ""),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return AniListMetaBuilder.plainText(text) ?? ""
    }

    static func isoDay(_ seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // MARK: MAL

    /// MAL's reviews of the anime through Tenrai (MAL Reviews on; MAL's own API has none), the
    /// most liked first; reviews MAL marks as spoilers are hidden until opened.
    static func mal(for meta: NuvioMeta) async -> [TraktCommentReview] {
        guard showsMAL, let id = await malEntry(for: meta),
              let data = try? await AniListClient.$isInteractive.withValue(true, operation: {
                  try await TenraiClient.shared.get(
                      "anime/\(id)/reviews", query: [("spoilers", "true"), ("preliminary", "true")], ttl: ttl
                  )
              }) else { return [] }
        return malReviews(from: data)
    }

    static func malReviews(from data: Data) -> [TraktCommentReview] {
        struct Review: Decodable {
            let malId: Int
            var review: String? = nil
            var score: Int? = nil
            var date: String? = nil
            var tags: [String]? = nil
            var isSpoiler: Bool? = nil
            var reactions: Reactions? = nil
            var user: User? = nil
            struct Reactions: Decodable { var overall: Int? = nil }
            struct User: Decodable { var username: String? = nil }
        }
        let reviews = (try? MALSource.decoder.decode(TenraiMany<Review>.self, from: data).data) ?? []
        let liked = reviews.enumerated().sorted { lhs, rhs in
            let left = lhs.element.reactions?.overall ?? 0, right = rhs.element.reactions?.overall ?? 0
            return left != right ? left > right : lhs.offset < rhs.offset
        }
        return liked.prefix(limit).compactMap { pair -> TraktCommentReview? in
            let review = pair.element
            let text = (review.review ?? "").replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var item = TraktCommentReview(
                id: Int64(review.malId),
                author: review.user?.username ?? "MAL",
                comment: text,
                likes: max(review.reactions?.overall ?? 0, 0),
                spoiler: review.isSpoiler == true,
                rating: review.score,
                createdAt: review.date
            )
            item.scoreText = review.score.flatMap { $0 > 0 ? "\($0)/10" : nil }
            item.tag = review.tags?.first { !$0.isEmpty }
            return item
        }
    }
}
