import Foundation

/// GraphQL queries sent to AniList. Each asks only for the fields Nuvio shows.
enum AniListQueries {
    /// What a card on Home or in Search needs.
    static let cardFields = """
    id idMal type format status episodes season seasonYear averageScore genres synonyms isAdult
    title { romaji english native }
    coverImage { extraLarge large color }
    bannerImage
    description(asHtml: false)
    startDate { year month day }
    """

    /// What a card in a relations row needs.
    static let relationNodeFields = """
    id type format status episodes seasonYear
    title { romaji english native }
    coverImage { extraLarge large }
    startDate { year month day }
    """

    /// What one entry of a title needs: its own details, its episodes and its relations.
    static let entryFields = """
    \(cardFields)
    duration source countryOfOrigin
    endDate { year month day }
    nextAiringEpisode { episode airingAt }
    airingSchedule(perPage: 50) { nodes { episode airingAt } }
    streamingEpisodes { title thumbnail }
    trailer { id site }
    studios(isMain: true) { nodes { name isAnimationStudio } }
    relations { edges { relationType node { \(relationNodeFields) } } }
    """

    /// Entries by id, with their episodes and relations. Following a series from season to
    /// season asks for the next ones the same way.
    static let entries = """
    query ($ids: [Int], $perPage: Int) {
      Page(perPage: $perPage) {
        media(id_in: $ids, type: ANIME) { \(entryFields) }
      }
    }
    """

    /// One page of a catalog.
    static let catalog = """
    query ($page: Int, $perPage: Int, $sort: [MediaSort], $season: MediaSeason, $seasonYear: Int, $genre: String, $isAdult: Boolean) {
      Page(page: $page, perPage: $perPage) {
        pageInfo { hasNextPage }
        media(type: ANIME, sort: $sort, season: $season, seasonYear: $seasonYear, genre: $genre, isAdult: $isAdult) { \(cardFields) }
      }
    }
    """

    static let search = """
    query ($search: String, $perPage: Int, $isAdult: Boolean) {
      Page(perPage: $perPage) {
        media(search: $search, type: ANIME, sort: [SEARCH_MATCH], isAdult: $isAdult) { \(cardFields) }
      }
    }
    """

    /// Characters with their Japanese voice actors, and recommendations, for a title's details.
    static let extras = """
    query ($id: Int) {
      Media(id: $id, type: ANIME) {
        id
        characters(sort: [ROLE, RELEVANCE, ID], perPage: 25) {
          edges {
            role
            node { id name { full } image { large } }
            voiceActors(language: JAPANESE, sort: [RELEVANCE, ID]) { id name { full } image { large } }
          }
        }
        recommendations(sort: [RATING_DESC, ID], perPage: 20) {
          nodes { rating mediaRecommendation { \(relationNodeFields) averageScore description(asHtml: false) bannerImage } }
        }
      }
    }
    """

    /// All Home rows in a single request.
    static func homeRows(_ rows: [AniListHomeRow]) -> String {
        let pages = rows.map { row in
            "\(row.id): Page(perPage: $perPage) { media(type: ANIME, \(row.arguments), isAdult: $isAdult) { \(cardFields) } }"
        }
        // GraphQL refuses a declared variable that no row uses.
        var declarations = ["$perPage: Int", "$isAdult: Boolean"]
        if rows.contains(where: \.usesSeason) {
            declarations += ["$season: MediaSeason", "$seasonYear: Int"]
        }
        if rows.contains(where: \.usesNextSeason) {
            declarations += ["$nextSeason: MediaSeason", "$nextSeasonYear: Int"]
        }
        return """
        query (\(declarations.joined(separator: ", "))) {
          \(pages.joined(separator: "\n  "))
        }
        """
    }
}

/// The AniList rows offered on Home.
struct AniListHomeRow: Hashable {
    let id: String
    let title: String
    /// Arguments for `media(…)` beside the type and the adult filter.
    let arguments: String
    let sort: [String]
    let usesSeason: Bool
    let usesNextSeason: Bool

    static let all: [AniListHomeRow] = [
        AniListHomeRow(id: "trending", title: "Trending Now", arguments: "sort: [TRENDING_DESC, POPULARITY_DESC]",
                       sort: ["TRENDING_DESC", "POPULARITY_DESC"], usesSeason: false, usesNextSeason: false),
        AniListHomeRow(id: "season", title: "Popular This Season", arguments: "season: $season, seasonYear: $seasonYear, sort: [POPULARITY_DESC]",
                       sort: ["POPULARITY_DESC"], usesSeason: true, usesNextSeason: false),
        AniListHomeRow(id: "nextseason", title: "Upcoming Next Season", arguments: "season: $nextSeason, seasonYear: $nextSeasonYear, sort: [POPULARITY_DESC]",
                       sort: ["POPULARITY_DESC"], usesSeason: false, usesNextSeason: true),
        AniListHomeRow(id: "popular", title: "All-Time Popular", arguments: "sort: [POPULARITY_DESC]",
                       sort: ["POPULARITY_DESC"], usesSeason: false, usesNextSeason: false),
        AniListHomeRow(id: "top", title: "Top 100", arguments: "sort: [SCORE_DESC]",
                       sort: ["SCORE_DESC"], usesSeason: false, usesNextSeason: false),
    ]

    static func row(id: String) -> AniListHomeRow? {
        all.first { $0.id == id }
    }
}

/// AniList's broadcast seasons: Winter (January–March), Spring, Summer, Fall.
enum AniListSeason {
    static func current(at date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> (season: String, year: Int) {
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        return (name(forMonth: month), year)
    }

    static func next(at date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> (season: String, year: Int) {
        let month = calendar.component(.month, from: date)
        let year = calendar.component(.year, from: date)
        let nextMonth = month + 3
        return nextMonth > 12 ? (name(forMonth: nextMonth - 12), year + 1) : (name(forMonth: nextMonth), year)
    }

    private static func name(forMonth month: Int) -> String {
        switch month {
        case 1...3: return "WINTER"
        case 4...6: return "SPRING"
        case 7...9: return "SUMMER"
        default: return "FALL"
        }
    }
}
