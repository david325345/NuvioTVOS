import Foundation

/// "Test" for a provider (Settings on the TV and the web page): one search
/// for a sample title — streams and/or subtitles, whatever the provider
/// offers — with what came back, how long it took and the provider's log
/// lines from that run. Android has the same button for streams.
enum PluginTester {
    struct Sample: Equatable {
        var type: String
        var imdbID: String
        var season: Int?
        var episode: Int?

        /// The Matrix — Android's own test title.
        static let movie = Sample(type: "movie", imdbID: "tt0133093", season: nil, episode: nil)
        /// Breaking Bad S01E01.
        static let episode = Sample(type: "series", imdbID: "tt0903747", season: 1, episode: 1)

        var videoID: String {
            guard type != "movie", let season, let episode else { return imdbID }
            return "\(imdbID):\(season):\(episode)"
        }

        var label: String {
            guard type != "movie", let season, let episode else { return imdbID }
            return "\(imdbID) S\(season)E\(episode)"
        }
    }

    struct Report {
        let sample: Sample
        let streams: [NuvioStream]
        /// Why the stream search failed, if it did.
        let error: String?
        let subtitles: [NuvioSubtitle]
        let subtitleError: String?
        let checkedStreams: Bool
        let checkedSubtitles: Bool
        let duration: TimeInterval
        let log: [PluginLogEntry]

        var failed: Bool { (checkedStreams && error != nil) || (checkedSubtitles && subtitleError != nil) }

        var summary: String {
            var parts: [String] = []
            if checkedStreams {
                parts.append(error.map { "✕ \($0)" } ?? "\(streams.count) stream\(streams.count == 1 ? "" : "s")")
            }
            if checkedSubtitles {
                parts.append(subtitleError.map { "✕ subtitles: \($0)" }
                    ?? "\(subtitles.count) subtitle\(subtitles.count == 1 ? "" : "s")")
            }
            parts.append(String(format: "%.1f s", duration))
            return parts.joined(separator: " · ")
        }
    }

    /// Asks the provider for everything it offers (streams, subtitles) for
    /// the sample, bypassing caches.
    static func run(_ scraper: PluginScraperRecord, sample: Sample) async -> Report {
        let before = PluginLogStore.shared.entries(for: scraper.id).last?.id
        let started = Date()
        let checkStreams = scraper.provides(PluginResources.stream)
        let checkSubtitles = scraper.provides(PluginResources.subtitles)

        async let streamGroup = streams(scraper, sample: sample, when: checkStreams)
        async let subtitleOutcome = subtitles(scraper, sample: sample, when: checkSubtitles)
        let group = await streamGroup
        let outcome = await subtitleOutcome

        let entries = PluginLogStore.shared.entries(for: scraper.id)
        let newLines: [PluginLogEntry]
        if let before, let index = entries.firstIndex(where: { $0.id == before }) {
            newLines = Array(entries[(index + 1)...])
        } else {
            newLines = entries
        }
        return Report(
            sample: sample,
            streams: group?.streams ?? [],
            error: group?.error,
            subtitles: outcome?.subtitles ?? [],
            subtitleError: outcome?.error,
            checkedStreams: checkStreams,
            checkedSubtitles: checkSubtitles,
            duration: Date().timeIntervalSince(started),
            log: newLines
        )
    }

    private static func streams(_ scraper: PluginScraperRecord, sample: Sample, when enabled: Bool) async -> AddonStreamGroup? {
        guard enabled else { return nil }
        let target = PluginStreamDiscovery.Target(groupID: "plugin:\(scraper.id)", displayName: scraper.name, scraper: scraper)
        return await PluginStreamDiscovery.fetchGroup(target: target, type: sample.type, videoID: sample.videoID)
    }

    private static func subtitles(_ scraper: PluginScraperRecord, sample: Sample, when enabled: Bool) async -> PluginSubtitleDiscovery.Outcome? {
        guard enabled else { return nil }
        return await PluginSubtitleDiscovery.run(scraper, query: PluginSubtitleDiscovery.Query(type: sample.type, videoID: sample.videoID))
    }
}
