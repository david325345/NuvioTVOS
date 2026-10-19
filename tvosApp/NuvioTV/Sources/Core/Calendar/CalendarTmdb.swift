import Foundation

protocol CalendarHTTPClient: Sendable {
    /// Returns the body and status code. Throws only on transport failures.
    func get(_ url: URL) async throws -> (Data, Int)
}

struct CalendarURLSessionClient: CalendarHTTPClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum CalendarTmdbError: Error, Equatable, Sendable {
    case missingApiKey
    case unauthorized
    case notFound
    case http(Int)
    case decoding
}

enum CalendarText {
    /// True when the text is written in Japanese, Chinese or Korean script.
    static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F:
                return true
            default:
                return false
            }
        }
    }
}

/// The few TMDB endpoints the calendar needs, decoded into minimal shapes.
enum CalendarTmdb {
    static let imageBase = "https://image.tmdb.org/t/p/"

    static func imageURL(_ path: String?, size: String) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: imageBase + size + path)
    }

    struct Episode: Decodable, Hashable, Sendable {
        let airDate: String?
        let episodeNumber: Int?
        let seasonNumber: Int?
        let name: String?
        let overview: String?
        let stillPath: String?
        let episodeType: String?

        enum CodingKeys: String, CodingKey {
            case airDate = "air_date"
            case episodeNumber = "episode_number"
            case seasonNumber = "season_number"
            case name, overview
            case stillPath = "still_path"
            case episodeType = "episode_type"
        }

        init(airDate: String?, episodeNumber: Int?, seasonNumber: Int?, name: String? = nil,
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

    struct SeasonSummary: Decodable, Hashable, Sendable {
        let seasonNumber: Int?
        let airDate: String?

        enum CodingKeys: String, CodingKey {
            case seasonNumber = "season_number"
            case airDate = "air_date"
        }

        init(seasonNumber: Int?, airDate: String?) {
            self.seasonNumber = seasonNumber
            self.airDate = airDate
        }
    }

    struct TvDetails: Decodable, Hashable, Sendable {
        let id: Int
        let name: String?
        let posterPath: String?
        let nextEpisodeToAir: Episode?
        let lastEpisodeToAir: Episode?
        let seasons: [SeasonSummary]?
        let genres: [Genre]?
        let originCountry: [String]?
        let translations: Translations?

        struct Genre: Decodable, Hashable, Sendable { let id: Int }

        struct Translations: Decodable, Hashable, Sendable {
            struct Item: Decodable, Hashable, Sendable {
                struct Payload: Decodable, Hashable, Sendable { let name: String? }
                let language: String?
                let data: Payload?
                enum CodingKeys: String, CodingKey {
                    case language = "iso_639_1"
                    case data
                }
            }
            let translations: [Item]?
        }

        enum CodingKeys: String, CodingKey {
            case id, name, seasons, genres, translations
            case posterPath = "poster_path"
            case nextEpisodeToAir = "next_episode_to_air"
            case lastEpisodeToAir = "last_episode_to_air"
            case originCountry = "origin_country"
        }

        /// A name the viewer can read: the localized one, or English when
        /// TMDB fell back to Japanese, Chinese or Korean script.
        var readableName: String? {
            if let name, !name.isEmpty, !CalendarText.isCJK(name) { return name }
            let english = translations?.translations?
                .first { $0.language == "en" }?.data?.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let english, !english.isEmpty, !CalendarText.isCJK(english) { return english }
            return nil
        }

        init(id: Int, name: String?, posterPath: String? = nil, nextEpisodeToAir: Episode? = nil,
             lastEpisodeToAir: Episode? = nil, seasons: [SeasonSummary]? = nil,
             genres: [Genre]? = nil, originCountry: [String]? = nil, translations: Translations? = nil) {
            self.id = id
            self.name = name
            self.posterPath = posterPath
            self.nextEpisodeToAir = nextEpisodeToAir
            self.lastEpisodeToAir = lastEpisodeToAir
            self.seasons = seasons
            self.genres = genres
            self.originCountry = originCountry
            self.translations = translations
        }

        /// Japanese animation: TMDB dates these by the Japanese broadcast day.
        var isJapaneseAnime: Bool {
            (genres ?? []).contains { $0.id == 16 } && (originCountry ?? []).contains("JP")
        }
    }

    struct SeasonDetails: Decodable, Hashable, Sendable {
        let episodes: [Episode]?
    }

    struct ReleaseDate: Decodable, Hashable, Sendable {
        let releaseDate: String?
        /// 1 premiere, 2 limited theatrical, 3 theatrical, 4 digital, 5 physical, 6 TV.
        let type: Int?

        enum CodingKeys: String, CodingKey {
            case releaseDate = "release_date"
            case type
        }

        init(releaseDate: String?, type: Int?) {
            self.releaseDate = releaseDate
            self.type = type
        }
    }

    struct CountryReleases: Decodable, Hashable, Sendable {
        let country: String?
        let releaseDates: [ReleaseDate]?

        enum CodingKeys: String, CodingKey {
            case country = "iso_3166_1"
            case releaseDates = "release_dates"
        }

        init(country: String?, releaseDates: [ReleaseDate]?) {
            self.country = country
            self.releaseDates = releaseDates
        }
    }

    struct MovieDetails: Decodable, Hashable, Sendable {
        let id: Int
        let title: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let overview: String?
        let releaseDates: ReleaseDatesContainer?

        struct ReleaseDatesContainer: Decodable, Hashable, Sendable {
            let results: [CountryReleases]?
        }

        enum CodingKeys: String, CodingKey {
            case id, title, overview
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case releaseDate = "release_date"
            case releaseDates = "release_dates"
        }

        init(id: Int, title: String?, posterPath: String? = nil, backdropPath: String? = nil,
             releaseDate: String? = nil, overview: String? = nil, countries: [CountryReleases]? = nil) {
            self.id = id
            self.title = title
            self.posterPath = posterPath
            self.backdropPath = backdropPath
            self.releaseDate = releaseDate
            self.overview = overview
            self.releaseDates = countries.map { ReleaseDatesContainer(results: $0) }
        }
    }

    /// One title from a TMDB list or discover query.
    struct ListResult: Decodable, Hashable, Identifiable, Sendable {
        let id: Int
        let name: String?
        let title: String?
        let posterPath: String?
        let firstAirDate: String?
        let releaseDate: String?

        enum CodingKeys: String, CodingKey {
            case id, name, title
            case posterPath = "poster_path"
            case firstAirDate = "first_air_date"
            case releaseDate = "release_date"
        }

        var displayTitle: String { title ?? name ?? "#\(id)" }
        var year: Int? { (releaseDate ?? firstAirDate).flatMap { Int($0.prefix(4)) } }
    }

    struct ListPage: Decodable, Sendable {
        let results: [ListResult]?
        let totalPages: Int?

        enum CodingKeys: String, CodingKey {
            case results
            case totalPages = "total_pages"
        }
    }

    struct ExternalIds: Decodable, Sendable {
        let imdbId: String?
        enum CodingKeys: String, CodingKey { case imdbId = "imdb_id" }
    }

    struct Client: Sendable {
        let apiKey: String
        let language: String
        private let http: CalendarHTTPClient
        private let baseURL: URL

        init(apiKey: String, language: String = "en-US", http: CalendarHTTPClient = CalendarURLSessionClient(),
             baseURL: URL = URL(string: "https://api.themoviedb.org/3")!) {
            self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.language = language
            self.http = http
            self.baseURL = baseURL
        }

        func tvDetails(_ id: Int) async throws -> TvDetails {
            // Translations ride along so CJK fallback names can be swapped for English.
            try await get("tv/\(id)", query: ["append_to_response": "translations"])
        }

        func season(_ tvId: Int, number: Int) async throws -> SeasonDetails {
            try await get("tv/\(tvId)/season/\(number)")
        }

        func movieDetails(_ id: Int) async throws -> MovieDetails {
            try await get("movie/\(id)", query: ["append_to_response": "release_dates"])
        }

        func list(_ path: String, query: [String: String] = [:], pages: Int = 2) async throws -> [ListResult] {
            var all: [ListResult] = []
            var seen = Set<Int>()
            for page in 1...max(1, pages) {
                var q = query
                q["page"] = String(page)
                let response: ListPage = try await get(path, query: q)
                var results = response.results ?? []
                // TMDB falls back to the original Japanese/Chinese/Korean title
                // when there's no translation; fetch the page in English then.
                if !Self.readsCJK(language), results.contains(where: { CalendarText.isCJK($0.displayTitle) }),
                   let english: ListPage = try? await get(path, query: q, language: "en-US") {
                    let names = Dictionary((english.results ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    results = results.map { result in
                        guard CalendarText.isCJK(result.displayTitle), let en = names[result.id],
                              !CalendarText.isCJK(en.displayTitle) else { return result }
                        return ListResult(id: result.id, name: en.name, title: en.title, posterPath: result.posterPath,
                                          firstAirDate: result.firstAirDate, releaseDate: result.releaseDate)
                    }
                }
                for result in results where seen.insert(result.id).inserted {
                    all.append(result)
                }
                if let total = response.totalPages, page >= total { break }
            }
            return all
        }

        func imdbId(tmdbId: Int, kind: CalendarMediaKind) async throws -> String? {
            let media = kind == .series ? "tv" : "movie"
            let ids: ExternalIds = try await get("\(media)/\(tmdbId)/external_ids")
            guard let imdb = ids.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines), imdb.hasPrefix("tt") else {
                return nil
            }
            return imdb
        }

        /// The viewer reads these scripts, so native titles are fine.
        static func readsCJK(_ language: String) -> Bool {
            let code = language.lowercased()
            return code.hasPrefix("ja") || code.hasPrefix("zh") || code.hasPrefix("ko")
        }

        func get<T: Decodable>(_ path: String, query: [String: String] = [:], language: String? = nil) async throws -> T {
            guard !apiKey.isEmpty else { throw CalendarTmdbError.missingApiKey }
            guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
                throw CalendarTmdbError.http(0)
            }
            var items = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "language", value: language ?? self.language),
            ]
            for key in query.keys.sorted() {
                items.append(URLQueryItem(name: key, value: query[key]))
            }
            components.queryItems = items
            guard let url = components.url else { throw CalendarTmdbError.http(0) }

            let (data, status) = try await http.get(url)
            switch status {
            case 200...299: break
            case 401: throw CalendarTmdbError.unauthorized
            case 404: throw CalendarTmdbError.notFound
            default: throw CalendarTmdbError.http(status)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw CalendarTmdbError.decoding
            }
        }
    }
}
