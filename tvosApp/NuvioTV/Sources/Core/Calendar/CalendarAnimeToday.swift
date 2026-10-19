import Foundation

/// "Anime today" built from AniList's airing schedule, which has exact
/// broadcast times, so the list follows the Apple TV's own day instead of the
/// Japanese date TMDB uses. TMDB and IMDb ids come from Simkl by AniList id
/// (needs only the Simkl Client ID, no login). Without a Client ID the
/// suggestions fall back to the TMDB list.
enum CalendarAnimeToday {
    struct Airing: Hashable, Sendable {
        let anilistId: Int
        let title: String
        let posterURL: URL?
        let airingAt: Date
        let episode: Int?
        let year: Int?
        let isMovie: Bool
    }

    struct Ids: Hashable, Sendable {
        let tmdb: Int?
        let imdb: String?
    }

    static var isAvailable: Bool { SimklConfig.isConfigured }

    /// Start and end (exclusive) of the local day containing `date`.
    static func dayBounds(of date: Date, timeZone: TimeZone = .current) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    /// Loads today's Japanese anime and resolves their ids. Titles Simkl
    /// doesn't know are kept but can't be added (no TMDB or IMDb id).
    static func load(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        http: CalendarAnimeHTTPClient = CalendarAnimeURLSessionClient(),
        clientID: String = SimklConfig.clientID
    ) async throws -> [CalendarSuggestionItem] {
        let bounds = dayBounds(of: now, timeZone: timeZone)
        let airings = try await AniList(http: http).airings(from: bounds.start, to: bounds.end)
        let simkl = Simkl(http: http, clientID: clientID)
        let ids = await simkl.ids(for: airings.map(\.anilistId))
        return items(airings, ids: ids, timeZone: timeZone)
    }

    static func items(_ airings: [Airing], ids: [Int: Ids], timeZone: TimeZone = .current) -> [CalendarSuggestionItem] {
        var seen = Set<String>()
        var result: [CalendarSuggestionItem] = []
        for airing in airings.sorted(by: { $0.airingAt < $1.airingAt }) {
            let found = ids[airing.anilistId]
            let kind: CalendarMediaKind = airing.isMovie ? .movie : .series
            let key: String
            if let tmdb = found?.tmdb {
                key = CalendarSuggestions.key(kind: kind, tmdbId: tmdb)
            } else if let imdb = found?.imdb {
                key = "\(kind.rawValue):\(imdb)"
            } else {
                key = "anilist:\(airing.anilistId)"
            }
            guard seen.insert(key).inserted else { continue }
            result.append(CalendarSuggestionItem(
                key: key,
                kind: kind,
                tmdbId: found?.tmdb,
                imdbId: found?.imdb,
                title: airing.title,
                posterURL: airing.posterURL,
                year: airing.year,
                detail: detail(for: airing, timeZone: timeZone)
            ))
        }
        return result
    }

    static func detail(for airing: Airing, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocaleManager.shared.locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        let time = formatter.string(from: airing.airingAt)
        guard let episode = airing.episode else { return time }
        return "\(time) · " + L10n.format("calendar_episode_short", fallback: "Ep %d", episode)
    }

    // MARK: - AniList

    struct AniList: Sendable {
        let http: CalendarAnimeHTTPClient
        static let endpoint = URL(string: "https://graphql.anilist.co")!
        static let maxPages = 10

        static let query = """
        query ($page: Int, $from: Int, $to: Int) {
          Page(page: $page, perPage: 50) {
            pageInfo { hasNextPage }
            airingSchedules(airingAt_greater: $from, airingAt_lesser: $to, sort: TIME) {
              airingAt
              episode
              media {
                id format countryOfOrigin isAdult
                title { romaji english }
                coverImage { large }
                startDate { year }
              }
            }
          }
        }
        """

        struct Response: Decodable {
            struct DataBlock: Decodable { let Page: PageBlock? }
            struct PageBlock: Decodable {
                let pageInfo: PageInfo?
                let airingSchedules: [Schedule]?
            }
            struct PageInfo: Decodable { let hasNextPage: Bool? }
            struct Schedule: Decodable {
                let airingAt: Int
                let episode: Int?
                let media: Media?
            }
            struct Media: Decodable {
                let id: Int
                let format: String?
                let countryOfOrigin: String?
                let isAdult: Bool?
                let title: Title?
                let coverImage: Cover?
                let startDate: StartDate?
            }
            struct Title: Decodable { let romaji: String?; let english: String? }
            struct Cover: Decodable { let large: String? }
            struct StartDate: Decodable { let year: Int? }
            let data: DataBlock?
        }

        /// Japanese, non-adult titles airing in [from, to), one per title
        /// (its first episode in the window).
        func airings(from: Date, to: Date) async throws -> [Airing] {
            var byId: [Int: Airing] = [:]
            var order: [Int] = []
            for page in 1...Self.maxPages {
                let variables: [String: Int] = [
                    "page": page,
                    // airingAt_greater is exclusive.
                    "from": Int(from.timeIntervalSince1970) - 1,
                    "to": Int(to.timeIntervalSince1970),
                ]
                let body = try JSONSerialization.data(withJSONObject: ["query": Self.query, "variables": variables])
                let (data, status) = try await http.post(Self.endpoint, json: body)
                guard (200..<300).contains(status) else { throw CalendarTmdbError.http(status) }
                guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
                    throw CalendarTmdbError.decoding
                }
                let block = decoded.data?.Page
                for schedule in block?.airingSchedules ?? [] {
                    guard let media = schedule.media,
                          media.isAdult != true,
                          media.countryOfOrigin == "JP",
                          byId[media.id] == nil else { continue }
                    let title = [media.title?.english, media.title?.romaji]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty } ?? "AniList #\(media.id)"
                    byId[media.id] = Airing(
                        anilistId: media.id,
                        title: title,
                        posterURL: media.coverImage?.large.flatMap(URL.init(string:)),
                        airingAt: Date(timeIntervalSince1970: TimeInterval(schedule.airingAt)),
                        episode: schedule.episode,
                        year: media.startDate?.year,
                        isMovie: media.format == "MOVIE"
                    )
                    order.append(media.id)
                }
                if block?.pageInfo?.hasNextPage != true { break }
            }
            return order.compactMap { byId[$0] }
        }
    }

    // MARK: - Simkl

    /// Ids already looked up this session, so switching lists back and forth
    /// doesn't ask Simkl again.
    actor IdCache {
        static let shared = IdCache()
        private var values: [Int: Ids] = [:]
        func get(_ id: Int) -> Ids? { values[id] }
        func set(_ id: Int, _ ids: Ids) { values[id] = ids }
    }

    struct Simkl: Sendable {
        let http: CalendarAnimeHTTPClient
        let clientID: String
        var cache: IdCache = .shared
        static let maxConcurrent = 4

        private var appQuery: [URLQueryItem] {
            [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "app-name", value: SimklConfig.appName),
                URLQueryItem(name: "app-version", value: SimklConfig.appVersion),
            ]
        }

        private var headers: [String: String] {
            [
                "User-Agent": SimklConfig.userAgent,
                "simkl-api-key": clientID,
                "Accept": "application/json",
            ]
        }

        func ids(for anilistIds: [Int]) async -> [Int: Ids] {
            guard !clientID.isEmpty else { return [:] }
            var result: [Int: Ids] = [:]
            var pending: [Int] = []
            for id in anilistIds {
                if let cached = await cache.get(id) { result[id] = cached } else { pending.append(id) }
            }
            await withTaskGroup(of: (Int, Ids?).self) { group in
                var index = 0
                while index < min(Self.maxConcurrent, pending.count) {
                    let id = pending[index]
                    group.addTask { (id, await lookup(anilistId: id)) }
                    index += 1
                }
                while let pair = await group.next() {
                    if let ids = pair.1 {
                        result[pair.0] = ids
                        await cache.set(pair.0, ids)
                    }
                    if index < pending.count {
                        let id = pending[index]
                        group.addTask { (id, await lookup(anilistId: id)) }
                        index += 1
                    }
                }
            }
            return result
        }

        /// nil = request failed (try again next time); empty Ids = not on Simkl.
        func lookup(anilistId: Int) async -> Ids? {
            var redirect = URLComponents(string: SimklConfig.apiBaseURL + "/redirect")!
            redirect.queryItems = [
                URLQueryItem(name: "to", value: "simkl"),
                URLQueryItem(name: "anilist", value: String(anilistId)),
            ] + appQuery
            guard let redirectURL = redirect.url,
                  let redirectResponse = try? await http.getWithoutRedirect(redirectURL, headers: headers) else {
                return nil
            }
            let status = redirectResponse.1
            guard let location = redirectResponse.2, let target = Self.simklTarget(fromLocation: location) else {
                return (300..<500).contains(status) ? Ids(tmdb: nil, imdb: nil) : nil
            }
            var details = URLComponents(string: SimklConfig.apiBaseURL + "/\(target.type)/\(target.id)")!
            details.queryItems = [URLQueryItem(name: "extended", value: "full")] + appQuery
            guard let detailsURL = details.url,
                  let detailResponse = try? await http.getWithoutRedirect(detailsURL, headers: headers),
                  (200..<300).contains(detailResponse.1) else {
                return nil
            }
            guard let decoded = try? JSONDecoder().decode(Details.self, from: detailResponse.0) else {
                return Ids(tmdb: nil, imdb: nil)
            }
            let imdb = decoded.ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Ids(tmdb: decoded.ids?.tmdb, imdb: (imdb?.hasPrefix("tt") ?? false) ? imdb : nil)
        }

        /// Picks "anime/123" (or tv/movies) out of a Simkl web or API URL.
        static func simklTarget(fromLocation location: String) -> (type: String, id: String)? {
            let path = location.split(separator: "?", maxSplits: 1).first.map(String.init) ?? location
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            for index in stride(from: parts.count - 2, through: 0, by: -1) {
                let type = parts[index]
                let id = parts[index + 1]
                if ["anime", "tv", "movies"].contains(type), !id.isEmpty, id.allSatisfy(\.isNumber) {
                    return (type, id)
                }
            }
            return nil
        }

        struct Details: Decodable {
            struct IdBlock: Decodable {
                let imdb: String?
                let tmdb: Int?

                enum CodingKeys: String, CodingKey { case imdb, tmdb }

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    imdb = try? c.decodeIfPresent(String.self, forKey: .imdb)
                    // Simkl sends the TMDB id as a string; accept a number too.
                    if let number = try? c.decodeIfPresent(Int.self, forKey: .tmdb) {
                        tmdb = number
                    } else if let text = try? c.decodeIfPresent(String.self, forKey: .tmdb) {
                        tmdb = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        tmdb = nil
                    }
                }
            }
            let ids: IdBlock?
        }
    }
}

// MARK: - HTTP

protocol CalendarAnimeHTTPClient: Sendable {
    func post(_ url: URL, json: Data) async throws -> (Data, Int)
    /// GET that reports a redirect instead of following it: status, body and
    /// the Location header.
    func getWithoutRedirect(_ url: URL, headers: [String: String]) async throws -> (Data, Int, String?)
}

struct CalendarAnimeURLSessionClient: CalendarAnimeHTTPClient {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    func post(_ url: URL, json: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func getWithoutRedirect(_ url: URL, headers: [String: String]) async throws -> (Data, Int, String?) {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await Self.session.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Location"))
    }
}
