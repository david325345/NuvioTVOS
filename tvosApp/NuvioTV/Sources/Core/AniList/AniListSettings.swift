import Foundation

extension SettingsKey {
    static let aniListEnabled = "nuvio.tv.settings.integrations.aniListEnabled"
    static let aniListTitleLanguage = "nuvio.tv.settings.integrations.aniListTitleLanguage"
    static let aniListSeasonMode = "nuvio.tv.settings.integrations.aniListSeasonMode"
    static let aniListHomeRows = "nuvio.tv.settings.integrations.aniListHomeRows"
    static let aniListSearch = "nuvio.tv.settings.integrations.aniListSearch"
    static let aniListHideCinemetaDuplicates = "nuvio.tv.settings.integrations.aniListHideCinemetaDuplicates"
    static let aniListEpisodeDetails = "nuvio.tv.settings.integrations.aniListEpisodeDetails"
    static let aniListAdult = "nuvio.tv.settings.integrations.aniListAdult"
    static let aniListClientID = "nuvio.tv.settings.integrations.aniListClientID"
    static let aniListScrobble = "nuvio.tv.settings.integrations.aniListScrobble"
    static let aniListScrobbleCinemeta = "nuvio.tv.settings.integrations.aniListScrobbleCinemeta"
    static let aniListListRows = "nuvio.tv.settings.integrations.aniListListRows"
}

/// Settings → Integrations → AniList. Anime from AniList keep their `anilist:` ids everywhere,
/// so add-ons that declare the `anilist` prefix are asked with `anilist:ID` (a film) or
/// `anilist:ID:EP` (an episode, numbered as on AniList).
enum AniListSettings {
    enum TitleLanguage: String, CaseIterable {
        case romaji
        case english
        case native

        var label: String {
            switch self {
            case .romaji: return "Romaji"
            case .english: return "English"
            case .native: return "Native"
            }
        }
    }

    /// How the seasons of a series show: all of them as one title with a tab per AniList
    /// entry, or every AniList entry as a title of its own, as on AniList.
    enum SeasonMode: String, CaseIterable {
        case merged
        case separate

        var label: String {
            switch self {
            case .merged: return "One Title"
            case .separate: return "Each Entry"
            }
        }
    }

    static func isEnabled(in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.bool(forKey: SettingsKey.aniListEnabled)
    }

    static var isEnabled: Bool { isEnabled(in: ProfileSettings.current) }

    static var titleLanguage: TitleLanguage {
        TitleLanguage(rawValue: ProfileSettings.current.string(forKey: SettingsKey.aniListTitleLanguage) ?? "") ?? .romaji
    }

    static var seasonMode: SeasonMode {
        SeasonMode(rawValue: ProfileSettings.current.string(forKey: SettingsKey.aniListSeasonMode) ?? "") ?? .merged
    }

    static func showsHomeRows(in store: UserDefaults = ProfileSettings.current) -> Bool {
        isEnabled(in: store) && bool(SettingsKey.aniListHomeRows, default: true, in: store)
    }

    static var showsHomeRows: Bool { showsHomeRows(in: ProfileSettings.current) }

    static var searchesAniList: Bool {
        isEnabled && bool(SettingsKey.aniListSearch, default: true)
    }

    static var hidesCinemetaDuplicates: Bool {
        searchesAniList && bool(SettingsKey.aniListHideCinemetaDuplicates, default: false)
    }

    static var usesEpisodeDetails: Bool {
        bool(SettingsKey.aniListEpisodeDetails, default: true)
    }

    static var showsAdult: Bool {
        bool(SettingsKey.aniListAdult, default: false)
    }

    /// The Client ID of the viewer's AniList API client, which AniList asks for when they log in.
    static var clientID: String {
        (ProfileSettings.current.string(forKey: SettingsKey.aniListClientID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write how far the viewer watched an AniList title to their AniList list.
    static var scrobbles: Bool {
        AniListAccount.isLoggedIn && bool(SettingsKey.aniListScrobble, default: true)
    }

    /// Also for anime from Cinemeta, found on AniList by their TMDB/IMDb id and air dates.
    static var scrobblesCinemeta: Bool {
        scrobbles && bool(SettingsKey.aniListScrobbleCinemeta, default: true)
    }

    /// The viewer's lists (Watching, Planning, Paused) as Home rows.
    static var showsListRows: Bool {
        showsHomeRows && AniListAccount.isLoggedIn && bool(SettingsKey.aniListListRows, default: true)
    }

    /// What Home and Search read from these settings. It is part of their source signatures, so
    /// turning AniList on or changing what it shows reloads Home and drops cached search results.
    static var sourceSignature: String {
        guard isEnabled else { return "anilist:off" }
        return [
            "anilist:on",
            showsHomeRows ? "rows" : "norows",
            searchesAniList ? "search" : "nosearch",
            hidesCinemetaDuplicates ? "dedupe" : "all",
            titleLanguage.rawValue,
            showsAdult ? "adult" : "safe",
            showsListRows ? "lists:\(AniListAccount.login?.viewerID ?? 0)" : "nolists",
        ].joined(separator: ",")
    }

    /// Asks Home to load its rows again after a change that adds or removes AniList rows.
    static func notifyHomeChanged() {
        NotificationCenter.default.post(name: TVHomeCatalogOrder.changedNotification, object: nil)
        NotificationCenter.default.post(name: TVHomeCatalogOrder.snapshotChangedNotification, object: nil)
    }

    private static func bool(_ key: String, default value: Bool, in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.object(forKey: key) == nil ? value : store.bool(forKey: key)
    }
}
