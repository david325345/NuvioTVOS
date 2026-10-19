import Foundation

/// Pure functions that turn TMDB responses into calendar entries. No I/O,
/// so everything here is covered by unit tests.
public enum CalendarBuilder {
    public static let defaultHorizonDays = 90
    public static let maxSeasonsPerShow = 3

    // MARK: Series

    /// Seasons worth fetching for a show: the season of the next announced
    /// episode, plus any later season whose premiere date falls in the window.
    public static func seasonsToFetch(for details: TmdbTvDetails, today: DayKey, lastDay: DayKey) -> [Int] {
        var seasons = Set<Int>()
        if let next = details.nextEpisodeToAir,
           let number = next.seasonNumber,
           let date = DayKey(iso: next.airDate),
           date <= lastDay {
            seasons.insert(number)
        }
        for season in details.seasons ?? [] {
            guard let number = season.seasonNumber, number > 0,
                  let premiere = DayKey(iso: season.airDate),
                  premiere >= today, premiere <= lastDay else { continue }
            seasons.insert(number)
        }
        return Array(seasons.sorted().prefix(maxSeasonsPerShow))
    }

    public static func episodeEntries(
        item: LibraryItem,
        details: TmdbTvDetails,
        episodes: [TmdbEpisode],
        today: DayKey,
        lastDay: DayKey
    ) -> [CalendarEntry] {
        let title = details.name ?? item.name ?? item.id
        let poster = TmdbClient.imageURL(details.posterPath ?? item.posterPath, size: "w342")
        var seen = Set<String>()
        var result: [CalendarEntry] = []
        for episode in episodes {
            guard let number = episode.episodeNumber,
                  let season = episode.seasonNumber,
                  let date = DayKey(iso: episode.airDate),
                  date >= today, date <= lastDay else { continue }
            let entry = CalendarEntry(
                itemId: item.id,
                kind: .series,
                tmdbId: details.id,
                title: title,
                date: date,
                releaseKind: releaseKind(for: episode, season: season, number: number),
                seasonNumber: season,
                episodeNumber: number,
                episodeName: nonEmpty(episode.name),
                overview: nonEmpty(episode.overview),
                posterURL: poster,
                stillURL: TmdbClient.imageURL(episode.stillPath, size: "w780")
            )
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result
    }

    static func releaseKind(for episode: TmdbEpisode, season: Int, number: Int) -> ReleaseKind {
        if season == 0 { return .episode }
        if number == 1 { return season == 1 ? .seriesPremiere : .seasonPremiere }
        if episode.episodeType?.lowercased() == "finale" { return .seasonFinale }
        return .episode
    }

    // MARK: Movies

    /// Release-date types the calendar shows, with the label they map to.
    static let movieReleaseTypes: [Int: ReleaseKind] = [3: .theatrical, 4: .digital, 5: .physical]

    /// Upcoming releases of a movie in `region`. When TMDB has no theatrical,
    /// digital or physical date for that region, `fallbackRegion` is used,
    /// and as a last resort the movie's primary release date.
    public static func movieEntries(
        item: LibraryItem,
        details: TmdbMovieDetails,
        region: String,
        fallbackRegion: String = "US",
        today: DayKey,
        lastDay: DayKey
    ) -> [CalendarEntry] {
        let countries = details.releaseDates?.results ?? []

        func releases(in country: String) -> [(DayKey, ReleaseKind)] {
            let dates = countries.first { $0.country?.uppercased() == country.uppercased() }?.releaseDates ?? []
            return dates.compactMap { release in
                guard let type = release.type, let kind = movieReleaseTypes[type],
                      let day = DayKey(iso: release.releaseDate) else { return nil }
                return (day, kind)
            }
        }

        var candidates = releases(in: region)
        if candidates.isEmpty, fallbackRegion.uppercased() != region.uppercased() {
            candidates = releases(in: fallbackRegion)
        }
        if candidates.isEmpty, let primary = DayKey(iso: details.releaseDate) {
            candidates = [(primary, .release)]
        }

        let title = details.title ?? item.name ?? item.id
        let poster = TmdbClient.imageURL(details.posterPath ?? item.posterPath, size: "w342")
        var seen = Set<String>()
        var result: [CalendarEntry] = []
        for (day, kind) in candidates.sorted(by: { $0.0 < $1.0 }) where day >= today && day <= lastDay {
            let entry = CalendarEntry(
                itemId: item.id,
                kind: .movie,
                tmdbId: details.id,
                title: title,
                date: day,
                releaseKind: kind,
                overview: nonEmpty(details.overview),
                posterURL: poster
            )
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result
    }

    // MARK: Grouping

    public static func groupByDay(_ entries: [CalendarEntry]) -> [CalendarDaySection] {
        Dictionary(grouping: entries, by: \.date)
            .map { date, items in
                CalendarDaySection(date: date, entries: items.sorted(by: entryOrder))
            }
            .sorted { $0.date < $1.date }
    }

    static func entryOrder(_ a: CalendarEntry, _ b: CalendarEntry) -> Bool {
        let titleOrder = a.title.localizedCaseInsensitiveCompare(b.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        if (a.seasonNumber ?? 0) != (b.seasonNumber ?? 0) { return (a.seasonNumber ?? 0) < (b.seasonNumber ?? 0) }
        if (a.episodeNumber ?? 0) != (b.episodeNumber ?? 0) { return (a.episodeNumber ?? 0) < (b.episodeNumber ?? 0) }
        return a.id < b.id
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
