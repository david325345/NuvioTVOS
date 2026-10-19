import CalendarCore
import Foundation
import SwiftUI

enum SettingsKey {
    static let tmdbApiKey = "kalendar.tmdbApiKey"
    static let language = "kalendar.language"
    static let region = "kalendar.region"
    static let horizonDays = "kalendar.horizonDays"
    static let library = "kalendar.library"
    static let idCache = "kalendar.idCache"
}

enum AppSettings {
    static var tmdbApiKey: String { UserDefaults.standard.string(forKey: SettingsKey.tmdbApiKey) ?? "" }
    static var language: String { UserDefaults.standard.string(forKey: SettingsKey.language) ?? "cs-CZ" }
    static var region: String { UserDefaults.standard.string(forKey: SettingsKey.region) ?? "CZ" }
    static var horizonDays: Int {
        let value = UserDefaults.standard.integer(forKey: SettingsKey.horizonDays)
        return value > 0 ? value : 90
    }

    static func makeClient() -> TmdbClient {
        TmdbClient(apiKey: tmdbApiKey, language: language)
    }
}

/// Keeps IMDb → TMDB mappings between launches.
struct UserDefaultsIdCache: IdCacheStore {
    func load() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: SettingsKey.idCache) as? [String: Int]) ?? [:]
    }

    func save(_ values: [String: Int]) {
        UserDefaults.standard.set(values, forKey: SettingsKey.idCache)
    }
}

/// Stand-in for Nuvio's library: the titles the calendar looks at.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [CalendarItem] = []

    /// Long-running series with stable IMDb ids, plus two ended shows to show
    /// how skipped titles are reported. Movies are added through search.
    static let defaults: [CalendarItem] = [
        CalendarItem(id: "tt0096697", kind: .series, name: "The Simpsons"),
        CalendarItem(id: "tt0182576", kind: .series, name: "Family Guy"),
        CalendarItem(id: "tt0121955", kind: .series, name: "South Park"),
        CalendarItem(id: "tt0397306", kind: .series, name: "American Dad!"),
        CalendarItem(id: "tt1561755", kind: .series, name: "Bob's Burgers"),
        CalendarItem(id: "tt0413573", kind: .series, name: "Grey's Anatomy"),
        CalendarItem(id: "tt0072562", kind: .series, name: "Saturday Night Live"),
        CalendarItem(id: "tt3530232", kind: .series, name: "Last Week Tonight"),
        CalendarItem(id: "tt0239195", kind: .series, name: "Survivor"),
        CalendarItem(id: "tt0903747", kind: .series, name: "Breaking Bad"),
        CalendarItem(id: "tmdb:1399", kind: .series, name: "Game of Thrones"),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: SettingsKey.library),
           let saved = try? JSONDecoder().decode([CalendarItem].self, from: data) {
            items = saved
        } else {
            items = Self.defaults
        }
    }

    func contains(_ id: String, kind: MediaKind) -> Bool {
        items.contains { $0.id == id && $0.kind == kind }
    }

    func add(_ item: CalendarItem) {
        guard !contains(item.id, kind: item.kind) else { return }
        items.append(item)
        save()
    }

    func remove(_ item: CalendarItem) {
        items.removeAll { $0.id == item.id && $0.kind == item.kind }
        save()
    }

    func resetToDefaults() {
        items = Self.defaults
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: SettingsKey.library)
        }
    }
}
