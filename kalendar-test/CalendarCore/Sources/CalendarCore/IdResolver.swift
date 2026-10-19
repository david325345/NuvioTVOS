import Foundation

/// Persistent storage for resolved ids. An IMDb → TMDB mapping does not
/// change, so it is worth keeping between launches.
public protocol IdCacheStore: Sendable {
    func load() -> [String: Int]
    func save(_ values: [String: Int])
}

public struct NoIdCacheStore: IdCacheStore {
    public init() {}
    public func load() -> [String: Int] { [:] }
    public func save(_ values: [String: Int]) {}
}

/// Turns a library id into a TMDB id.
///
/// Order: `tmdb:123` → bare number → `tt…` via TMDB `/find`. Anything else
/// (kitsu:, mal:, ...) is reported as unsupported for now.
public actor IdResolver {
    public enum Resolution: Equatable, Sendable {
        case resolved(Int)
        case unsupported
        case notFound
    }

    private let client: TmdbClient
    private let store: IdCacheStore
    private var cache: [String: Int]

    public init(client: TmdbClient, store: IdCacheStore = NoIdCacheStore()) {
        self.client = client
        self.store = store
        self.cache = store.load()
    }

    /// Parses ids that need no network call. `nil` means a lookup is needed
    /// (IMDb) or the format is unsupported.
    public static func directTmdbId(from rawId: String) -> Int? {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.hasPrefix("tmdb:") {
            let rest = id.dropFirst(5)
            let first = rest.split(separator: ":").first.map(String.init) ?? String(rest)
            if let value = Int(first), value > 0 { return value }
            return nil
        }
        if let value = Int(id), value > 0 { return value }
        return nil
    }

    /// "tt0903747:1:2" → "tt0903747"; nil when the id is not an IMDb id.
    public static func imdbId(from rawId: String) -> String? {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = id.split(separator: ":").first.map(String.init) ?? id
        guard base.hasPrefix("tt"), base.count > 2, base.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return base
    }

    public func resolve(_ item: LibraryItem) async throws -> Resolution {
        if let direct = IdResolver.directTmdbId(from: item.id) {
            return .resolved(direct)
        }
        guard let imdb = IdResolver.imdbId(from: item.id) else {
            return .unsupported
        }
        let key = "\(item.kind.rawValue):\(imdb)"
        if let cached = cache[key] {
            return .resolved(cached)
        }
        guard let found = try await client.findByImdb(imdb, kind: item.kind) else {
            return .notFound
        }
        cache[key] = found
        store.save(cache)
        return .resolved(found)
    }
}
