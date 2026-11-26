import Foundation
import OSLog
import Combine

// Test build only (fork): what Usenet logs is also kept in the app, for Settings → Usenet →
// Usenet Log, so it can be read on the Apple TV without a Mac and Console.

/// `usenetLog`: the unified log (subsystem com.nuvio.tv, category Usenet) and `UsenetLogBook`.
struct UsenetLog: Sendable {
    private let logger = Logger(subsystem: "com.nuvio.tv", category: "Usenet")

    func info(_ message: UsenetLogMessage) {
        logger.info("\(message.text, privacy: .public)")
        UsenetLogBook.add(message.text, isError: false)
    }

    func notice(_ message: UsenetLogMessage) {
        logger.notice("\(message.text, privacy: .public)")
        UsenetLogBook.add(message.text, isError: false)
    }

    func error(_ message: UsenetLogMessage) {
        logger.error("\(message.text, privacy: .public)")
        UsenetLogBook.add(message.text, isError: true)
    }
}

/// A log line written like a `Logger` one: `"… \(value, privacy: .public) …"`.
struct UsenetLogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation<T>(_ value: T) {
            text += String(describing: value)
        }

        mutating func appendInterpolation<T>(_ value: T, privacy: OSLogPrivacy) {
            text += String(describing: value)
        }
    }
}

/// The last `limit` Usenet log lines since Nuvio started, newest first, in memory only.
@MainActor
final class UsenetLogBook: ObservableObject {
    static let shared = UsenetLogBook()
    static let limit = 200

    struct Line: Identifiable, Equatable {
        let id: UInt64
        let date: Date
        let text: String
        let isError: Bool
    }

    @Published private(set) var lines: [Line] = []
    private var nextID: UInt64 = 0

    nonisolated static func add(_ text: String, isError: Bool) {
        let date = Date()
        let safe = UsenetLogRedaction.redact(text)
        Task { @MainActor in
            shared.append(safe, date: date, isError: isError)
        }
    }

    private func append(_ text: String, date: Date, isError: Bool) {
        nextID &+= 1
        lines.insert(Line(id: nextID, date: date, text: text, isError: isError), at: 0)
        if lines.count > Self.limit { lines.removeLast(lines.count - Self.limit) }
    }

    func clear() {
        lines.removeAll()
    }
}

/// Never an address in the log: an NZB URL can carry an indexer key.
enum UsenetLogRedaction {
    private static let urlExpression = try! NSRegularExpression(pattern: #"(?i)\b[a-z][a-z0-9+.-]*://\S+"#)

    static func redact(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return urlExpression.stringByReplacingMatches(in: text, range: range, withTemplate: "<url>")
    }
}

/// Test build: what an indexer sent when it wasn't an NZB, for the Usenet Log. The host, the
/// HTTP answer, the size and kind, the XML parser's error and the first characters, with keys
/// and addresses taken out.
enum UsenetNZBDiagnostics {
    private static let keyExpression = try! NSRegularExpression(
        pattern: #"(?i)\b(apikey|api_key|key|token|r|i)=[^&\s"'<>]+"#
    )

    static func describe(_ data: Data, response: URLResponse, url: URL) -> String {
        let http = response as? HTTPURLResponse
        var parts = ["from \(url.host ?? "?")", "HTTP \(http?.statusCode ?? 0)"]
        if let type = http?.value(forHTTPHeaderField: "Content-Type") { parts.append(type) }
        if let disposition = http?.value(forHTTPHeaderField: "Content-Disposition") { parts.append(disposition) }
        parts.append("\(data.count) bytes")

        var xml: Data? = data
        if UsenetGzip.isGzip(data) {
            xml = try? UsenetGzip.inflate(data)
            parts.append(xml == nil ? "gzip that couldn't be inflated" : "gzip, \(xml?.count ?? 0) bytes inflated")
        } else if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            parts.append("a zip archive")
            xml = nil
        }
        if let xml {
            let parser = XMLParser(data: xml)
            if !parser.parse() {
                let error = parser.parserError.map { "\(($0 as NSError).code) \($0.localizedDescription)" } ?? "unknown"
                parts.append("XML error at line \(parser.lineNumber): \(error)")
            }
            parts.append("starts: \"\(snippet(xml))\"")
        }
        return parts.joined(separator: ", ")
    }

    static func snippet(_ data: Data) -> String {
        let head = String(decoding: data.prefix(300), as: UTF8.self)
        var text = String(head.map { character -> Character in
            if character.isWhitespace { return " " }
            return character.unicodeScalars.allSatisfy { $0.value >= 0x20 } ? character : "·"
        })
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let range = NSRange(text.startIndex..., in: text)
        text = keyExpression.stringByReplacingMatches(in: text, range: range, withTemplate: "$1=<redacted>")
        return UsenetLogRedaction.redact(text)
    }
}
