import Foundation

/// The Usenet log of the fork's test build (Settings → Advanced → Crash Reports & Usenet Log):
/// what a Usenet stream asked for and how long it took, and why the player moved to another
/// source. The last lines are kept in Caches/Diagnostics on this Apple TV and never sent anywhere.
enum TestDiagnosticLog {
    static let maximumLines = 1_000

    private static let queue = DispatchQueue(label: "nuvio.test-diagnostic-log", qos: .utility)
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var handle: FileHandle?
    /// Lines appended to the file since it was last rewritten with only the kept ones.
    nonisolated(unsafe) private static var appendedLines = 0

    static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("usenet.log")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// A line about Usenet playback.
    static func usenet(_ message: @autoclosure () -> String) {
        let line = timeFormatter.string(from: Date()) + "  " + message()
        queue.async {
            loadIfNeeded()
            lines.append(line)
            if lines.count > maximumLines { lines.removeFirst(lines.count - maximumLines) }
            // Written at once: the next line may never come if the app is about to crash.
            appendedLines += 1
            if appendedLines > maximumLines {
                rewrite()
            } else {
                handle?.write(Data((line + "\n").utf8))
            }
        }
    }

    /// At launch: a marker between app sessions.
    static func noteLaunch(version: String) {
        usenet("—— Nuvio \(version) started ——")
    }

    static func snapshot(_ completion: @escaping @Sendable ([String]) -> Void) {
        queue.async {
            loadIfNeeded()
            completion(lines)
        }
    }

    static func clear() {
        queue.async {
            loadIfNeeded()
            lines.removeAll()
            rewrite()
        }
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(maximumLines))
        }
        rewrite()
    }

    /// The file again with only the kept lines, open for appending.
    private static func rewrite() {
        appendedLines = 0
        try? handle?.close()
        handle = nil
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// "12.3 MB" for logs.
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Milliseconds since `start`.
    static func elapsed(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1_000)) ms"
    }
}
