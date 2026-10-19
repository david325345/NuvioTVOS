import Foundation

/// A calendar day without a time or time zone ("2026-10-19").
///
/// TMDB publishes air dates as plain dates, so the calendar keeps them as
/// dates too instead of turning them into instants in some time zone.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "yyyy-MM-dd", also accepting a longer ISO-8601 string
    /// ("2026-10-30T00:00:00.000Z") by reading only its date part.
    public init?(iso: String?) {
        guard let raw = iso?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        guard DayKey.isValid(year: y, month: m, day: d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The day `date` falls on in `timeZone` (the device's zone by default).
    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso }

    public func adding(days: Int) -> DayKey {
        let calendar = DayKey.utcCalendar
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let moved = calendar.date(byAdding: .day, value: days, to: start) else { return self }
        return DayKey(date: moved, timeZone: calendar.timeZone)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: DayKey) -> Int {
        let calendar = DayKey.utcCalendar
        guard let a = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let b = calendar.date(from: DateComponents(year: other.year, month: other.month, day: other.day)) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// Noon UTC of this day; safe to format in any time zone without
    /// slipping to a neighbouring day.
    public var noonDate: Date {
        var calendar = DayKey.utcCalendar
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        let calendar = utcCalendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return c.year == year && c.month == month && c.day == day
    }
}
