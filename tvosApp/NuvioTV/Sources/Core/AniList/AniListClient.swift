import CryptoKit
import Foundation

/// Talks to graphql.anilist.co (and api.ani.zip) from this Apple TV.
///
/// AniList allows 90 requests a minute per address and lately only 30, so every answer is
/// kept on disk for a while (`ttl`), the same request asked twice at once is sent once, and
/// requests wait for a free slot. When AniList says to slow down, or the request fails, the
/// last answer on disk is used even if it is old. Answers saved by another build of the app
/// are dropped when this one first asks.
actor AniListClient {
    static let shared = AniListClient(dropsAnswersFromOtherBuilds: true)

    enum ClientError: Error {
        case rateLimited
        case badResponse(Int)
        /// AniList answered 200 with only an error in it.
        case answeredWithError(String)
    }

    /// An answer, and whether it was saved earlier rather than given by AniList just now.
    struct Answer {
        let data: Data
        let isSaved: Bool
    }

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    /// Below the current limit of 30 a minute, so a burst never trips it.
    private static let requestsPerMinute = 25
    /// Longest wait for a free slot before an old answer, or an error, is returned instead.
    private static let longestWait: TimeInterval = 20

    /// The last answer AniList gave, for the status in Settings → Integrations → AniList.
    struct Status {
        var lastSuccess: Date?
        var lastFailure: Date?
        var lastFailureMessage: String?
    }

    private let session: URLSession
    private let cache: AniListDiskCache
    private(set) var status = Status()
    private var sentAt: [Date] = []
    private var blockedUntil: Date?
    private var inFlight: [String: Task<Answer, Error>] = [:]

    init(session: URLSession? = nil, cache: AniListDiskCache = AniListDiskCache(), dropsAnswersFromOtherBuilds: Bool = false) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.cache = cache
        if dropsAnswersFromOtherBuilds {
            cache.removeAllIfWritten(byAnotherBuildThan: AniListDiskCache.currentBuild)
        }
    }

    /// The JSON answer to a GraphQL query, from disk when it is younger than `ttl`.
    func query(_ query: String, variables: [String: Any?] = [:], ttl: TimeInterval, notesStatus: Bool = true) async throws -> Data {
        try await answer(query, variables: variables, ttl: ttl, notesStatus: notesStatus).data
    }

    /// `query`, telling whether the answer was saved earlier. `notesStatus: false` leaves the
    /// status in Settings alone (Test Connection).
    func answer(_ query: String, variables: [String: Any?] = [:], ttl: TimeInterval, notesStatus: Bool = true) async throws -> Answer {
        let body = try Self.body(query: query, variables: variables)
        let key = Self.cacheKey(for: body)
        if let fresh = cache.read(key: key, maxAge: ttl) {
            return Answer(data: fresh, isSaved: true)
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let task = Task { try await self.send(body: body, key: key, notesStatus: notesStatus) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// The answer on disk and how old it is, without asking AniList.
    func cached(_ query: String, variables: [String: Any?] = [:]) -> (data: Data, age: TimeInterval)? {
        guard let body = try? Self.body(query: query, variables: variables) else { return nil }
        return cache.readWithAge(key: Self.cacheKey(for: body))
    }

    /// A plain GET (api.ani.zip), kept on disk for `ttl`. It has no AniList rate limit.
    func get(_ url: URL, ttl: TimeInterval) async throws -> Data {
        let key = Self.cacheKey(for: Data(url.absoluteString.utf8))
        if let fresh = cache.read(key: key, maxAge: ttl) {
            return fresh
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw ClientError.badResponse(code) }
            cache.write(data, key: key)
            return data
        } catch {
            if let stale = cache.read(key: key, maxAge: .infinity) { return stale }
            throw error
        }
    }

    func clearCache() {
        cache.removeAll()
    }

    private func send(body: Data, key: String, notesStatus: Bool) async throws -> Answer {
        do {
            try await waitForSlot()
        } catch {
            if notesStatus { noteFailure("Waiting for AniList's rate limit") }
            if let stale = cache.read(key: key, maxAge: .infinity) { return Answer(data: stale, isSaved: true) }
            throw error
        }
        sentAt.append(Date())

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            noteLimits(from: http)
            let code = http?.statusCode ?? 0
            guard code == 200 else {
                let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
                if notesStatus { noteFailure("HTTP \(code) \(snippet)") }
                if code == 429 { throw ClientError.rateLimited }
                throw ClientError.badResponse(code)
            }
            if let message = Self.errorMessage(in: data) {
                // An error sent as 200. It is never saved, so the next ask reaches AniList.
                if notesStatus { noteFailure("AniList: \(message)") }
                if Self.hasData(data) { return Answer(data: data, isSaved: false) }
                throw ClientError.answeredWithError(message)
            }
            if notesStatus { status.lastSuccess = Date() }
            cache.write(data, key: key)
            return Answer(data: data, isSaved: false)
        } catch {
            // Bad answers are noted above with their body; this is the network failing.
            if notesStatus, !(error is ClientError) {
                noteFailure(error.localizedDescription)
            }
            if let stale = cache.read(key: key, maxAge: .infinity) { return Answer(data: stale, isSaved: true) }
            throw error
        }
    }

    func noteFailure(_ message: String) {
        status.lastFailure = Date()
        status.lastFailureMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForSlot() async throws {
        let deadline = Date().addingTimeInterval(Self.longestWait)
        while true {
            let now = Date()
            sentAt.removeAll { now.timeIntervalSince($0) >= 60 }
            var readyAt = now
            if let blockedUntil, blockedUntil > readyAt {
                readyAt = blockedUntil
            }
            if sentAt.count >= Self.requestsPerMinute, let oldest = sentAt.first {
                readyAt = max(readyAt, oldest.addingTimeInterval(60))
            }
            if readyAt <= now { return }
            guard readyAt <= deadline else { throw ClientError.rateLimited }
            try await Task.sleep(nanoseconds: UInt64(readyAt.timeIntervalSince(now) * 1_000_000_000) + 50_000_000)
        }
    }

    private func noteLimits(from response: HTTPURLResponse?) {
        guard let response else { return }
        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 60
            blockedUntil = Date().addingTimeInterval(retryAfter)
            return
        }
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap({ Int($0) }),
           remaining <= 0 {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { TimeInterval($0) }
            blockedUntil = reset.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(60)
        }
    }

    /// A variable without a value is left out, so its argument is left out too. AniList reads an
    /// explicit null as a filter: `isAdult: null` finds nothing, `season: null` nothing either.
    static func body(query: String, variables: [String: Any?]) throws -> Data {
        var cleaned: [String: Any] = [:]
        for (name, value) in variables {
            if let value, let present = unwrapped(value) {
                cleaned[name] = present
            }
        }
        return try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": cleaned],
            options: [.sortedKeys]
        )
    }

    /// The value inside however many optionals hold it (a `Bool?` passed as `Any?`), or nil.
    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first?.value else { return nil }
        return unwrapped(wrapped)
    }

    /// AniList's own error in an answer it sent as 200, joined into one line, or nil.
    static func errorMessage(in data: Data) -> String? {
        // Cheap look before parsing: nearly every answer has no errors.
        guard data.range(of: Data("\"errors\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]], !errors.isEmpty else { return nil }
        let messages = errors.compactMap { ($0["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return messages.isEmpty ? "unknown error" : messages.joined(separator: "; ")
    }

    /// Whether an answer with errors still carries some data (one of several pages, say).
    static func hasData(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any] else { return false }
        return payload.values.contains { !($0 is NSNull) }
    }

    static func cacheKey(for body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}

/// Answers from AniList and ani.zip, one file each in Caches/AniList.
struct AniListDiskCache {
    let directory: URL

    /// Raised when what is saved has to be read differently, so older answers are dropped.
    static let formatVersion = 2
    private static let buildMarker = ".build"

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches.appendingPathComponent("AniList", isDirectory: true)
        }
    }

    /// This copy of the app: its version and build, and when it was installed. Test builds can
    /// share a version and build, so the install time tells them apart.
    static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var installed = "?"
        if let executable = Bundle.main.executableURL,
           let modified = (try? FileManager.default.attributesOfItem(atPath: executable.path))?[.modificationDate] as? Date {
            installed = String(Int(modified.timeIntervalSince1970))
        }
        return "\(formatVersion)|\(version)|\(build)|\(installed)"
    }

    func read(key: String, maxAge: TimeInterval) -> Data? {
        let url = directory.appendingPathComponent(key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        guard maxAge == .infinity || Date().timeIntervalSince(modified) < maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    func readWithAge(key: String) -> (data: Data, age: TimeInterval)? {
        let url = directory.appendingPathComponent(key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, Date().timeIntervalSince(modified))
    }

    func write(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Drops every saved answer written by another build than `build`, then notes `build`.
    /// True when answers were dropped (or there was nothing noted yet).
    @discardableResult
    func removeAllIfWritten(byAnotherBuildThan build: String) -> Bool {
        let marker = directory.appendingPathComponent(Self.buildMarker)
        if let noted = try? String(contentsOf: marker, encoding: .utf8), noted == build {
            return false
        }
        removeAll()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(build.utf8).write(to: marker, options: .atomic)
        return true
    }
}
