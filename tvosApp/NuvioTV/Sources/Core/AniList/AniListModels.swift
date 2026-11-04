import Foundation

/// The parts of AniList's GraphQL `Media` that Nuvio reads. Every field is optional: a query
/// asks only for what it needs, and AniList leaves out what it doesn't know.
struct AniListMedia: Decodable, Hashable {
    let id: Int
    var idMal: Int? = nil
    var type: String? = nil
    var format: String? = nil
    var status: String? = nil
    var episodes: Int? = nil
    var duration: Int? = nil
    var season: String? = nil
    var seasonYear: Int? = nil
    var averageScore: Int? = nil
    var genres: [String]? = nil
    var synonyms: [String]? = nil
    var isAdult: Bool? = nil
    var countryOfOrigin: String? = nil
    var source: String? = nil
    var title: AniListTitle? = nil
    var coverImage: AniListCoverImage? = nil
    var bannerImage: String? = nil
    var description: String? = nil
    var startDate: AniListDate? = nil
    var endDate: AniListDate? = nil
    var nextAiringEpisode: AniListAiring? = nil
    var airingSchedule: AniListAiringConnection? = nil
    var streamingEpisodes: [AniListStreamingEpisode]? = nil
    var trailer: AniListTrailer? = nil
    var studios: AniListStudioConnection? = nil
    var relations: AniListRelationConnection? = nil
    var characters: AniListCharacterConnection? = nil
    var recommendations: AniListRecommendationConnection? = nil
    var tags: [AniListTag]? = nil

    static func == (lhs: AniListMedia, rhs: AniListMedia) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct AniListTitle: Decodable, Hashable {
    var romaji: String? = nil
    var english: String? = nil
    var native: String? = nil
}

struct AniListCoverImage: Decodable, Hashable {
    var extraLarge: String? = nil
    var large: String? = nil
    var color: String? = nil
}

struct AniListDate: Decodable, Hashable {
    var year: Int? = nil
    var month: Int? = nil
    var day: Int? = nil
}

struct AniListAiring: Decodable, Hashable {
    let episode: Int
    let airingAt: Int
}

struct AniListAiringConnection: Decodable, Hashable {
    var nodes: [AniListAiring]? = nil
}

struct AniListStreamingEpisode: Decodable, Hashable {
    var title: String? = nil
    var thumbnail: String? = nil
}

struct AniListTrailer: Decodable, Hashable {
    var id: String? = nil
    var site: String? = nil
}

struct AniListStudioConnection: Decodable, Hashable {
    var nodes: [AniListStudio]? = nil
}

struct AniListStudio: Decodable, Hashable {
    let name: String
    var isAnimationStudio: Bool? = nil
}

struct AniListRelationConnection: Decodable, Hashable {
    var edges: [AniListRelationEdge]? = nil
}

struct AniListRelationEdge: Decodable, Hashable {
    var relationType: String? = nil
    var node: AniListMedia? = nil
}

struct AniListCharacterConnection: Decodable, Hashable {
    var edges: [AniListCharacterEdge]? = nil
}

struct AniListCharacterEdge: Decodable, Hashable {
    var role: String? = nil
    var node: AniListPerson? = nil
    var voiceActors: [AniListPerson]? = nil
}

struct AniListPerson: Decodable, Hashable {
    var id: Int? = nil
    var name: AniListName? = nil
    var image: AniListImage? = nil
}

struct AniListName: Decodable, Hashable {
    var full: String? = nil
}

struct AniListImage: Decodable, Hashable {
    var large: String? = nil
}

struct AniListRecommendationConnection: Decodable, Hashable {
    var nodes: [AniListRecommendation]? = nil
}

struct AniListRecommendation: Decodable, Hashable {
    var rating: Int? = nil
    var mediaRecommendation: AniListMedia? = nil
}

struct AniListTag: Decodable, Hashable {
    let name: String
    var rank: Int? = nil
    var isMediaSpoiler: Bool? = nil
}

struct AniListPage: Decodable {
    var pageInfo: AniListPageInfo? = nil
    var media: [AniListMedia]? = nil
}

struct AniListPageInfo: Decodable {
    var hasNextPage: Bool? = nil
}

/// `{ "data": { "Media": … } }`
struct AniListMediaResponse: Decodable {
    struct DataField: Decodable {
        let Media: AniListMedia?
    }
    let data: DataField?
}

/// `{ "data": { "Page": … } }`
struct AniListPageResponse: Decodable {
    struct DataField: Decodable {
        let Page: AniListPage?
    }
    let data: DataField?
}

/// `{ "data": { "<alias>": { "media": … }, … } }` for several pages in one request.
struct AniListAliasedPagesResponse: Decodable {
    let data: [String: AniListPage]?
}

/// One episode from api.ani.zip: titles, picture and summary that AniList itself lacks.
struct AniZipEpisode: Decodable, Hashable {
    var title: [String: String?]? = nil
    var image: String? = nil
    var overview: String? = nil
    var summary: String? = nil
    var airDateUtc: String? = nil

    var englishTitle: String? {
        guard let title else { return nil }
        for key in ["en", "x-jat"] {
            if let value = title[key] ?? nil {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

struct AniZipMappingsResponse: Decodable {
    var episodes: [String: AniZipEpisode]? = nil
}
