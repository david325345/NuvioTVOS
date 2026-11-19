import Foundation

/// Test build only: where the pictures of the last AniList title came from (ani.zip, TMDB,
/// Metahub), and what its details screen then showed, for Settings → AniList.
enum AniListPictureLog {
    /// Set while a title is built, so the Home hero's own picture lookups don't fill the log.
    @TaskLocal static var isRecording = false

    private static let lock = NSLock()
    private static var lines: [String] = []
    static let limit = 40

    static func begin(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines = [stamp() + line]
    }

    /// A line while a title is built.
    static func note(_ line: String) {
        guard isRecording else { return }
        append(line)
    }

    /// A line from the details screen (backdrop, trailer).
    static func noteAlways(_ line: String) {
        append(line)
    }

    static func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? "No AniList title opened yet" : lines.joined(separator: "\n")
    }

    /// "artworks.thetvdb.com/…/62a1b2c3d.jpg", or "none".
    static func short(_ value: String?) -> String {
        guard let value, let url = URL(string: value), let host = url.host else { return "none" }
        let last = url.pathComponents.last.map { String($0.prefix(28)) } ?? ""
        return "\(host)/…/\(last)"
    }

    static func short(_ url: URL?) -> String { short(url?.absoluteString) }

    private static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(stamp() + line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date()) + "  "
    }
}
