import Foundation

/// The ids an AniList title is asked by from add-ons that don't know `anilist:` ids (Settings →
/// AniList → "Ask Other Add-ons"):
///
/// 1. `kitsu:ID:episode`: Kitsu keeps a separate entry per season, as AniList does, so the
///    episode number stays as on AniList.
/// 2. `tt…:season:episode`: IMDb with TheTVDB's numbering, the one Stremio add-ons go by.
///
/// The offline tables (Fribb, anibridge) answer first. Only what they don't know is asked
/// online: ani.zip for ids and TheTVDB numbers, then (for a season too new for any of them) the
/// episode's air day matched against Cinemeta's episode list, through the earlier seasons' IMDb
/// id. An episode nothing places is not asked by IMDb: no streams beat another episode's.
enum AniListStreamIds {
    private static let lock = NSLock()
    private static var known: [String: [String]] = [:]

    /// The ids to try, best first, for an add-on that doesn't take `videoId`. [] for ids that
    /// aren't AniList's, or with the setting off.
    static func alternatives(for videoId: String) async -> [String] {
        guard AniListSettings.isEnabled, AniListSettings.asksOtherAddons,
              let entryID = AniListMetaBuilder.aniListID(from: videoId) else { return [] }
        if let cached = lock.withLock({ known[videoId] }) { return cached }
        let ids = await find(entryID: entryID, episode: AniListAccount.episodeNumber(in: videoId))
        if !ids.isEmpty { lock.withLock { known[videoId] = ids } }
        return ids
    }

    private static func find(entryID: Int, episode: Int?) async -> [String] {
        let offline = await AniListOfflineMaps.shared.entry(aniListID: entryID)
        var kitsu = offline?.kitsu
        var imdb = offline?.imdb
        var numbering: (season: Int, episode: Int)? = nil
        if let episode, let found = await AniListOfflineMaps.shared.seasonEpisode(aniListID: entryID, episode: episode) {
            numbering = (found.season, found.episode)
        }

        // Online, only for what the tables don't know.
        var airDay: String? = nil
        if kitsu == nil || imdb == nil || (episode != nil && numbering == nil) {
            let zip = await AniListService.aniZipMappings(entryID: entryID, finished: false)
            kitsu = kitsu ?? zip?.mappings?.kitsuID
            imdb = imdb ?? zip?.mappings?.imdbID
            if let episode, let zipEpisode = zip?.episodes?[String(episode)] {
                if numbering == nil, let season = zipEpisode.seasonNumber, let number = zipEpisode.episodeNumber {
                    numbering = (season, number)
                }
                airDay = zipEpisode.airDay
            }
        }

        var ids: [String] = []
        if let kitsu {
            ids.append(episode.map { "kitsu:\(kitsu):\($0)" } ?? "kitsu:\(kitsu)")
        }
        guard let episode else {
            // A film: its IMDb id alone.
            if let imdb { ids.append(imdb) }
            return ids
        }

        if numbering == nil {
            // A season too new for the tables and ani.zip: its IMDb id (or the earlier seasons'),
            // and the episode Cinemeta lists for the day it aired.
            if imdb == nil { imdb = await earlierSeasonsIMDb(of: entryID) }
            if let imdb {
                var day = airDay
                if day == nil { day = await aniListAirDay(entryID: entryID, episode: episode) }
                if let day, let found = await cinemetaEpisode(imdb: imdb, airDay: day) {
                    numbering = found
                }
            }
        }
        if let imdb, let numbering {
            ids.append("\(imdb):\(numbering.season):\(numbering.episode)")
        }
        return ids
    }

    /// The IMDb id of the nearest earlier season the tables or ani.zip know: one show on IMDb.
    private static func earlierSeasonsIMDb(of entryID: Int) async -> String? {
        var current = entryID
        for _ in 0..<3 {
            guard let media = await AniListService.prequels(of: current),
                  let previous = AniListMetaBuilder.previousSeason(of: media) else { return nil }
            if let imdb = await AniListOfflineMaps.shared.entry(aniListID: previous)?.imdb { return imdb }
            if let imdb = await AniListService.aniZipMappings(entryID: previous, finished: true)?.mappings?.imdbID { return imdb }
            current = previous
        }
        return nil
    }

    /// The day AniList's broadcast schedule gives an episode.
    private static func aniListAirDay(entryID: Int, episode: Int) async -> String? {
        guard let media = await AniListMatcher.franchise(ids: [entryID]).first(where: { $0.id == entryID }),
              let node = media.airingSchedule?.nodes?.first(where: { $0.episode == episode }) else { return nil }
        return AniListMatcher.utcDay(of: node.airingAt)
    }

    /// Cinemeta's season and episode that aired on `airDay` (a day either way, for time zones),
    /// when exactly one did.
    static func cinemetaEpisode(imdb: String, airDay: String) async -> (season: Int, episode: Int)? {
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/series/\(imdb).json"),
              let data = try? await AniListClient.shared.get(url, ttl: 6 * 3600),
              let response = try? JSONDecoder().decode(CinemetaSeries.self, from: data) else { return nil }
        return episode(in: response.meta?.videos ?? [], airDay: airDay)
    }

    static func episode(in videos: [CinemetaSeries.Video], airDay: String) -> (season: Int, episode: Int)? {
        for distance in 0...1 {
            let matches = videos.filter { video in
                guard let season = video.season, season > 0, video.episode != nil,
                      let day = AniListMatcher.day(of: video.released),
                      let gap = AniListMatcher.daysBetween(airDay, day) else { return false }
                return abs(gap) == distance
            }
            if matches.count == 1, let season = matches[0].season, let number = matches[0].episode {
                return (season, number)
            }
            if matches.count > 1 { return nil }
        }
        return nil
    }

    struct CinemetaSeries: Decodable {
        struct Meta: Decodable {
            let videos: [Video]?
        }
        struct Video: Decodable {
            let season: Int?
            let episode: Int?
            let released: String?

            init(season: Int?, episode: Int?, released: String?) {
                self.season = season
                self.episode = episode
                self.released = released
            }

            enum CodingKeys: String, CodingKey { case season, episode, number, released }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                season = try? container.decode(Int.self, forKey: .season)
                episode = (try? container.decode(Int.self, forKey: .episode)) ?? (try? container.decode(Int.self, forKey: .number))
                released = try? container.decode(String.self, forKey: .released)
            }
        }
        let meta: Meta?
    }

    /// Which id add-on `manifest` is asked by for `resource`: `videoId` when it takes it, else the
    /// first alternative it does. nil = it takes none.
    static func requestID(
        for manifest: StreamAddonManifest,
        resource: String,
        type: String,
        videoId: String,
        alternatives: [String]
    ) -> String? {
        if manifest.supportsResource(resource, type: type, id: videoId) { return videoId }
        return alternatives.first { manifest.supportsResource(resource, type: type, id: $0) }
    }

    /// For tests.
    static func forget() {
        lock.withLock { known.removeAll() }
    }
}
