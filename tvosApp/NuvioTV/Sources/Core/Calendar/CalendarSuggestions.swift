import Foundation

/// Ready-made TMDB lists for adding many titles to the library at once
/// ("anime this season", "series airing now", "upcoming movies").
enum CalendarSuggestionList: String, CaseIterable, Identifiable, Sendable {
    case animeToday
    case animeThisSeason
    case seriesToday
    case airingNow
    case upcomingMovies

    var id: String { rawValue }

    var kind: CalendarMediaKind {
        self == .upcomingMovies ? .movie : .series
    }

    var title: String {
        switch self {
        case .animeToday: return L10n.string("calendar_suggest_anime_today", fallback: "Anime today")
        case .animeThisSeason: return L10n.string("calendar_suggest_anime", fallback: "Anime this season")
        case .seriesToday: return L10n.string("calendar_suggest_series_today", fallback: "Series today")
        case .airingNow: return L10n.string("calendar_suggest_airing", fallback: "Series airing now")
        case .upcomingMovies: return L10n.string("calendar_suggest_movies", fallback: "Upcoming movies")
        }
    }
}

struct CalendarSuggestionRequest: Equatable, Sendable {
    let path: String
    let query: [String: String]
}

enum CalendarSuggestions {
    /// TMDB pages per list (20 titles each).
    static let pages = 5

    /// The anime broadcast season `day` falls in: winter Jan–Mar, spring
    /// Apr–Jun, summer Jul–Sep, fall Oct–Dec.
    static func animeSeason(containing day: CalendarDay) -> (first: CalendarDay, last: CalendarDay) {
        let startMonth = ((day.month - 1) / 3) * 3 + 1
        let first = CalendarDay(year: day.year, month: startMonth, day: 1)
        let last = first.addingMonths(2).lastOfMonth
        return (first, last)
    }

    /// Genres left out of "airing now": animation (has its own list), news,
    /// reality and talk shows, which would otherwise crowd the top.
    static let airingNowExcludedGenres = "16,10763,10764,10767"

    static func request(for list: CalendarSuggestionList, today: CalendarDay, region: String) -> CalendarSuggestionRequest {
        switch list {
        case .animeToday:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "with_genres": "16",
                "with_origin_country": "JP",
                "air_date.gte": today.iso,
                "air_date.lte": today.iso,
                "sort_by": "popularity.desc",
            ])
        case .seriesToday:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "without_genres": airingNowExcludedGenres,
                "air_date.gte": today.iso,
                "air_date.lte": today.iso,
                "sort_by": "popularity.desc",
            ])
        case .animeThisSeason:
            let season = animeSeason(containing: today)
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "with_genres": "16",
                "with_origin_country": "JP",
                "air_date.gte": season.first.iso,
                "air_date.lte": season.last.iso,
                "sort_by": "popularity.desc",
            ])
        case .airingNow:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "without_genres": airingNowExcludedGenres,
                "air_date.gte": today.iso,
                "air_date.lte": today.adding(days: 14).iso,
                "sort_by": "popularity.desc",
            ])
        case .upcomingMovies:
            return CalendarSuggestionRequest(path: "movie/upcoming", query: ["region": region])
        }
    }

    static func key(kind: CalendarMediaKind, tmdbId: Int) -> String {
        "\(kind.rawValue):\(tmdbId)"
    }
}

/// One title in the "Add shows" picker, from a TMDB list or from the
/// AniList + Simkl "Anime today" list.
struct CalendarSuggestionItem: Identifiable, Hashable, Sendable {
    /// Matches `CalendarResult.libraryKeys` ("series:123") when the TMDB id is known.
    let key: String
    let kind: CalendarMediaKind
    let tmdbId: Int?
    let imdbId: String?
    let title: String
    let posterURL: URL?
    let year: Int?
    /// Shown under the title instead of the year (e.g. the broadcast time).
    let detail: String?

    var id: String { key }
    var isAddable: Bool { tmdbId != nil || imdbId != nil }

    init(key: String, kind: CalendarMediaKind, tmdbId: Int?, imdbId: String?, title: String,
         posterURL: URL?, year: Int?, detail: String? = nil) {
        self.key = key
        self.kind = kind
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.title = title
        self.posterURL = posterURL
        self.year = year
        self.detail = detail
    }

    init(tmdb result: CalendarTmdb.ListResult, kind: CalendarMediaKind) {
        self.init(
            key: CalendarSuggestions.key(kind: kind, tmdbId: result.id),
            kind: kind,
            tmdbId: result.id,
            imdbId: nil,
            title: result.displayTitle,
            posterURL: CalendarTmdb.imageURL(result.posterPath, size: "w342"),
            year: result.year
        )
    }
}

/// Adds titles picked from a suggestion list to the active library, the same
/// way "Add to Library" in Details does: the remote watchlist when a Trakt,
/// Simkl, MDBList or WeTrakr library is selected, otherwise the local one.
enum CalendarLibraryWriter {
    @MainActor
    static func add(_ items: [CalendarSuggestionItem], client: CalendarTmdb.Client) async -> Int {
        var added = 0
        let useRemote = TraktSettingsStore.librarySourceMode != .local
            && SelectedLibraryService.isSelectedAndAuthenticated
        for item in items where item.isAddable {
            // Addons look titles up by IMDb id, so prefer it over tmdb:.
            var imdb = item.imdbId
            if imdb == nil, let tmdb = item.tmdbId {
                imdb = try? await client.imdbId(tmdbId: tmdb, kind: item.kind)
            }
            guard let id = imdb ?? item.tmdbId.map({ "tmdb:\($0)" }) else { continue }
            let meta = NuvioMeta(
                id: id,
                name: item.title,
                posterUrl: item.posterURL?.absoluteString,
                imdbId: imdb,
                tmdbId: item.tmdbId,
                type: item.kind == .series ? "series" : "movie",
                year: item.year
            )
            if useRemote {
                if await SelectedLibraryService.setWatchlist(meta, isInWatchlist: true) {
                    added += 1
                }
            } else {
                LibraryStore.add(meta)
                added += 1
            }
        }
        return added
    }
}
