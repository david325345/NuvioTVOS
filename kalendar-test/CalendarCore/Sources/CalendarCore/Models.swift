import Foundation

public enum MediaKind: String, Codable, Hashable, Sendable {
    case series
    case movie
}

/// One title from the user's library, identified the way Nuvio identifies it
/// ("tt0903747", "tmdb:1396", ...).
public struct CalendarItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: MediaKind
    public var name: String?
    public var posterPath: String?

    public init(id: String, kind: MediaKind, name: String? = nil, posterPath: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.posterPath = posterPath
    }
}

public enum ReleaseKind: String, Codable, Hashable, Sendable {
    case episode
    case seasonPremiere
    case seriesPremiere
    case seasonFinale
    case theatrical
    case digital
    case physical
    case release
}

public struct CalendarEntry: Hashable, Identifiable, Sendable {
    public let id: String
    public let itemId: String
    public let kind: MediaKind
    public let tmdbId: Int
    public let title: String
    public let date: DayKey
    public let releaseKind: ReleaseKind
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let episodeName: String?
    public let overview: String?
    public let posterURL: URL?
    public let stillURL: URL?

    public init(
        itemId: String,
        kind: MediaKind,
        tmdbId: Int,
        title: String,
        date: DayKey,
        releaseKind: ReleaseKind,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        episodeName: String? = nil,
        overview: String? = nil,
        posterURL: URL? = nil,
        stillURL: URL? = nil
    ) {
        switch kind {
        case .series:
            self.id = "tv:\(tmdbId):\(seasonNumber ?? -1):\(episodeNumber ?? -1)"
        case .movie:
            self.id = "movie:\(tmdbId):\(releaseKind.rawValue):\(date.iso)"
        }
        self.itemId = itemId
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.date = date
        self.releaseKind = releaseKind
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeName = episodeName
        self.overview = overview
        self.posterURL = posterURL
        self.stillURL = stillURL
    }
}

public struct CalendarDaySection: Hashable, Identifiable, Sendable {
    public var id: String { date.iso }
    public let date: DayKey
    public let entries: [CalendarEntry]

    public init(date: DayKey, entries: [CalendarEntry]) {
        self.date = date
        self.entries = entries
    }
}

public enum SkipReason: Hashable, Sendable {
    /// The id has a format the calendar cannot turn into a TMDB id.
    case unsupportedId
    /// TMDB did not know the title.
    case notFoundOnTmdb
    /// Nothing announced inside the window.
    case nothingUpcoming
    case failed(String)
}

public struct SkippedItem: Hashable, Identifiable, Sendable {
    public var id: String { item.id }
    public let item: CalendarItem
    public let reason: SkipReason

    public init(item: CalendarItem, reason: SkipReason) {
        self.item = item
        self.reason = reason
    }
}

public struct CalendarResult: Sendable {
    public let today: DayKey
    public let lastDay: DayKey
    public let days: [CalendarDaySection]
    public let skipped: [SkippedItem]

    public init(today: DayKey, lastDay: DayKey, days: [CalendarDaySection], skipped: [SkippedItem]) {
        self.today = today
        self.lastDay = lastDay
        self.days = days
        self.skipped = skipped
    }

    public var entryCount: Int { days.reduce(0) { $0 + $1.entries.count } }
}
