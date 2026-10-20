import Foundation

/// How much memory the engine may use for decoded articles, and how far it
/// reads ahead of the player. Mirrors the profiles of NuvioTV (Android).
enum UsenetMemoryProfile: String, CaseIterable, Sendable {
    case lowMemory
    case balanced
    case highThroughput

    var cacheBytes: Int {
        switch self {
        case .lowMemory: return 32 << 20
        case .balanced: return 64 << 20
        case .highThroughput: return 128 << 20
        }
    }

    /// Read-ahead as a share of the cache, so prefetched articles aren't
    /// evicted before the player reaches them.
    var readAheadBytes: Int { cacheBytes * 3 / 5 }

    var title: String {
        switch self {
        case .lowMemory: return L10n.string("usenet_profile_low", fallback: "Low Memory")
        case .balanced: return L10n.string("usenet_profile_balanced", fallback: "Balanced")
        case .highThroughput: return L10n.string("usenet_profile_high", fallback: "High Throughput")
        }
    }
}

/// Where each article's decoded bytes sit in the file.
///
/// Posters split files into equal parts, so after decoding the first article
/// (`=ypart begin/end`, `=ybegin size`) every other article's range follows
/// arithmetically. When the article count doesn't fit that, ranges learned
/// from decoded articles are used and the rest are estimated from the NZB's
/// encoded sizes and corrected as articles arrive.
struct UsenetFileLayout: Sendable, Equatable {
    let totalSize: Int64
    let partSize: Int64
    let segmentCount: Int
    /// Equal parts that add up to `totalSize`.
    let isRegular: Bool
    /// Cumulative encoded sizes, for estimating irregular layouts.
    private let encodedStarts: [Int64]
    private let encodedTotal: Int64
    private(set) var known: [Int: Range<Int64>] = [:]

    init(totalSize: Int64, firstPart: Range<Int64>, segments: [UsenetSegment]) {
        self.totalSize = totalSize
        self.segmentCount = segments.count
        let part = max(1, firstPart.upperBound - firstPart.lowerBound)
        self.partSize = part
        let expected = Int((totalSize + part - 1) / part)
        self.isRegular = expected == segments.count && firstPart.lowerBound == 0
        var starts: [Int64] = []
        var running: Int64 = 0
        for segment in segments {
            starts.append(running)
            running += Int64(max(1, segment.bytes))
        }
        self.encodedStarts = starts
        self.encodedTotal = max(1, running)
        known[0] = firstPart
    }

    mutating func learn(_ index: Int, range: Range<Int64>) {
        known[index] = range
    }

    /// The bytes article `index` holds, when known or regular.
    func range(of index: Int) -> Range<Int64>? {
        if let range = known[index] { return range }
        guard isRegular, index >= 0, index < segmentCount else { return nil }
        let start = Int64(index) * partSize
        return start..<min(totalSize, start + partSize)
    }

    /// The article holding `offset`, or the best guess to probe next.
    func index(for offset: Int64) -> (index: Int, certain: Bool) {
        if isRegular {
            return (min(segmentCount - 1, max(0, Int(offset / partSize))), true)
        }
        if let hit = known.first(where: { $0.value.contains(offset) }) {
            return (hit.key, true)
        }
        // Scale the offset into the encoded sizes, then nudge by neighbours we know.
        let target = Int64(Double(offset) / Double(max(1, totalSize)) * Double(encodedTotal))
        var low = 0, high = segmentCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if encodedStarts[mid] <= target { low = mid } else { high = mid - 1 }
        }
        var guess = low
        if let below = known.filter({ $0.value.upperBound <= offset }).max(by: { $0.key < $1.key }) {
            guess = max(guess, below.key + 1)
        }
        if let above = known.filter({ $0.value.lowerBound > offset }).min(by: { $0.key < $1.key }) {
            guess = min(guess, above.key - 1)
        }
        return (min(segmentCount - 1, max(0, guess)), false)
    }
}

/// Serves byte ranges of one Usenet file to the local HTTP server, fetching
/// and decoding articles on demand with read-ahead and an in-memory cache.
actor UsenetStreamSession {
    let file: UsenetFile
    private let pool: UsenetConnectionPool
    private let profile: UsenetMemoryProfile

    private(set) var layout: UsenetFileLayout?
    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var cachedBytes = 0
    private var inflight: [Int: Task<Data, Error>] = [:]
    private var prefetching: Set<Int> = []
    private var playhead = 0

    private(set) var downloadedBytes: Int64 = 0
    private(set) var missingArticles = 0

    init(file: UsenetFile, pool: UsenetConnectionPool, profile: UsenetMemoryProfile) {
        self.file = file
        self.pool = pool
        self.profile = profile
    }

    var totalSize: Int64 { layout?.totalSize ?? 0 }

    /// Decodes the first article to learn the file size and part layout, then
    /// warms the head and the tail (MKV keeps its seek index at the end).
    func prepare() async throws {
        guard let first = file.segments.first else { throw UsenetError.noPlayableFile }
        guard case .body(let lines) = try await pool.fetch(messageID: first.messageID) else {
            throw UsenetError.firstSegmentUnavailable
        }
        let decoded = try await Self.decode(lines)
        let size = Int64(decoded.header.size ?? decoded.data.count)
        let begin = Int64(decoded.fileOffset)
        let firstRange = begin..<(begin + Int64(decoded.data.count))
        layout = UsenetFileLayout(totalSize: size, firstPart: firstRange, segments: file.segments)
        store(0, decoded.data)
        downloadedBytes += Int64(decoded.data.count)

        let count = file.segments.count
        let warm = [1, count - 2, count - 1].filter { $0 > 0 && $0 < count }
        for index in Set(warm) { startPrefetch(index) }
        prefetch(after: 0)
    }

    /// Up to `maxLength` bytes starting at `offset`, never crossing an article boundary.
    /// Side reads (the player's index lookups at the end of the file) pass
    /// `updatesPlayhead: false` so they don't move the read-ahead window.
    func read(offset: Int64, maxLength: Int, updatesPlayhead: Bool = true) async throws -> Data {
        guard let current = layout else { throw UsenetError.noPlayableFile }
        guard offset < current.totalSize else { return Data() }

        var probe = current.index(for: offset)
        var hops = 0
        while true {
            let data = try await article(probe.index)
            guard let range = layout?.range(of: probe.index) else { throw UsenetError.noPlayableFile }
            if range.contains(offset) {
                if updatesPlayhead { noteRead(probe.index) }
                let start = Int(offset - range.lowerBound)
                let end = min(data.count, start + maxLength)
                guard start < end else { return Data() }
                return data.subdata(in: start..<end)
            }
            // Irregular layout: walk towards the article that holds the offset.
            hops += 1
            guard hops < 64 else { throw UsenetError.noPlayableFile }
            let next = offset < range.lowerBound ? probe.index - 1 : probe.index + 1
            guard next >= 0, next < file.segments.count else { return Data() }
            probe = (next, false)
        }
    }

    func stop() async {
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
        cache = [:]
        cacheOrder = []
        cachedBytes = 0
        await pool.shutdown()
    }

    // MARK: - Articles

    private func article(_ index: Int) async throws -> Data {
        if let data = cache[index] {
            touch(index)
            return data
        }
        if let task = inflight[index] {
            // A read-ahead fetch is already on its way: wait for it instead
            // of fetching twice, and take over its bookkeeping.
            prefetching.remove(index)
            defer { if inflight[index] == task { inflight[index] = nil } }
            return try await task.value
        }
        let task = makeTask(index)
        inflight[index] = task
        defer { inflight[index] = nil }
        return try await task.value
    }

    private func makeTask(_ index: Int) -> Task<Data, Error> {
        let segment = file.segments[index]
        let pool = self.pool
        return Task {
            let outcome = try await pool.fetch(messageID: segment.messageID)
            switch outcome {
            case .body(let lines):
                let decoded = try await Self.decode(lines)
                await self.accept(index, decoded)
                return decoded.data
            case .missing:
                // Keep playing past a hole rather than failing the whole stream:
                // the player usually skips a damaged frame.
                let filler = await self.filler(for: index)
                await self.noteMissing()
                return filler
            }
        }
    }

    private func accept(_ index: Int, _ decoded: UsenetYEncSegment) {
        let begin = Int64(decoded.fileOffset)
        layout?.learn(index, range: begin..<(begin + Int64(decoded.data.count)))
        store(index, decoded.data)
        downloadedBytes += Int64(decoded.data.count)
    }

    private func filler(for index: Int) -> Data {
        let length = layout?.range(of: index).map { Int($0.upperBound - $0.lowerBound) } ?? 0
        let data = Data(count: length)
        store(index, data)
        return data
    }

    private func noteMissing() { missingArticles += 1 }

    private static func decode(_ lines: [Data]) async throws -> UsenetYEncSegment {
        try await Task.detached(priority: .userInitiated) {
            try UsenetYEnc.decode(bodyLines: lines)
        }.value
    }

    // MARK: - Read-ahead

    private var readAheadSegments: Int {
        let part = Int(layout?.partSize ?? 716_800)
        return max(4, profile.readAheadBytes / max(1, part))
    }

    /// Prefetch slots: all connections but one, so a demand read after a seek
    /// isn't stuck behind read-ahead.
    private var prefetchSlots: Int { max(1, pool.totalConnections - 1) }

    private func noteRead(_ index: Int) {
        let jumped = abs(index - playhead) > 2
        playhead = index
        if jumped {
            // A seek: read-ahead for the old position is no longer useful.
            let window = index...(index + readAheadSegments)
            for (pending, task) in inflight where prefetching.contains(pending) && !window.contains(pending) {
                task.cancel()
                inflight[pending] = nil
                prefetching.remove(pending)
            }
        }
        prefetch(after: index)
    }

    private func prefetch(after index: Int) {
        let last = min(file.segments.count - 1, index + readAheadSegments)
        guard index + 1 <= last else { return }
        for next in (index + 1)...last {
            guard prefetching.count < prefetchSlots else { return }
            startPrefetch(next)
        }
    }

    private func startPrefetch(_ index: Int) {
        guard cache[index] == nil, inflight[index] == nil else { return }
        let task = makeTask(index)
        inflight[index] = task
        prefetching.insert(index)
        Task {
            _ = try? await task.value
            self.prefetchFinished(index)
        }
    }

    private func prefetchFinished(_ index: Int) {
        guard prefetching.remove(index) != nil else { return }
        inflight[index] = nil
        prefetch(after: playhead)
    }

    // MARK: - Cache

    private func store(_ index: Int, _ data: Data) {
        if cache[index] == nil { cachedBytes += data.count }
        cache[index] = data
        touch(index)
        while cachedBytes > profile.cacheBytes, let oldest = cacheOrder.first(where: { $0 != index }) {
            cacheOrder.removeAll { $0 == oldest }
            cachedBytes -= cache.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    private func touch(_ index: Int) {
        cacheOrder.removeAll { $0 == index }
        cacheOrder.append(index)
    }
}
