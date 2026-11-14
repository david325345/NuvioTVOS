import Foundation
import QuartzCore

/// The fork's test build: what Details does after focus moves to another of its sections (the
/// first move down from Play stutters). One test log line about 1.5 s after the move:
///
///     ui: details: focus actions → episodes — +0 scrolled down, +3 build below asked,
///         +41 sections 2 → 3 · bodies: content ×3, episodes ×2, backdrop ×2, episodeCard ×14
///
/// Times are milliseconds after the move, bodies the views of Details worked out again in
/// that time. Main thread only.
enum TVDetailsMoveTrace {
    private static let window: CFTimeInterval = 1.5
    private static var start: CFTimeInterval = 0
    private static var label = ""
    private static var events: [String] = []
    private static var bodies: [String: Int] = [:]
    private static var generation = 0

    private static var isOpen: Bool {
        start > 0 && CACurrentMediaTime() - start < window
    }

    /// Focus moved to another section: a new line starts.
    static func begin(_ what: String) {
        flush()
        start = CACurrentMediaTime()
        label = what
        events = []
        bodies = [:]
        generation &+= 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            guard generation == current else { return }
            flush()
        }
    }

    static func note(_ event: String) {
        guard isOpen else { return }
        let ms = Int((CACurrentMediaTime() - start) * 1000)
        events.append("+\(ms) \(event)")
    }

    static func body(_ name: String) {
        guard isOpen else { return }
        bodies[name, default: 0] += 1
    }

    private static func flush() {
        guard start > 0 else { return }
        start = 0
        let bodyText = bodies.sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        TestDiagnosticLog.ui(
            "details: \(label) — \(events.isEmpty ? "nothing else" : events.joined(separator: ", "))"
                + (bodyText.isEmpty ? "" : " · bodies: \(bodyText)")
        )
    }
}
