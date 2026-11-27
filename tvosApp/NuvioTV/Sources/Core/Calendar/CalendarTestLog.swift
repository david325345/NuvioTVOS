import Foundation

// Test build only (fork): where the calendar's time goes, in the Test Log
// (Settings → Usenet → Test Log), to find why its first load is slow.
enum CalendarTestLog {
    static func note(_ text: String) {
        UsenetLogBook.add("calendar: " + text, isError: false)
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

extension CalendarSnapshot {
    /// Why it isn't shown, nil when it is.
    func testLogUnusableReason(settings: String, now: Date) -> String? {
        if version != Self.currentVersion { return "saved by another version" }
        if settingsDigest != Self.digest(settings) { return "made with other settings or profile" }
        let age = now.timeIntervalSince(loadedAt)
        if age >= Self.maxAge { return "too old (\(Int(age / 3600)) h)" }
        if loadedAt.timeIntervalSince(now) >= 5 * 60 { return "made in the future (clock)" }
        return nil
    }
}
