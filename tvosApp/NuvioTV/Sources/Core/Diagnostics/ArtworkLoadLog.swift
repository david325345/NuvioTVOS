import Foundation
import QuartzCore

/// The fork's test build: how artwork got to the screen, a line every 5 s that had any.
///
/// Where the posters and backdrops came from (memory, disk, a download), how long reading,
/// waiting for a decode slot, decoding and downloading took, how big the decoded images are,
/// how long cards showed their placeholder, and how full the memory caches are. Where a card
/// fills in late, or a stall lines up with artwork arriving, this says which step it was.
final class ArtworkLoadLog: @unchecked Sendable {
    static let shared = ArtworkLoadLog()
    static let interval: TimeInterval = 5

    enum Kind: String {
        case poster
        case backdrop
    }

    enum Source {
        /// Already decoded, in the memory cache.
        case memory
        /// Another card was already loading the same image.
        case shared
        case disk
        case network
        case failed
    }

    struct Stat {
        var count = 0
        var total: Double = 0
        var longest: Double = 0

        mutating func add(_ milliseconds: Double) {
            count += 1
            total += milliseconds
            longest = max(longest, milliseconds)
        }

        var average: Int { count == 0 ? 0 : Int((total / Double(count)).rounded()) }
    }

    struct Window {
        var sources: [Source: Int] = [:]
        var diskRead = Stat()
        var decode = Stat()
        var decodeWait = Stat()
        var download = Stat()
        var downloadBytes = 0
        var longestSide = Stat()
        var decodedBytes = 0
        var placeholderWait = Stat()
        var placeholderWaitsOver100 = 0

        var isEmpty: Bool { sources.isEmpty && placeholderWait.count == 0 }
    }

    private let lock = NSLock()
    private var windows: [Kind: Window] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "nuvio.test.artwork-log", qos: .utility)

    static func now() -> CFTimeInterval { CACurrentMediaTime() }

    static func milliseconds(since start: CFTimeInterval) -> Double {
        (CACurrentMediaTime() - start) * 1_000
    }

    func noteSource(_ source: Source, _ kind: Kind) {
        update(kind) { $0.sources[source, default: 0] += 1 }
    }

    func noteDiskRead(milliseconds: Double) {
        update(.poster) { $0.diskRead.add(milliseconds) }
    }

    func noteDownload(_ kind: Kind, milliseconds: Double, bytes: Int) {
        update(kind) {
            $0.download.add(milliseconds)
            $0.downloadBytes += bytes
        }
    }

    /// A decode: how long it waited for one of the decode slots, how long it took, and what
    /// came of it (its longest side in pixels and its decoded size).
    func noteDecode(_ kind: Kind, waitMilliseconds: Double, milliseconds: Double, longestSide: CGFloat?, bytes: Int) {
        update(kind) {
            if waitMilliseconds >= 1 { $0.decodeWait.add(waitMilliseconds) }
            $0.decode.add(milliseconds)
            if let longestSide { $0.longestSide.add(Double(longestSide)) }
            $0.decodedBytes += bytes
        }
    }

    /// A card that had nothing to show (its placeholder was on screen) got its poster.
    func notePlaceholderWait(milliseconds: Double) {
        update(.poster) {
            $0.placeholderWait.add(milliseconds)
            if milliseconds > 100 { $0.placeholderWaitsOver100 += 1 }
        }
    }

    private func update(_ kind: Kind, _ change: (inout Window) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&windows[kind, default: Window()])
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    private func flush() {
        lock.lock()
        let taken = windows
        windows = [:]
        lock.unlock()
        let screen = HitchMeter.screen
        for kind in [Kind.poster, .backdrop] {
            guard let window = taken[kind], !window.isEmpty else { continue }
            let memory = kind == .poster ? PosterArtworkCache.telemetryMetrics() : BackdropImageCache.telemetryMetrics()
            TestDiagnosticLog.ui(Self.line(kind, window, screen: screen, memory: memory))
        }
    }

    /// "art: 48 posters in 5 s on main · home — 31 from memory, 12 from disk (read avg 4 ms),
    /// 3 downloaded (avg 410 ms, longest 920 ms, 1.4 MB) · decoded 15 (avg 22 ms, longest 61 ms;
    /// 9 waited for a slot, longest 140 ms), 520 px, 920 KB each on average · 15 cards showed a
    /// placeholder (avg 120 ms, longest 950 ms, 4 over 100 ms) · in memory 160 images, 92 of 140 MB"
    static func line(
        _ kind: Kind,
        _ window: Window,
        screen: String,
        memory: (count: Int, totalBytes: Int, maxCost: Int)
    ) -> String {
        let total = window.sources.values.reduce(0, +)
        var parts: [String] = []
        if let count = window.sources[.memory] { parts.append("\(count) from memory") }
        if let count = window.sources[.shared] { parts.append("\(count) shared with another card") }
        if let count = window.sources[.disk] {
            parts.append("\(count) from disk" + (window.diskRead.count > 0 ? " (read avg \(window.diskRead.average) ms, longest \(Int(window.diskRead.longest)) ms)" : ""))
        }
        if let count = window.sources[.network] {
            parts.append(
                "\(count) downloaded (avg \(window.download.average) ms, longest \(Int(window.download.longest)) ms, "
                    + "\(megabytes(window.downloadBytes)))"
            )
        }
        if let count = window.sources[.failed] { parts.append("\(count) failed") }
        var line = "art: \(total) \(kind.rawValue)\(total == 1 ? "" : "s") in \(Int(interval)) s on \(screen)"
        if !parts.isEmpty { line += " — " + parts.joined(separator: ", ") }
        if window.decode.count > 0 {
            var decode = "decoded \(window.decode.count) (avg \(window.decode.average) ms, longest \(Int(window.decode.longest)) ms"
            if window.decodeWait.count > 0 {
                decode += "; \(window.decodeWait.count) waited for a slot, longest \(Int(window.decodeWait.longest)) ms"
            }
            decode += ")"
            if window.longestSide.count > 0 {
                decode += ", \(window.longestSide.average) px, \(megabytes(window.decodedBytes / max(1, window.decode.count))) each on average"
            }
            line += " · " + decode
        }
        if window.placeholderWait.count > 0 {
            let waits = window.placeholderWait
            line += " · \(waits.count) card\(waits.count == 1 ? "" : "s") showed a placeholder (avg \(waits.average) ms, "
                + "longest \(Int(waits.longest)) ms, \(window.placeholderWaitsOver100) over 100 ms)"
        }
        line += " · in memory \(memory.count) images, \(memory.totalBytes / 1_048_576) of \(memory.maxCost / 1_048_576) MB"
        return line
    }

    private static func megabytes(_ bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
            : "\(max(1, bytes / 1024)) KB"
    }
}

/// The fork's test build: how often the big screens' views were redrawn (their `body` ran),
/// a line every 5 s that had any. Home redrawn while Details is open, or a tab redrawn on
/// every focus move, is work the main thread didn't need to do.
final class RedrawLog: @unchecked Sendable {
    static let shared = RedrawLog()

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "nuvio.test.redraw-log", qos: .utility)

    /// `view`'s body ran.
    static func note(_ view: String) {
        shared.count(view)
    }

    private func count(_ view: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[view, default: 0] += 1
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + ArtworkLoadLog.interval, repeating: ArtworkLoadLog.interval)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    private func flush() {
        lock.lock()
        let taken = counts
        counts = [:]
        lock.unlock()
        guard !taken.isEmpty else { return }
        TestDiagnosticLog.ui(Self.line(taken, screen: HitchMeter.screen))
    }

    static func line(_ counts: [String: Int], screen: String) -> String {
        let views = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        return "ui: redrawn in \(Int(ArtworkLoadLog.interval)) s on \(screen): \(views)"
    }
}
