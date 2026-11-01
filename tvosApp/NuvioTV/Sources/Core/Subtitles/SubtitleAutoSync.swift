import CryptoKit
import Foundation

/// Settings → Playback → Subtitle Auto Sync.
enum SubtitleAutoSyncSettings {
    static let toleranceChoicesMs = [0, 100, 200, 300, 500]
    /// Corrections this small are left alone whatever the tolerance: no one sees 50 ms.
    static let minimumCorrection: Double = 0.05

    static func isEnabled(in settings: UserDefaults) -> Bool {
        settings.object(forKey: SettingsKey.subtitleAutoSync) as? Bool ?? false
    }

    static func toleranceMs(in settings: UserDefaults) -> Int {
        let value = settings.integer(forKey: SettingsKey.subtitleAutoSyncToleranceMs)
        return toleranceChoicesMs.contains(value) ? value : 0
    }
}

/// Why a subtitle keeps its own timing.
enum SubtitleAutoSyncIssue: String, Codable, Sendable {
    case inSync
    case unsupportedSource
    case unsupportedFormat
    case downloadFailed
    case notMatroska
    case noIndex
    case noEmbeddedSubtitles
    case tooFewLines
    case noMatch
    case ambiguous
    case indexFailed

    var message: String {
        switch self {
        case .inSync:
            return L10n.string("subtitle_autosync_in_sync", fallback: "The subtitles already match the video")
        case .unsupportedSource:
            return L10n.string("subtitle_autosync_unsupported_source", fallback: "This source can't be checked (torrent, local file or live)")
        case .unsupportedFormat:
            return L10n.string("subtitle_autosync_unsupported_format", fallback: "This subtitle format can't be synced")
        case .downloadFailed:
            return L10n.string("subtitle_autosync_download_failed", fallback: "The subtitles couldn't be downloaded")
        case .notMatroska:
            return L10n.string("subtitle_autosync_not_mkv", fallback: "Only MKV videos can be checked")
        case .noIndex:
            return L10n.string("subtitle_autosync_no_index", fallback: "The video has no subtitle index to compare with")
        case .noEmbeddedSubtitles:
            return L10n.string("subtitle_autosync_no_embedded", fallback: "The video has no embedded subtitles to compare with")
        case .tooFewLines:
            return L10n.string("subtitle_autosync_too_few_lines", fallback: "Too few lines to compare")
        case .noMatch:
            return L10n.string("subtitle_autosync_no_match", fallback: "These subtitles don't match this video")
        case .ambiguous:
            return L10n.string("subtitle_autosync_ambiguous", fallback: "The match isn't certain, the original timing stays")
        case .indexFailed:
            return L10n.string("subtitle_autosync_index_failed", fallback: "The video's subtitle index couldn't be read")
        }
    }

    /// Worth a cached answer: the same file and subtitle give the same result next time.
    var isLasting: Bool {
        switch self {
        case .inSync, .unsupportedFormat, .notMatroska, .noIndex, .noEmbeddedSubtitles, .tooFewLines, .noMatch, .ambiguous:
            return true
        case .unsupportedSource, .downloadFailed, .indexFailed:
            return false
        }
    }
}

struct SubtitleAutoSyncResult: Codable, Equatable, Sendable {
    var mapping: SubtitleSyncMapping
    var coverage: Double
    /// The embedded track it was lined up with ("ASS eng").
    var reference: String
    var elapsedMs: Int
    var fromCache: Bool = false

    /// "−2.4 s", "+0.8 s ×1.043" (the scale only for a frame rate change).
    var shortLabel: String {
        var label = String(format: "%@%.1f s", mapping.offset < 0 ? "−" : "+", abs(mapping.offset))
        if abs(mapping.scale - 1) > 0.0001 { label += String(format: " ×%.3f", mapping.scale) }
        return label
    }
}

enum SubtitleAutoSyncOutcome: Equatable, Sendable {
    case synced(fileURL: URL, result: SubtitleAutoSyncResult)
    case kept(SubtitleAutoSyncIssue)
}

/// What one run looked at, for the Auto Sync tab of the bottom panel.
struct SubtitleAutoSyncReport: Equatable, Sendable {
    /// Where the index was read ("Usenet (preview connection)", a CDN host).
    var source = ""
    /// The subtitle's format and lines ("ASS · 412 lines, 380 dialogue").
    var subtitle = ""
    /// The video's subtitle index ("4 tracks · 92 kB · 5 requests · 2.3 s"), or why it is missing.
    var index = ""
    /// The embedded tracks in the index ("ASS eng 412", "PGS eng 820").
    var tracks: [String] = []
    /// One line per embedded track tried as the reference.
    var attempts: [String] = []
    /// The answer and how long the run took.
    var result = ""
    var fromCache = false
}

struct SubtitleAutoSyncRun: Equatable, Sendable {
    var outcome: SubtitleAutoSyncOutcome
    var report: SubtitleAutoSyncReport
}

/// Where the playing file's bytes can be read for its subtitle index.
struct SubtitleAutoSyncSource: Hashable, Sendable {
    let url: URL
    let headers: [String: String]
    /// The file's identity across sessions (debrid links change, the file does not).
    let fileKey: String
    /// For the diagnostics.
    let description: String
}

/// Lines add-on subtitles up with the subtitles embedded in the playing file: reads the file's
/// subtitle index while the stream opens, and when a subtitle is chosen, retimes a copy of it
/// that the player loads in its place. Results are kept per file and subtitle.
actor SubtitleAutoSync {
    static let shared = SubtitleAutoSync()

    struct LoadedIndex: Sendable {
        let index: MatroskaSubtitleIndex
        let milliseconds: Int
    }

    private var indexTasks: [String: Task<Result<LoadedIndex, Error>, Never>] = [:]
    private var indexOrder: [String] = []
    private var didPrune = false

    static let cacheLifetime: TimeInterval = 30 * 24 * 3600
    static let maxCachedFiles = 300

    /// The source Auto Sync reads for `playbackURL`, nil for the ones it can't (torrent and other
    /// local sources, live, HLS, disc images). Usenet goes through the server's preview path,
    /// which has an NNTP connection of its own, so playback keeps its connections.
    static func source(
        playbackURL: URL,
        headers: [String: String],
        fileKey: String,
        isLive: Bool
    ) async -> SubtitleAutoSyncSource? {
        let descriptor = PlaybackThumbnailSourceFallback.isCacheProxyURL(playbackURL)
            ? await PlaybackStreamCacheManager.shared.thumbnailSource(for: playbackURL)
            : nil
        guard let origin = SeekPreviewNetworkPolicy.previewOrigin(
            playbackURL: playbackURL,
            headerSourceURL: nil,
            descriptorRemoteURL: descriptor?.remoteURL,
            isLive: isLive,
            isKnownHLS: PlaybackThumbnailSourceFallback.isKnownHLSURL(playbackURL)
        ) else { return nil }
        let description: String
        if UsenetStreamServer.isStreamURL(playbackURL) {
            description = "Usenet (preview connection)"
        } else {
            description = (origin.host ?? origin.absoluteString) + (descriptor == nil ? "" : " (via cache)")
        }
        return SubtitleAutoSyncSource(
            url: origin, headers: descriptor?.originalHeaders ?? headers, fileKey: fileKey, description: description)
    }

    /// Starts reading the index of `source` now, so it is ready when a subtitle is chosen.
    func prefetchIndex(for source: SubtitleAutoSyncSource) {
        _ = indexTask(for: source, force: false)
    }

    private func indexTask(for source: SubtitleAutoSyncSource, force: Bool) -> Task<Result<LoadedIndex, Error>, Never> {
        if !force, let task = indexTasks[source.fileKey] { return task }
        indexTasks[source.fileKey]?.cancel()
        let task = Task<Result<LoadedIndex, Error>, Never>.detached(priority: .utility) {
            let started = Date()
            do {
                let index = try await MatroskaSubtitleIndex.load(
                    from: HTTPRangeByteSource(url: source.url, headers: source.headers))
                return .success(LoadedIndex(index: index, milliseconds: Int(Date().timeIntervalSince(started) * 1000)))
            } catch {
                return .failure(error)
            }
        }
        indexTasks[source.fileKey] = task
        indexOrder.removeAll { $0 == source.fileKey }
        indexOrder.append(source.fileKey)
        while indexOrder.count > 2 {
            let old = indexOrder.removeFirst()
            indexTasks[old]?.cancel()
            indexTasks[old] = nil
        }
        return task
    }

    /// Lines `subtitle` up with the file behind `source`. `force` (the Auto Sync tab's button)
    /// skips the remembered answer and reads the index again when the last read failed.
    func sync(
        subtitle: NuvioSubtitle,
        source: SubtitleAutoSyncSource,
        toleranceMs: Int,
        force: Bool = false
    ) async -> SubtitleAutoSyncRun {
        let started = Date()
        pruneCacheOnce()
        var report = SubtitleAutoSyncReport(source: source.description)
        let key = Self.cacheKey(fileKey: source.fileKey, subtitleURL: subtitle.url)
        let tolerance = max(Double(toleranceMs) / 1000, SubtitleAutoSyncSettings.minimumCorrection)
        if !force, let cached = Self.cachedOutcome(key: key, tolerance: tolerance) {
            report.fromCache = true
            report.result = Self.describe(cached, elapsed: started)
            await Self.reportLine(Self.hudLine(cached, started: started, cached: true))
            return SubtitleAutoSyncRun(outcome: cached, report: report)
        }
        await Self.reportLine("checking…")

        func finish(_ issue: SubtitleAutoSyncIssue, result: SubtitleAutoSyncResult? = nil) async -> SubtitleAutoSyncRun {
            if issue.isLasting {
                Self.store(key: key, entry: CacheEntry(issue: issue, result: result, file: nil, span: nil))
            }
            let outcome = SubtitleAutoSyncOutcome.kept(issue)
            report.result = Self.describe(outcome, elapsed: started)
            await Self.reportLine(Self.hudLine(outcome, started: started, cached: false))
            return SubtitleAutoSyncRun(outcome: outcome, report: report)
        }

        let data: Data
        do {
            data = try await Self.download(subtitle.url)
        } catch {
            report.subtitle = "download failed: \(error.localizedDescription)"
            return await finish(.downloadFailed)
        }
        guard let text = SubtitleTiming.decodeText(data), let format = SubtitleTiming.format(of: text) else {
            report.subtitle = "\(data.count / 1024) kB, format not recognized"
            return await finish(.unsupportedFormat)
        }
        let cues = SubtitleTiming.cues(in: text, format: format)
        let dialogue = cues.filter(\.isDialogue)
        report.subtitle = "\(format.rawValue.uppercased()) · \(cues.count) lines, \(dialogue.count) dialogue"
        guard dialogue.count >= SubtitleSyncAligner.minLines, let first = dialogue.first else {
            return await finish(.tooFewLines)
        }

        let loaded: LoadedIndex
        var task = indexTask(for: source, force: false)
        if force, case .failure = await task.value {
            task = indexTask(for: source, force: true)
        }
        switch await task.value {
        case .success(let value):
            loaded = value
        case .failure(let error):
            report.index = "not read: \(error)"
            return await finish(Self.issue(for: error))
        }
        let index = loaded.index
        report.index = "\(index.tracks.count) subtitle tracks · \(max(1, Int(index.bytes / 1024))) kB · "
            + "\(index.requests) requests · " + String(format: "%.1f s", Double(loaded.milliseconds) / 1000)
        report.tracks = index.tracks.map { "\($0.summary) \($0.events.count)" + ($0.isForced ? " forced" : "") }

        let candidates = SubtitleSyncReference.candidates(in: index, targetLineCount: dialogue.count)
        guard !candidates.isEmpty else { return await finish(.noEmbeddedSubtitles) }

        var match: (fit: SubtitleSyncFit, reference: MatroskaSubtitleTrack)?
        var verdict = SubtitleSyncVerdict.tooFewLines
        for candidate in candidates {
            let alignment = SubtitleSyncAligner.align(target: cues, reference: candidate.cues)
            report.attempts.append(Self.describe(alignment, reference: candidate))
            if alignment.verdict == .confident, let fit = alignment.fit {
                match = (fit, candidate.track)
                break
            }
            verdict = Self.stronger(verdict, alignment.verdict)
        }
        guard let chosen = match else {
            return await finish(verdict == .ambiguous ? .ambiguous : (verdict == .noMatch ? .noMatch : .tooFewLines))
        }

        let span = first.start...max(dialogue.last?.end ?? first.end, first.start + 1)
        let result = SubtitleAutoSyncResult(
            mapping: chosen.fit.mapping, coverage: chosen.fit.coverage,
            reference: chosen.reference.summary, elapsedMs: Int(Date().timeIntervalSince(started) * 1000))
        if chosen.fit.mapping.largestShift(over: span) <= tolerance {
            Self.store(key: key, entry: CacheEntry(issue: .inSync, result: result, file: nil, span: [span.lowerBound, span.upperBound]))
            let outcome = SubtitleAutoSyncOutcome.kept(.inSync)
            report.result = Self.describe(outcome, elapsed: started) + " (\(result.shortLabel))"
            await Self.reportLine(Self.hudLine(outcome, started: started, cached: false) + " (\(result.shortLabel))")
            return SubtitleAutoSyncRun(outcome: outcome, report: report)
        }
        guard let retimed = SubtitleRetimer.retime(text, format: format, mapping: chosen.fit.mapping),
              let fileURL = Self.writeCopy(retimed, key: key, mapping: chosen.fit.mapping, format: format) else {
            return await finish(.unsupportedFormat)
        }
        Self.store(key: key, entry: CacheEntry(
            issue: nil, result: result, file: fileURL.lastPathComponent, span: [span.lowerBound, span.upperBound]))
        let outcome = SubtitleAutoSyncOutcome.synced(fileURL: fileURL, result: result)
        report.result = Self.describe(outcome, elapsed: started)
        await Self.reportLine(Self.hudLine(outcome, started: started, cached: false))
        return SubtitleAutoSyncRun(outcome: outcome, report: report)
    }

    static func stronger(_ current: SubtitleSyncVerdict, _ next: SubtitleSyncVerdict) -> SubtitleSyncVerdict {
        func rank(_ verdict: SubtitleSyncVerdict) -> Int {
            switch verdict {
            case .confident: return 3
            case .ambiguous: return 2
            case .noMatch: return 1
            case .tooFewLines: return 0
            }
        }
        return rank(next) > rank(current) ? next : current
    }

    static func issue(for error: Error) -> SubtitleAutoSyncIssue {
        switch error as? SubtitleIndexError {
        case .notMatroska: return .notMatroska
        case .noIndex, .budgetExceeded: return .noIndex
        case .noSubtitleTracks: return .noEmbeddedSubtitles
        case .rangeUnsupported: return .unsupportedSource
        case nil: return .indexFailed
        }
    }

    static func download(_ string: String) async throws -> Data {
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        if url.isFileURL { return try Data(contentsOf: url) }
        let request = URLRequest(url: url, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Descriptions

    static func describe(_ alignment: SubtitleSyncAlignment, reference: SubtitleSyncReference.Candidate) -> String {
        let name = "\(reference.track.summary) (\(reference.cues.count))"
        guard let fit = alignment.fit else { return "\(name): \(alignment.verdict)" }
        let mark = alignment.verdict == .confident ? "✓" : "✗ \(alignment.verdict)"
        var text = "\(name): \(mark) · \(Int((fit.coverage * 100).rounded())) % · "
            + "starts \(fit.startMatches)/\(fit.lineCount) · gap \(fit.longestMiss) · "
            + String(format: "%+.2f s", fit.mapping.offset)
        if abs(fit.mapping.scale - 1) > 0.0001 { text += String(format: " ×%.4f", fit.mapping.scale) }
        text += String(format: " · median %d ms", Int((fit.medianError * 1000).rounded()))
        return text
    }

    static func describe(_ outcome: SubtitleAutoSyncOutcome, elapsed started: Date) -> String {
        let seconds = String(format: "%.1f s", Date().timeIntervalSince(started))
        switch outcome {
        case .synced(_, let result):
            return "\(result.shortLabel) · \(Int((result.coverage * 100).rounded())) % · \(result.reference) · \(seconds)"
        case .kept(let issue):
            return "\(issue.message) · \(seconds)"
        }
    }

    static func hudLine(_ outcome: SubtitleAutoSyncOutcome, started: Date, cached: Bool) -> String {
        let seconds = String(format: "%.1f s", Date().timeIntervalSince(started))
        switch outcome {
        case .synced(_, let result):
            return "ok \(result.shortLabel) · \(Int((result.coverage * 100).rounded())) % · \(result.reference)"
                + (cached ? " · cached" : " · \(seconds)")
        case .kept(.inSync):
            return "in sync" + (cached ? " · cached" : "")
        case .kept(let issue):
            return "kept: \(issue.rawValue)" + (cached ? " · cached" : " · \(seconds)")
        }
    }

    static func reportLine(_ line: String) async {
        await MainActor.run { SeekPreviewDiagnostics.shared.updateSync(line) }
    }

    // MARK: Cache

    struct CacheEntry: Codable {
        var issue: SubtitleAutoSyncIssue?
        var result: SubtitleAutoSyncResult?
        /// The retimed copy's file name.
        var file: String?
        var span: [Double]?
    }

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SubtitleAutoSync", isDirectory: true)
    }

    static func cacheKey(fileKey: String, subtitleURL: String) -> String {
        hex(SHA256.hash(data: Data("\(fileKey)|\(subtitleURL)".utf8)), bytes: 12)
    }

    private static func hex<D: Sequence>(_ digest: D, bytes: Int) -> String where D.Element == UInt8 {
        digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func cachedOutcome(key: String, tolerance: Double) -> SubtitleAutoSyncOutcome? {
        let metadata = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: metadata),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        if let issue = entry.issue { return .kept(issue) }
        guard var result = entry.result, let name = entry.file else { return nil }
        if let span = entry.span, span.count == 2, span[0] <= span[1],
           result.mapping.largestShift(over: span[0]...span[1]) <= tolerance {
            return .kept(.inSync)
        }
        let file = cacheDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        result.fromCache = true
        return .synced(fileURL: file, result: result)
    }

    static func store(key: String, entry: CacheEntry) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: cacheDirectory.appendingPathComponent("\(key).json"), options: .atomic)
    }

    /// The copy is named after the mapping too: a different answer is a different file, so a
    /// player that already loaded the old copy loads the new one instead of reusing it.
    static func writeCopy(_ text: String, key: String, mapping: SubtitleSyncMapping, format: SubtitleTextFormat) -> URL? {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let signature = hex(SHA256.hash(data: Data(String(format: "%.3f|%.6f", mapping.offset, mapping.scale).utf8)), bytes: 3)
        let file = cacheDirectory.appendingPathComponent("\(key)-\(signature).\(format.fileExtension)")
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    private func pruneCacheOnce() {
        guard !didPrune else { return }
        didPrune = true
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: Self.cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        let cutoff = Date().addingTimeInterval(-Self.cacheLifetime)
        for (index, item) in dated.enumerated() where item.1 < cutoff || index >= Self.maxCachedFiles * 2 {
            try? manager.removeItem(at: item.0)
        }
    }
}

/// Range requests for the subtitle index. A server that ignores Range is left at once: it would
/// send the whole file.
struct HTTPRangeByteSource: SubtitleIndexByteSource {
    let url: URL
    let headers: [String: String]

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func read(offset: Int64, length: Int) async throws -> (data: Data, totalSize: Int64?) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        for (field, value) in headers where field.caseInsensitiveCompare("Range") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            bytes.task.cancel()
            throw SubtitleIndexError.rangeUnsupported
        }
        var data = Data()
        data.reserveCapacity(length)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= length { break }
        }
        bytes.task.cancel()
        return (data, SeekPreviewRangeTransport.totalSize(fromContentRange: http.value(forHTTPHeaderField: "Content-Range")))
    }
}

/// The player's subtitle list with Auto Sync's copies in place of the subtitles they were made
/// from: a loaded copy takes its original's URL (so selection and saved choices keep working on
/// the add-on subtitle), and the original's own track stays out of sight, unless the viewer went
/// back to the original timing, which hides the copy instead.
enum SubtitleAutoSyncTracks {
    static func present(_ tracks: [SubtitleTrack], copies: [String: String], originals: Set<String>) -> [SubtitleTrack] {
        guard !copies.isEmpty else { return tracks }
        let withLoadedCopy = Set(tracks.compactMap { copies[$0.externalFilename] })
        return tracks.compactMap { track in
            var track = track
            if let original = copies[track.externalFilename] {
                guard !originals.contains(original) else { return nil }
                track.externalFilename = original
                return track
            }
            if withLoadedCopy.contains(track.externalFilename), !originals.contains(track.externalFilename) {
                return nil
            }
            return track
        }
    }
}

/// What Auto Sync did with one add-on subtitle in this session.
enum SubtitleAutoSyncState: Equatable {
    case checking
    case synced(SubtitleAutoSyncResult)
    case kept(SubtitleAutoSyncIssue)
}
