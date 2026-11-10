import QuartzCore

/// The fork's test build: when Details opens, finishes loading and closes, in the test log.
///
/// A crash while Details was being left and opened again showed nothing of it in the log;
/// these lines say which title opened from where, how long it took to load, when Back was
/// pressed (still loading or not), how long the screen took to go, and whether another
/// Details was still there when one opened.
@MainActor
enum DetailsLifecycleLog {
    private struct Visit {
        let id: String
        let openedAt: CFTimeInterval
        var loadedAt: CFTimeInterval?
        var backAt: CFTimeInterval?
    }

    private static var visits: [UUID: Visit] = [:]

    /// A Details screen (`token`, one per screen) came on screen for `id`.
    static func opened(_ token: UUID, id: String, type: String, loaded: Bool, steady: Bool) {
        let now = CACurrentMediaTime()
        let from = HitchMeter.screen.hasPrefix("details(\(id),") ? HitchMeter.previousScreen : HitchMeter.screen
        let sameTitle = visits.values.filter { $0.id == id }.count
        let others = visits.count - sameTitle
        var line = "details: opened \(type) \(id) from \(from), opening \(steady ? "steady" : "nuvio")"
        if loaded { line += ", already loaded" }
        if sameTitle > 0 { line += ", while the previous Details of this title is still there" }
        if others > 0 { line += ", \(others) other Details still there" }
        TestDiagnosticLog.ui(line)
        visits[token] = Visit(id: id, openedAt: now, loadedAt: loaded ? now : nil)
    }

    static func loaded(_ token: UUID) {
        guard var visit = visits[token], visit.loadedAt == nil else { return }
        let now = CACurrentMediaTime()
        visit.loadedAt = now
        visits[token] = visit
        TestDiagnosticLog.ui("details: \(visit.id) loaded in \(milliseconds(now - visit.openedAt)) ms")
    }

    static func backPressed(_ token: UUID) {
        guard var visit = visits[token] else { return }
        let now = CACurrentMediaTime()
        visit.backAt = now
        visits[token] = visit
        TestDiagnosticLog.ui(
            "details: Back on \(visit.id) after \(milliseconds(now - visit.openedAt)) ms"
                + (visit.loadedAt == nil ? ", still loading" : "")
        )
    }

    static func closed(_ token: UUID) {
        guard let visit = visits.removeValue(forKey: token) else { return }
        let now = CACurrentMediaTime()
        var line = "details: closed \(visit.id) after \(milliseconds(now - visit.openedAt)) ms"
        if let backAt = visit.backAt { line += " (gone \(milliseconds(now - backAt)) ms after Back)" }
        if visit.loadedAt == nil { line += ", never finished loading" }
        TestDiagnosticLog.ui(line)
    }

    private static func milliseconds(_ seconds: CFTimeInterval) -> Int {
        Int((seconds * 1_000).rounded())
    }
}
