import Foundation

/// "Test" for a provider (Settings on the TV and the web page): one stream
/// search for a sample title, with what came back, how long it took and the
/// provider's log lines from that run. Android has the same button.
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
        let error: String?
        let duration: TimeInterval
        let log: [PluginLogEntry]

        var summary: String {
            let time = String(format: "%.1f s", duration)
            if let error { return "✕ \(error) (\(time))" }
            return "\(streams.count) stream\(streams.count == 1 ? "" : "s") in \(time)"
        }
    }

    static func run(_ scraper: PluginScraperRecord, sample: Sample) async -> Report {
        let before = PluginLogStore.shared.entries(for: scraper.id).last?.id
        let started = Date()
        let target = PluginStreamDiscovery.Target(groupID: "plugin:\(scraper.id)", displayName: scraper.name, scraper: scraper)
        let group = await PluginStreamDiscovery.fetchGroup(target: target, type: sample.type, videoID: sample.videoID)
        let entries = PluginLogStore.shared.entries(for: scraper.id)
        let newLines: [PluginLogEntry]
        if let before, let index = entries.firstIndex(where: { $0.id == before }) {
            newLines = Array(entries[(index + 1)...])
        } else {
            newLines = entries
        }
        return Report(
            sample: sample,
            streams: group.streams,
            error: group.error,
            duration: Date().timeIntervalSince(started),
            log: newLines
        )
    }
}
