import Foundation

public enum TmdbError: Error, Equatable, Sendable {
    case missingApiKey
    case unauthorized
    case notFound
    case http(Int)
    case decoding(String)
}

// MARK: - DTOs

public struct TmdbEpisode: Decodable, Hashable, Sendable {
    public let airDate: String?
    public let episodeNumber: Int?
    public let seasonNumber: Int?
    public let name: String?
    public let overview: String?
    public let stillPath: String?
    public let episodeType: String?

    enum CodingKeys: String, CodingKey {
        case airDate = "air_date"
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
        case name, overview
        case stillPath = "still_path"
        case episodeType = "episode_type"
    }

    public init(airDate: String?, episodeNumber: Int?, seasonNumber: Int?, name: String? = nil,
                overview: String? = nil, stillPath: String? = nil, episodeType: String? = nil) {
        self.airDate = airDate
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.name = name
        self.overview = overview
        self.stillPath = stillPath
        self.episodeType = episodeType
    }
}

public struct TmdbSeasonSummary: Decodable, Hashable, Sendable {
    public let seasonNumber: Int?
    public let airDate: String?
    public let episodeCount: Int?

    enum CodingKeys: String, CodingKey {
        case seasonNumber = "season_number"
        case airDate = "air_date"
        case episodeCount = "episode_count"
    }

    public init(seasonNumber: Int?, airDate: String?, episodeCount: Int? = nil) {
        self.seasonNumber = seasonNumber
        self.airDate = airDate
        self.episodeCount = episodeCount
    }
}

public struct TmdbTvDetails: Decodable, Hashable, Sendable {
    public let id: Int
    public let name: String?
    public let posterPath: String?
    public let status: String?
    public let nextEpisodeToAir: TmdbEpisode?
    public let lastEpisodeToAir: TmdbEpisode?
    public let seasons: [TmdbSeasonSummary]?

    enum CodingKeys: String, CodingKey {
        case id, name, status, seasons
        case posterPath = "poster_path"
        case nextEpisodeToAir = "next_episode_to_air"
        case lastEpisodeToAir = "last_episode_to_air"
    }

    public init(id: Int, name: String?, posterPath: String? = nil, status: String? = nil,
                nextEpisodeToAir: TmdbEpisode? = nil, lastEpisodeToAir: TmdbEpisode? = nil,
                seasons: [TmdbSeasonSummary]? = nil) {
        self.id = id
        self.name = name
        self.posterPath = posterPath
        self.status = status
        self.nextEpisodeToAir = nextEpisodeToAir
        self.lastEpisodeToAir = lastEpisodeToAir
        self.seasons = seasons
    }
}

public struct TmdbSeasonDetails: Decodable, Hashable, Sendable {
    public let episodes: [TmdbEpisode]?
}

public struct TmdbReleaseDate: Decodable, Hashable, Sendable {
    public let releaseDate: String?
    /// 1 premiere, 2 limited theatrical, 3 theatrical, 4 digital, 5 physical, 6 TV.
    public let type: Int?

    enum CodingKeys: String, CodingKey {
        case releaseDate = "release_date"
        case type
    }

    public init(releaseDate: String?, type: Int?) {
        self.releaseDate = releaseDate
        self.type = type
    }
}

public struct TmdbCountryReleases: Decodable, Hashable, Sendable {
    public let country: String?
    public let releaseDates: [TmdbReleaseDate]?

    enum CodingKeys: String, CodingKey {
        case country = "iso_3166_1"
        case releaseDates = "release_dates"
    }

    public init(country: String?, releaseDates: [TmdbReleaseDate]?) {
        self.country = country
        self.releaseDates = releaseDates
    }
}

public struct TmdbMovieDetails: Decodable, Hashable, Sendable {
    public let id: Int
    public let title: String?
    public let posterPath: String?
    public let releaseDate: String?
    public let status: String?
    public let overview: String?
    public let releaseDates: ReleaseDatesContainer?

    public struct ReleaseDatesContainer: Decodable, Hashable, Sendable {
        public let results: [TmdbCountryReleases]?
        public init(results: [TmdbCountryReleases]?) { self.results = results }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, overview
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case releaseDates = "release_dates"
    }

    public init(id: Int, title: String?, posterPath: String? = nil, releaseDate: String? = nil,
                status: String? = nil, overview: String? = nil, countries: [TmdbCountryReleases]? = nil) {
        self.id = id
        self.title = title
        self.posterPath = posterPath
        self.releaseDate = releaseDate
        self.status = status
        self.overview = overview
        self.releaseDates = countries.map { ReleaseDatesContainer(results: $0) }
    }
}

public struct TmdbSearchResult: Decodable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let mediaType: String?
    public let title: String?
    public let name: String?
    public let posterPath: String?
    public let releaseDate: String?
    public let firstAirDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name
        case mediaType = "media_type"
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }

    public var displayTitle: String { title ?? name ?? "#\(id)" }
    /// Movies and series share the id space only per media type.
    public var uniqueKey: String { "\(mediaType ?? "?"):\(id)" }
    public var year: String? {
        let raw = releaseDate ?? firstAirDate ?? ""
        return raw.count >= 4 ? String(raw.prefix(4)) : nil
    }
    public var kind: MediaKind? {
        switch mediaType {
        case "tv": return .series
        case "movie": return .movie
        default: return nil
        }
    }
}

struct TmdbFindResponse: Decodable {
    struct Hit: Decodable { let id: Int }
    let movieResults: [Hit]?
    let tvResults: [Hit]?

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }
}

struct TmdbSearchResponse: Decodable {
    let results: [TmdbSearchResult]?
}

// MARK: - Client

public struct TmdbClient: Sendable {
    public static let imageBase = "https://image.tmdb.org/t/p/"

    public let apiKey: String
    public let language: String
    private let http: HTTPClient
    private let baseURL: URL

    public init(apiKey: String, language: String = "en-US", http: HTTPClient = URLSessionHTTPClient(),
                baseURL: URL = URL(string: "https://api.themoviedb.org/3")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.http = http
        self.baseURL = baseURL
    }

    public static func imageURL(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + size + path)
    }

    public func findByImdb(_ imdbId: String, kind: MediaKind) async throws -> Int? {
        let response: TmdbFindResponse = try await get(
            "find/\(imdbId)", query: ["external_source": "imdb_id"], localized: false
        )
        switch kind {
        case .series: return response.tvResults?.first?.id
        case .movie: return response.movieResults?.first?.id
        }
    }

    public func tvDetails(_ id: Int) async throws -> TmdbTvDetails {
        try await get("tv/\(id)")
    }

    public func season(_ tvId: Int, number: Int) async throws -> TmdbSeasonDetails {
        try await get("tv/\(tvId)/season/\(number)")
    }

    public func movieDetails(_ id: Int) async throws -> TmdbMovieDetails {
        try await get("movie/\(id)", query: ["append_to_response": "release_dates"])
    }

    public func search(_ text: String) async throws -> [TmdbSearchResult] {
        let response: TmdbSearchResponse = try await get(
            "search/multi", query: ["query": text, "include_adult": "false"]
        )
        return (response.results ?? []).filter { $0.kind != nil }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], localized: Bool = true) async throws -> T {
        guard !apiKey.isEmpty else { throw TmdbError.missingApiKey }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "api_key", value: apiKey)]
        if localized { items.append(URLQueryItem(name: "language", value: language)) }
        for key in query.keys.sorted() {
            items.append(URLQueryItem(name: key, value: query[key]))
        }
        components.queryItems = items
        guard let url = components.url else { throw TmdbError.http(0) }

        let (data, status) = try await http.get(url)
        switch status {
        case 200...299: break
        case 401: throw TmdbError.unauthorized
        case 404: throw TmdbError.notFound
        default: throw TmdbError.http(status)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TmdbError.decoding(String(describing: error))
        }
    }
}
