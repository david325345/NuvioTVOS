import Foundation

public enum CalendarLoadError: Error, Equatable, Sendable {
    case missingApiKey
    case invalidApiKey
}

/// Loads the calendar for a list of library items.
///
/// Only reads: it never changes the library. A failure for one title is
/// recorded as skipped and does not stop the others; only a missing or
/// rejected API key fails the whole load.
public struct CalendarService: Sendable {
    public let client: TmdbClient
    public let resolver: IdResolver
    public var horizonDays: Int
    public var maxConcurrent: Int
    public var region: String

    public init(
        client: TmdbClient,
        resolver: IdResolver? = nil,
        horizonDays: Int = CalendarBuilder.defaultHorizonDays,
        maxConcurrent: Int = 4,
        region: String = "CZ"
    ) {
        self.client = client
        self.resolver = resolver ?? IdResolver(client: client)
        self.horizonDays = max(0, horizonDays)
        self.maxConcurrent = max(1, maxConcurrent)
        self.region = region
    }

    enum Outcome: Sendable {
        case entries([CalendarEntry])
        case skipped(SkipReason)
        case authFailure
    }

    public func load(items: [LibraryItem], today: DayKey = DayKey(date: Date())) async throws -> CalendarResult {
        guard !client.apiKey.isEmpty else { throw CalendarLoadError.missingApiKey }
        let lastDay = today.adding(days: horizonDays)

        // 1. Resolve ids, then drop duplicates (the same show saved twice
        //    under different ids).
        let resolutions = await concurrentMap(items) { item -> (LibraryItem, Result<IdResolver.Resolution, Error>) in
            do { return (item, .success(try await resolver.resolve(item))) }
            catch { return (item, .failure(error)) }
        }

        var skipped: [SkippedItem] = []
        var targets: [(LibraryItem, Int)] = []
        var seenTargets = Set<String>()
        for (item, result) in resolutions {
            switch result {
            case .success(.resolved(let tmdbId)):
                if seenTargets.insert("\(item.kind.rawValue):\(tmdbId)").inserted {
                    targets.append((item, tmdbId))
                }
            case .success(.unsupported):
                skipped.append(SkippedItem(item: item, reason: .unsupportedId))
            case .success(.notFound):
                skipped.append(SkippedItem(item: item, reason: .notFoundOnTmdb))
            case .failure(let error):
                if Self.isAuthError(error) { throw CalendarLoadError.invalidApiKey }
                if case TmdbError.notFound = error {
                    skipped.append(SkippedItem(item: item, reason: .notFoundOnTmdb))
                } else {
                    skipped.append(SkippedItem(item: item, reason: .failed(Self.describe(error))))
                }
            }
        }

        // 2. Fetch upcoming episodes / releases.
        let outcomes = await concurrentMap(targets) { target -> (LibraryItem, Outcome) in
            let (item, tmdbId) = target
            return (item, await fetch(item: item, tmdbId: tmdbId, today: today, lastDay: lastDay))
        }

        var entries: [CalendarEntry] = []
        for (item, outcome) in outcomes {
            switch outcome {
            case .entries(let found):
                if found.isEmpty {
                    skipped.append(SkippedItem(item: item, reason: .nothingUpcoming))
                } else {
                    entries.append(contentsOf: found)
                }
            case .skipped(let reason):
                skipped.append(SkippedItem(item: item, reason: reason))
            case .authFailure:
                throw CalendarLoadError.invalidApiKey
            }
        }

        return CalendarResult(
            today: today,
            lastDay: lastDay,
            days: CalendarBuilder.groupByDay(entries),
            skipped: skipped
        )
    }

    func fetch(item: LibraryItem, tmdbId: Int, today: DayKey, lastDay: DayKey) async -> Outcome {
        do {
            switch item.kind {
            case .series:
                let details = try await client.tvDetails(tmdbId)
                let seasons = CalendarBuilder.seasonsToFetch(for: details, today: today, lastDay: lastDay)
                var episodes: [TmdbEpisode] = []
                for number in seasons {
                    do {
                        episodes += try await client.season(tmdbId, number: number).episodes ?? []
                    } catch {
                        if Self.isAuthError(error) { return .authFailure }
                        // A missing season page should not hide the rest;
                        // fall back to the single announced episode.
                        if let next = details.nextEpisodeToAir, next.seasonNumber == number {
                            episodes.append(next)
                        }
                    }
                }
                return .entries(CalendarBuilder.episodeEntries(
                    item: item, details: details, episodes: episodes, today: today, lastDay: lastDay
                ))
            case .movie:
                let details = try await client.movieDetails(tmdbId)
                return .entries(CalendarBuilder.movieEntries(
                    item: item, details: details, region: region, today: today, lastDay: lastDay
                ))
            }
        } catch {
            if Self.isAuthError(error) { return .authFailure }
            if case TmdbError.notFound = error { return .skipped(.notFoundOnTmdb) }
            return .skipped(.failed(Self.describe(error)))
        }
    }

    /// Runs `transform` over `input` with at most `maxConcurrent` calls in
    /// flight, keeping the input order.
    func concurrentMap<T: Sendable, R: Sendable>(_ input: [T], _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
        guard !input.isEmpty else { return [] }
        var results = [R?](repeating: nil, count: input.count)
        await withTaskGroup(of: (Int, R).self) { group in
            var next = 0
            let initial = min(maxConcurrent, input.count)
            while next < initial {
                let index = next
                group.addTask { (index, await transform(input[index])) }
                next += 1
            }
            while let finished = await group.next() {
                results[finished.0] = finished.1
                if next < input.count {
                    let index = next
                    group.addTask { (index, await transform(input[index])) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    static func isAuthError(_ error: Error) -> Bool {
        guard let tmdb = error as? TmdbError else { return false }
        return tmdb == .unauthorized || tmdb == .missingApiKey
    }

    static func describe(_ error: Error) -> String {
        if let tmdb = error as? TmdbError {
            switch tmdb {
            case .http(let code): return "HTTP \(code)"
            case .decoding: return "neplatná odpověď TMDB"
            case .notFound: return "nenalezeno"
            case .unauthorized, .missingApiKey: return "neplatný klíč"
            }
        }
        return error.localizedDescription
    }
}
