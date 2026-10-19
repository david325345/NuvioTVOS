import CalendarCore
import Foundation

enum Formatting {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEEE d. MMMM"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d. M. yyyy"
        return f
    }()

    static func dayHeader(_ day: DayKey, today: DayKey) -> String {
        let offset = today.days(until: day)
        let name = dayFormatter.string(from: day.noonDate)
        switch offset {
        case 0: return "Dnes · \(name)"
        case 1: return "Zítra · \(name)"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    static func shortDate(_ day: DayKey) -> String {
        shortFormatter.string(from: day.noonDate)
    }

    static func episodeCode(_ entry: CalendarEntry) -> String? {
        guard let s = entry.seasonNumber, let e = entry.episodeNumber else { return nil }
        return String(format: "S%02dE%02d", s, e)
    }

    static func releaseLabel(_ kind: ReleaseKind) -> String? {
        switch kind {
        case .episode: return nil
        case .seasonPremiere: return "Nová série"
        case .seriesPremiere: return "Premiéra seriálu"
        case .seasonFinale: return "Finále série"
        case .theatrical: return "V kinech"
        case .digital: return "Digitálně"
        case .physical: return "Blu-ray / DVD"
        case .release: return "Vydání"
        }
    }

    static func subtitle(_ entry: CalendarEntry) -> String {
        switch entry.kind {
        case .series:
            return [episodeCode(entry), entry.episodeName].compactMap { $0 }.joined(separator: " · ")
        case .movie:
            return "Film"
        }
    }

    static func skipReason(_ reason: SkipReason) -> String {
        switch reason {
        case .unsupportedId: return "nepodporované ID (zatím jen IMDb a TMDB)"
        case .notFoundOnTmdb: return "na TMDB nenalezeno"
        case .nothingUpcoming: return "nic ohlášeného v nejbližších dnech"
        case .failed(let message): return "chyba: \(message)"
        }
    }
}
