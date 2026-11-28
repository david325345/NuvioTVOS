import Foundation
import Combine

/// Live numbers for the loading overlay and the playback HUD.
struct UsenetStreamStats: Equatable, Sendable {
    var downloadRate: Double = 0
    var busyConnections = 0
    /// What the servers accept, fewer than `configuredConnections` once a
    /// server turned a connection away.
    var totalConnections = 0
    var configuredConnections = 0
    var bufferedAheadBytes: Int64 = 0
    /// The same in seconds of video, once the player knows the duration.
    var bufferedAheadSeconds: Double?
    /// Articles kept on disk (Read Ahead on Disk), what they may use now and what tvOS
    /// reports free (-1: unknown).
    var diskBytes: Int64 = 0
    var diskBudgetBytes: Int64 = 0
    var diskFreeBytes: Int64 = -1
    var cacheHitRate: Double?
    var missingArticles = 0
    /// Articles no server had an intact copy of (bad CRC), played as they came.
    var damagedArticles = 0
    var fallbackArticles = 0
    /// Connections closed and opened again (idle too long, or dropped).
    var reconnects = 0
    var server = ""
    var serverCount = 0
    var fileName = ""
    var kind = ""
    var fileSize: Int64 = 0
    var speedLimitMbps = 0
    /// Read-ahead requests per connection at once; 1 when pipelining is off.
    var pipelineDepth = 1

    var downloadRateFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(downloadRate), countStyle: .file) + "/s"
    }

    var bufferedFormatted: String {
        let bytes = ByteCountFormatter.string(fromByteCount: bufferedAheadBytes, countStyle: .memory)
        guard let bufferedAheadSeconds, bufferedAheadSeconds.isFinite else { return bytes }
        return bytes + " (\(Int(bufferedAheadSeconds.rounded())) s)"
    }

    var connectionsText: String { "\(busyConnections)/\(totalConnections)" }

    /// HUD line 1: where the articles come from and how fast.
    var connectionLine: String {
        let host = server.isEmpty ? "Usenet" : server + (serverCount > 1 ? " +\(serverCount - 1)" : "")
        var connections = "\(connectionsText) conn"
        if configuredConnections > totalConnections { connections += " (\(configuredConnections) set)" }
        var parts = [host, connections, downloadRateFormatted]
        if speedLimitMbps > 0 { parts.append("max \(speedLimitMbps) Mbit/s") }
        if pipelineDepth > 1 { parts.append("pipeline ×\(pipelineDepth)") }
        return parts.joined(separator: " · ")
    }

    /// HUD line 2: what the article cache holds and what went missing.
    var cacheLine: String {
        var parts = ["ahead \(bufferedFormatted)"]
        if let cacheHitRate { parts.append("hit \(Int((cacheHitRate * 100).rounded()))%") }
        parts.append("missing \(missingArticles)")
        if damagedArticles > 0 { parts.append("damaged \(damagedArticles)") }
        if fallbackArticles > 0 { parts.append("backup \(fallbackArticles)") }
        if reconnects > 0 { parts.append("reconnect \(reconnects)") }
        return parts.joined(separator: " · ")
    }

    /// HUD line 3 with Read Ahead on Disk: what it holds, what it may use now and what tvOS
    /// reports free; nil when it is off.
    var diskLine: String? {
        guard diskBudgetBytes > 0 || diskBytes > 0 else { return nil }
        var line = ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file)
            + " of " + ByteCountFormatter.string(fromByteCount: diskBudgetBytes, countStyle: .file)
        if diskFreeBytes >= 0 {
            line += " · tvOS free " + ByteCountFormatter.string(fromByteCount: diskFreeBytes, countStyle: .file)
        }
        return line
    }

    var summary: String { connectionLine + " · " + cacheLine }
}

/// Starts and stops the one active Usenet stream, the way
/// `TorrentEngineManager` does for torrents.
@MainActor
final class UsenetEngineManager: ObservableObject {
    static let shared = UsenetEngineManager()

    @Published private(set) var isStreaming = false
    @Published private(set) var lastError: String?
    @Published private(set) var activeStats = UsenetStreamStats()
    /// Set when the playing release turns out too damaged; the player then
    /// switches to another source at the current position.
    @Published private(set) var damagedStreamURL: URL?
    private var damagedGeneration: Int?

    private var session: UsenetStreamSession?
    private var server: UsenetStreamServer?
    private var pool: UsenetConnectionPool?
    private var statsTask: Task<Void, Never>?
    private(set) var activeStreamURL: URL?
    /// The playing stream, for remembering it damaged.
    private var activeSpec: UsenetStreamSpec?
    /// The uploads (`uploadIDs(of:)`) that failed to start or played damaged in this run of the
    /// app, and the playing one's: automatic failover passes another indexer's copy of them by.
    private var failedUploads = Set<String>()
    private var activeUploadIDs = Set<String>()
    /// The playing stream's servers, so a preparation for the same ones shares its pool.
    private var activeServers: [UsenetServerConfig] = []
    /// A stream got ready ahead (`prepare`): starting it skips the NZB, the file and the check.
    private var preparedStart: PreparedStart?
    private var generation = 0
    /// The duration last passed to the session.
    private var reportedDuration: Double = 0

    private init() {}

    /// Downloads and parses the NZB, connects to the servers, works out the
    /// file (also inside stored RAR sets and obfuscated releases), checks the
    /// release is complete and returns the local playback URL.
    ///
    /// `skippingFailedUploads` (automatic failover): an upload that failed already, from any
    /// indexer, fails at once once its NZB is read, without connecting to a server.
    func startStream(_ spec: UsenetStreamSpec, skippingFailedUploads: Bool = false) async throws -> URL {
        generation &+= 1
        let current = generation
        await stopCurrent()
        lastError = nil

        let servers = UsenetSettings.servers(for: spec)
        guard !servers.isEmpty else {
            lastError = UsenetError.noServers.localizedDescription
            throw UsenetError.noServers
        }

        // Test build only (fork): connections opened ahead for these servers, when there are.
        let startClock = ContinuousClock()
        let startedAt = startClock.now
        let speedLimit = UsenetSettings.speedLimitMbps()
        let depth = UsenetSettings.pipelineDepth()
        let warm = await takeWarmPool(servers: servers, speedLimitMbps: speedLimit, pipelineDepth: depth)
        let pool = warm?.pool ?? UsenetConnectionPool(servers: servers, speedLimitMbps: speedLimit, pipelineDepth: depth)
        var health: UsenetHealthCheck.Result?
        var uploadIDs = Set<String>()
        let prepared = takePrepared(spec)
        do {
            let source: UsenetStreamSource
            if let prepared {
                source = prepared.source
                uploadIDs = prepared.uploadIDs
                usenetLog.notice("usenet: \(source.name, privacy: .public) — got ready ahead, starting at once")
            } else {
                source = try await Self.readyRelease(
                    spec, pool: pool, skipping: skippingFailedUploads ? failedUploads : [],
                    health: &health, uploadIDs: &uploadIDs
                )
            }
            try Task.checkCancellation()

            // Off the main thread: it clears what an earlier stream left on disk.
            let diskBytes = UsenetSettings.diskReadAheadBytes()
            let diskReadAhead = await Task.detached(priority: .userInitiated) {
                UsenetDiskReadAhead.make(sizeBytes: diskBytes)
            }.value
            let session = UsenetStreamSession(
                source: source, pool: pool, profile: UsenetSettings.profile(), diskReadAhead: diskReadAhead
            ) { [weak self] in
                Task { @MainActor in self?.reportDamage(generation: current) }
            }
            try await session.prepare()
            guard current == generation, !Task.isCancelled else {
                await session.stop()
                throw CancellationError()
            }
            let server = UsenetStreamServer(session: session, fileName: source.name, fileLength: source.totalSize)
            let url = try await server.start()
            self.session = session
            self.server = server
            self.pool = pool
            self.activeStreamURL = url
            self.activeSpec = spec
            self.activeUploadIDs = uploadIDs
            self.activeServers = servers
            activeStats = UsenetStreamStats(
                totalConnections: pool.totalConnections,
                configuredConnections: pool.totalConnections,
                server: servers.first?.host ?? "",
                serverCount: servers.count,
                fileName: source.name,
                kind: source.kind.rawValue,
                fileSize: source.totalSize,
                speedLimitMbps: pool.speedLimitMbps,
                pipelineDepth: pool.pipelineDepth
            )
            isStreaming = true
            Self.remember(source: spec.url.absoluteString, playback: url.absoluteString)
            if damagedGeneration == current { damagedStreamURL = url }
            startStatsLoop(session: session, pool: pool, generation: current)
            let took = UsenetConnectionPool.warmMilliseconds(startClock.now - startedAt)
            let how = warm.map { "\($0.idle) warm connection(s) waiting, opened \(Int($0.age)) s before" }
                ?? "no warm connections (cold)"
            usenetLog.notice("warm-test: \(source.name, privacy: .public) started in \(took) ms with \(how, privacy: .public)")
            return url
        } catch is CancellationError {
            await pool.shutdown()
            throw CancellationError()
        } catch {
            await pool.shutdown()
            if (error as? UsenetError) == .nzbUnreadable { UsenetNZBCache.remove(spec.nzbURL) }
            if let report = Self.startFailureReport(error, health: health) {
                UsenetAvailabilityChecker.shared.recordPlayback(spec, report: report)
            }
            if Self.isReleaseProblem(error) { failedUploads.formUnion(uploadIDs) }
            lastError = error.localizedDescription
            usenetLog.error("usenet: start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The NZB read, the file worked out and the release checked: what a start waits for
    /// before the session opens. `health` and `uploadIDs` are filled as soon as known, for
    /// what a failure remembers. An upload in `skipping` fails at once, before any server.
    private static func readyRelease(
        _ spec: UsenetStreamSpec, pool: UsenetConnectionPool, skipping: Set<String>,
        health: inout UsenetHealthCheck.Result?, uploadIDs: inout Set<String>
    ) async throws -> UsenetStreamSource {
        let nzb = try await loadNZB(spec.nzbURL)
        uploadIDs = Self.uploadIDs(of: nzb)
        if !uploadIDs.isDisjoint(with: skipping) {
            usenetLog.notice("usenet: the same upload as a release that failed (another indexer's copy), skipped")
            throw UsenetError.releaseIncomplete
        }
        let resolver = UsenetReleaseResolver(nzb: nzb, pool: pool, mustInclude: spec.fileMustInclude, fileIdx: spec.fileIdx)
        let source = try await resolver.resolve()
        try Task.checkCancellation()
        let checked = try await UsenetHealthCheck.check(source, pool: pool)
        health = checked
        usenetLog.notice("usenet: \(source.name, privacy: .public) [\(source.kind.rawValue, privacy: .public)] — \(source.volumes.count) file(s), \(checked.missing)/\(checked.checked) sampled articles missing")
        guard UsenetHealthCheck.isPlayable(checked) else { throw UsenetError.releaseIncomplete }
        return source
    }

    // MARK: - Getting a stream ready ahead

    private struct PreparedStart {
        let url: URL
        let source: UsenetStreamSource
        let uploadIDs: Set<String>
        let at: Date
    }

    /// How long a stream got ready ahead may wait to be started; the check is redone after.
    static let preparedLifetime: TimeInterval = 30 * 60
    /// Connections a preparation opens when it can't share the playing stream's.
    static let preparationConnections = 2

    /// Gets `spec` ready while another stream plays (the next episode): reads its NZB, works
    /// out its file and checks the release, without stopping or slowing the playing stream.
    /// It shares the playing stream's connections when the servers are the same (no more
    /// connections than the plan allows), else opens two of its own. `startStream(spec)` then
    /// skips all that. Throws what a start would (an incomplete release, say); a broken
    /// release is remembered like one that failed to start.
    func prepare(_ spec: UsenetStreamSpec) async throws {
        if let preparedStart, preparedStart.url == spec.url,
           Date().timeIntervalSince(preparedStart.at) < Self.preparedLifetime { return }
        let servers = UsenetSettings.servers(for: spec)
        guard !servers.isEmpty else { throw UsenetError.noServers }
        let shared = servers == activeServers ? self.pool : nil
        let preparationPool = shared ?? UsenetConnectionPool(servers: servers.map {
            UsenetServerConfig(host: $0.host, port: $0.port, useSSL: $0.useSSL, username: $0.username,
                               password: $0.password, maxConnections: min($0.maxConnections, Self.preparationConnections))
        })
        var health: UsenetHealthCheck.Result?
        var uploadIDs = Set<String>()
        do {
            let source = try await Self.readyRelease(
                spec, pool: preparationPool, skipping: failedUploads, health: &health, uploadIDs: &uploadIDs
            )
            if shared == nil { await preparationPool.shutdown() }
            preparedStart = PreparedStart(url: spec.url, source: source, uploadIDs: uploadIDs, at: Date())
        } catch {
            if shared == nil { await preparationPool.shutdown() }
            if Self.isReleaseProblem(error) { failedUploads.formUnion(uploadIDs) }
            if let report = Self.startFailureReport(error, health: health) {
                UsenetAvailabilityChecker.shared.recordPlayback(spec, report: report)
            }
            usenetLog.notice("usenet: couldn't get the next stream ready: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The release `prepare` got ready for `spec`, once: nil when there is none or it waited too long.
    private func takePrepared(_ spec: UsenetStreamSpec) -> PreparedStart? {
        guard let preparedStart, preparedStart.url == spec.url else { return nil }
        self.preparedStart = nil
        guard Date().timeIntervalSince(preparedStart.at) < Self.preparedLifetime else { return nil }
        return preparedStart
    }

    /// What a start that failed for missing articles showed, for the stream list to remember:
    /// the release check's numbers, or that it wouldn't start (its files' first articles gone).
    nonisolated static func startFailureReport(_ error: Error, health: UsenetHealthCheck.Result?) -> UsenetAvailabilityReport? {
        guard let usenet = error as? UsenetError,
              usenet == .releaseIncomplete || usenet == .firstSegmentUnavailable else { return nil }
        if let health, !UsenetHealthCheck.isPlayable(health) {
            return UsenetAvailabilityReport(checked: health.checked, missing: health.missing,
                                            tailMissing: health.tailMissing, nzbGaps: 0, missingVolumes: 0)
        }
        return UsenetAvailabilityReport(checked: 0, missing: 0, tailMissing: false, nzbGaps: 0,
                                        missingVolumes: 0, playbackProblem: .wouldNotStart)
    }

    /// A delayed player exit only stops its own stream, never a newer one.
    func stopActiveStream(for sourceURL: URL) async {
        guard activeStreamURL == sourceURL else { return }
        generation &+= 1
        await stopCurrent()
    }

    func stopAll() async {
        generation &+= 1
        await stopCurrent()
    }

    // MARK: - Test build only (fork): connections opened ahead and kept alive

    private struct WarmPool {
        let servers: [UsenetServerConfig]
        let speedLimitMbps: Int
        let pipelineDepth: Int
        let pool: UsenetConnectionPool
        let created: Date
        var until: Date
    }

    private var warmPool: WarmPool?
    private var warmKeeper: Task<Void, Never>?
    private var warmKeptAlive = 0
    /// Connections opened ahead, to the first server.
    static let warmConnections = 4
    /// How long they're kept after the stream list last showed Usenet streams.
    static let warmLifetime: TimeInterval = 5 * 60
    /// Idle connections older than this are kept alive (STAT), checked every `warmKeepAliveEvery`.
    static let warmPingAfter: Duration = .seconds(25)
    static let warmKeepAliveEvery: Duration = .seconds(10)

    /// The stream list shows Usenet streams: opens a few connections to their servers ahead and
    /// keeps them alive, so playing one skips connecting and logging in. Nothing while a stream
    /// plays (it holds its own).
    func warmUp(for spec: UsenetStreamSpec) {
        guard !isStreaming else { return }
        let servers = UsenetSettings.servers(for: spec)
        guard let first = servers.first else { return }
        let speedLimit = UsenetSettings.speedLimitMbps()
        let depth = UsenetSettings.pipelineDepth()
        let until = Date().addingTimeInterval(Self.warmLifetime)
        if var warm = warmPool, warm.servers == servers, warm.speedLimitMbps == speedLimit, warm.pipelineDepth == depth {
            warm.until = until
            warmPool = warm
            return
        }
        if let old = warmPool { Task { await old.pool.shutdown() } }
        let pool = UsenetConnectionPool(servers: servers, speedLimitMbps: speedLimit, pipelineDepth: depth)
        warmPool = WarmPool(servers: servers, speedLimitMbps: speedLimit, pipelineDepth: depth,
                            pool: pool, created: Date(), until: until)
        warmKeptAlive = 0
        let count = min(Self.warmConnections, first.maxConnections)
        let host = first.host
        Task {
            let result = await pool.warmUp(count: count)
            let times = result.opened.sorted()
            let median = times.isEmpty ? 0 : times[times.count / 2]
            let list = times.map { String($0) }.joined(separator: ", ")
            let failures = result.failed > 0 ? ", \(result.failed) failed" : ""
            usenetLog.notice("warm-test: opened \(times.count) of \(count) connections to \(host, privacy: .public) ahead (connect + TLS + login: \(list) ms, median \(median) ms)\(failures)")
        }
        startWarmKeeper()
    }

    private func startWarmKeeper() {
        guard warmKeeper == nil else { return }
        warmKeeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.warmKeepAliveEvery)
                guard let self, !Task.isCancelled else { return }
                guard let warm = self.warmPool else {
                    self.warmKeeper = nil
                    return
                }
                if Date() > warm.until {
                    self.warmPool = nil
                    self.warmKeeper = nil
                    await warm.pool.shutdown()
                    usenetLog.notice("warm-test: closed the warm connections, no stream played within \(Int(Self.warmLifetime / 60)) minutes (kept alive \(self.warmKeptAlive) times)")
                    return
                }
                let result = await warm.pool.keepIdleAlive(after: Self.warmPingAfter)
                self.warmKeptAlive += result.kept
                if result.dropped > 0 {
                    usenetLog.notice("warm-test: the server closed \(result.dropped) idle warm connection(s) (kept alive \(self.warmKeptAlive) times so far)")
                }
            }
        }
    }

    /// The warm pool when it is for exactly these servers and settings, taken for a stream;
    /// another one is closed.
    private func takeWarmPool(servers: [UsenetServerConfig], speedLimitMbps: Int,
                              pipelineDepth: Int) async -> (pool: UsenetConnectionPool, idle: Int, age: TimeInterval)? {
        guard let warm = warmPool else { return nil }
        warmPool = nil
        warmKeeper?.cancel()
        warmKeeper = nil
        guard warm.servers == servers, warm.speedLimitMbps == speedLimitMbps, warm.pipelineDepth == pipelineDepth else {
            await warm.pool.shutdown()
            usenetLog.notice("warm-test: the warm connections were for other servers or settings, closed")
            return nil
        }
        let idle = await warm.pool.idleConnections
        return (warm.pool, idle, Date().timeIntervalSince(warm.created))
    }

    /// Errors where another release of the same title may well work, so the
    /// caller can move on to the next Usenet stream.
    nonisolated static func isReleaseProblem(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let usenet = error as? UsenetError else { return true }
        switch usenet {
        case .noServers, .serverRejected: return false
        default: return true
        }
    }

    private func stopCurrent() async {
        statsTask?.cancel()
        statsTask = nil
        let session = self.session
        let server = self.server
        self.session = nil
        self.server = nil
        self.pool = nil
        activeStreamURL = nil
        activeSpec = nil
        activeUploadIDs = []
        activeServers = []
        reportedDuration = 0
        isStreaming = false
        activeStats = UsenetStreamStats()
        damagedStreamURL = nil
        damagedGeneration = nil
        await server?.stop()
        await session?.stop()
        // Test build only (fork): the yEnc measurement's summary for this stream.
        if session != nil { UsenetYEncBench.flush() }
    }

    /// The player's duration for the playing Usenet stream, once (and when it
    /// changes): the session sizes its read-ahead in seconds of video.
    func reportDuration(_ duration: Double, playbackURL: String?) {
        guard let session, let activeStreamURL, playbackURL == activeStreamURL.absoluteString,
              duration.isFinite, duration > 60, abs(duration - reportedDuration) > 1 else { return }
        // The first time: the player opened the file and read its length, so the release
        // plays on these servers.
        if reportedDuration == 0, let activeSpec { UsenetAvailabilityChecker.shared.recordPlayed(activeSpec) }
        reportedDuration = duration
        Task { await session.setDuration(duration) }
    }

    private func reportDamage(generation: Int) {
        guard generation == self.generation else { return }
        damagedGeneration = generation
        if let activeStreamURL { damagedStreamURL = activeStreamURL }
        if let activeSpec {
            UsenetAvailabilityChecker.shared.recordPlayback(activeSpec, report: UsenetAvailabilityReport(
                checked: 0, missing: 0, tailMissing: false, nzbGaps: 0, missingVolumes: 0, playbackProblem: .damaged
            ))
        }
        failedUploads.formUnion(activeUploadIDs)
    }

    /// What identifies an upload whichever indexer's NZB lists it: the message-ID of the first
    /// article of each file played from (not its PAR2, NFO and such). Indexers write NZBs from
    /// the same articles, so another indexer's copy shares them; a repost has new ones.
    nonisolated static func uploadIDs(of nzb: UsenetNZB) -> Set<String> {
        let content = nzb.files.filter { !$0.isSidecar }
        return Set((content.isEmpty ? nzb.files : content).compactMap { $0.segments.first?.messageID })
    }

    // MARK: - Which add-on stream a playback URL came from

    private nonisolated static let historyLock = NSLock()
    private nonisolated(unsafe) static var sourceByPlaybackURL: [String: String] = [:]

    /// The add-on stream URL in one canonical form (nil for non-Usenet URLs).
    nonisolated static func canonicalSource(_ string: String) -> String? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let spec = UsenetStreamSpec(url: url) else { return nil }
        return spec.url.absoluteString
    }

    nonisolated static func remember(source: String, playback: String) {
        guard let canonical = canonicalSource(source) else { return }
        historyLock.lock()
        defer { historyLock.unlock() }
        if sourceByPlaybackURL.count > 64 { sourceByPlaybackURL.removeAll() }
        sourceByPlaybackURL[playback] = canonical
    }

    /// Failover excludes the local playback URLs that failed; each Usenet
    /// start gets a new one, so match them back to the add-on stream.
    /// A Usenet stream is among the ones that failed (its local playback URL, or its source).
    nonisolated static func includesUsenet(_ failedURLs: Set<String>) -> Bool {
        failedURLs.contains { UsenetStreamSpec.isUsenetURL($0) || UsenetStreamServer.isStreamURL(URL(string: $0)) }
    }

    /// The order to try sources in after a Usenet stream failed: the other Usenet streams first,
    /// as ranked, then the rest. Someone playing Usenet wants Usenet again, not whatever ranks
    /// first overall (a torrent, a debrid link).
    nonisolated static func usenetFirst(_ streams: [NuvioStream]) -> [NuvioStream] {
        let usenet = streams.filter { UsenetStreamSpec.isUsenetURL($0.directURL) }
        guard !usenet.isEmpty else { return streams }
        return usenet + streams.filter { !UsenetStreamSpec.isUsenetURL($0.directURL) }
    }

    /// The sources failover tries, in order: unchanged unless a Usenet stream failed; then the
    /// other Usenet streams first, and with Usenet Only (Settings → Usenet) nothing else.
    nonisolated static func failoverCandidates(
        _ ranked: [NuvioStream], failedURLs: Set<String>, mode: UsenetSettings.Failover
    ) -> [NuvioStream] {
        guard includesUsenet(failedURLs) else { return ranked }
        let ordered = usenetFirst(ranked)
        guard mode == .usenetOnly else { return ordered }
        return ordered.filter { UsenetStreamSpec.isUsenetURL($0.directURL) }
    }

    nonisolated static func isExcluded(sourceURL: String, excludedPlaybackURLs: Set<String>) -> Bool {
        guard let canonical = canonicalSource(sourceURL), !excludedPlaybackURLs.isEmpty else { return false }
        if excludedPlaybackURLs.contains(where: { canonicalSource($0) == canonical }) { return true }
        historyLock.lock()
        defer { historyLock.unlock() }
        return excludedPlaybackURLs.contains { sourceByPlaybackURL[$0] == canonical }
    }

    private func startStatsLoop(session: UsenetStreamSession, pool: UsenetConnectionPool, generation: Int) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var lastBytes: Int64 = 0
            var lastTime = Date()
            var rate: Double = 0
            while !Task.isCancelled {
                let sessionStats = await session.stats()
                let poolStats = await pool.stats()
                let now = Date()
                let elapsed = max(0.25, now.timeIntervalSince(lastTime))
                let instant = Double(max(0, sessionStats.downloadedBytes - lastBytes)) / elapsed
                rate = rate == 0 ? instant : rate * 0.6 + instant * 0.4
                lastBytes = sessionStats.downloadedBytes
                lastTime = now
                guard let self, self.generation == generation else { return }
                let lookups = sessionStats.cacheHits + sessionStats.cacheMisses
                var stats = self.activeStats
                stats.downloadRate = rate
                stats.busyConnections = poolStats.busyConnections
                stats.totalConnections = poolStats.totalConnections
                stats.configuredConnections = poolStats.configuredConnections
                stats.fallbackArticles = poolStats.fallbackArticles
                stats.reconnects = poolStats.reconnects
                stats.bufferedAheadBytes = sessionStats.bufferedAheadBytes
                stats.bufferedAheadSeconds = sessionStats.bufferedAheadSeconds
                stats.diskBytes = sessionStats.diskBytes
                stats.diskBudgetBytes = sessionStats.diskBudgetBytes
                stats.diskFreeBytes = sessionStats.diskFreeBytes
                stats.missingArticles = sessionStats.missingArticles
                stats.damagedArticles = sessionStats.damagedArticles
                stats.cacheHitRate = lookups > 0 ? Double(sessionStats.cacheHits) / Double(lookups) : nil
                if stats != self.activeStats { self.activeStats = stats }
                // Twice a second: the seek bar draws the read-ahead from these, and a seek
                // changes it at once.
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// The NZB from the disk cache, else from the indexer (then cached).
    nonisolated static func loadNZB(_ url: URL) async throws -> UsenetNZB {
        if let data = UsenetNZBCache.cached(url) {
            if let nzb = try? UsenetNZB.parse(data) { return nzb }
            UsenetNZBCache.remove(url)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/x-nzb, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Test build: what the indexer sent instead (Usenet Log).
            usenetLog.error("usenet: NZB download failed — \(UsenetNZBDiagnostics.describe(data, response: response, url: url), privacy: .public)")
            throw UsenetError.nzbDownloadFailed(status)
        }
        let nzb: UsenetNZB
        do {
            nzb = try UsenetNZB.parse(data)
        } catch {
            // Test build: what the indexer sent instead (Usenet Log).
            usenetLog.error("usenet: NZB couldn't be read (\(error.localizedDescription, privacy: .public)) — \(UsenetNZBDiagnostics.describe(data, response: response, url: url), privacy: .public)")
            throw error
        }
        UsenetNZBCache.store(data, for: url)
        return nzb
    }
}

/// While on (`UsenetPreparation.$isAhead.withValue(true) { … }`), a Usenet stream picked for
/// playback is only got ready (`UsenetEngineManager.prepare`), not started, and its
/// `nuvio-usenet://` URL comes back: the stream playing now keeps going. The player starts it
/// when the next episode begins.
enum UsenetPreparation {
    @TaskLocal static var isAhead = false
}
