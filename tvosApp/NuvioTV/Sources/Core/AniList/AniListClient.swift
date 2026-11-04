import CryptoKit
import Foundation

/// Talks to graphql.anilist.co (and api.ani.zip) from this Apple TV.
///
/// AniList allows 90 requests a minute per address and lately only 30, so every answer is
/// kept on disk for a while (`ttl`), the same request asked twice at once is sent once, and
/// requests wait for a free slot. When AniList says to slow down, or the request fails, the
/// last answer on disk is used even if it is old.
actor AniListClient {
    static let shared = AniListClient()

    enum ClientError: Error {
        case rateLimited
        case badResponse(Int)
    }

    private static let endpoint = URL(string: "https://graphql.anilist.co")!
    /// Below the current limit of 30 a minute, so a burst never trips it.
    private static let requestsPerMinute = 25
    /// Longest wait for a free slot before an old answer, or an error, is returned instead.
    private static let longestWait: TimeInterval = 20

    private let session: URLSession
    private let cache: AniListDiskCache
    private var sentAt: [Date] = []
    private var blockedUntil: Date?
    private var inFlight: [String: Task<Data, Error>] = [:]

    init(session: URLSession? = nil, cache: AniListDiskCache = AniListDiskCache()) {
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
    }

    /// The JSON answer to a GraphQL query, from disk when it is younger than `ttl`.
    func query(_ query: String, variables: [String: Any?] = [:], ttl: TimeInterval) async throws -> Data {
        let body = try Self.body(query: query, variables: variables)
        let key = Self.cacheKey(for: body)
        if let fresh = cache.read(key: key, maxAge: ttl) {
            return fresh
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let task = Task { try await self.send(body: body, key: key) }
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ClientError.badResponse(status) }
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

    private func send(body: Data, key: String) async throws -> Data {
        do {
            try await waitForSlot()
        } catch {
            if let stale = cache.read(key: key, maxAge: .infinity) { return stale }
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
            let status = http?.statusCode ?? 0
            guard status == 200 else {
                if status == 429 { throw ClientError.rateLimited }
                throw ClientError.badResponse(status)
            }
            cache.write(data, key: key)
            return data
        } catch {
            if let stale = cache.read(key: key, maxAge: .infinity) { return stale }
            throw error
        }
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

    static func body(query: String, variables: [String: Any?]) throws -> Data {
        var cleaned: [String: Any] = [:]
        for (name, value) in variables {
            cleaned[name] = value ?? NSNull()
        }
        return try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": cleaned],
            options: [.sortedKeys]
        )
    }

    static func cacheKey(for body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}

/// Answers from AniList and ani.zip, one file each in Caches/AniList.
struct AniListDiskCache {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches.appendingPathComponent("AniList", isDirectory: true)
        }
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
}
