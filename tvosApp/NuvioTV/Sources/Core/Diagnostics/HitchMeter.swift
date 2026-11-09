import UIKit
import QuartzCore

/// The fork's test build: how smooth the interface is, in the test log.
///
/// Counts every frame the main thread didn't draw on time (one frame late included), and the
/// hitches among them (a frame more than two frames late), and writes a line for every five
/// seconds that dropped any, with the screen, how many focus moves happened and whether glass
/// cards are on. A frame held up for a
/// quarter of a second or more gets a line of its own at once. Frames the GPU drops while the
/// main thread is idle don't show up here.
@MainActor
final class HitchMeter: NSObject {
    static let shared = HitchMeter()

    /// A frame this late (or later, at least two frame times) is a hitch.
    static let hitchThreshold: CFTimeInterval = 0.034
    /// A frame this late is a stall, logged on its own line.
    static let stallThreshold: CFTimeInterval = 0.25
    static let summaryInterval: CFTimeInterval = 5

    /// The screen on view, kept current by `CrashRecorder.noteScreen`.
    nonisolated(unsafe) static var screen = "launch"

    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var lastTimestamp: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var hitches = 0
    private var droppedFrames = 0
    private var frames = 0
    private var lostTime: CFTimeInterval = 0
    private var longest: CFTimeInterval = 0
    private var focusMoves = 0

    /// One window's numbers, for the log line (and the tests).
    struct Summary: Equatable {
        var seconds: Int
        var hitches: Int
        var lostMilliseconds: Int
        var longestMilliseconds: Int
        var focusMoves: Int
        var screen: String
        var glassCards: Bool
        /// Every frame that didn't come on time, one late frame included.
        var droppedFrames: Int = 0
        var frames: Int = 0
        /// The smoothness experiments in use ("rows system, focus light"), empty when none.
        var experiments: String = ""

        var text: String {
            "ui: \(droppedFrames) of \(frames) frames dropped in \(seconds) s, "
                + "\(hitches) hitch\(hitches == 1 ? "" : "es") (longest \(longestMilliseconds) ms, \(lostMilliseconds) ms lost), "
                + "\(focusMoves) focus move\(focusMoves == 1 ? "" : "s"), "
                + "\(screen), glass \(glassCards ? "on" : "off")"
                + (experiments.isEmpty ? "" : ", " + experiments)
        }
    }

    /// Frames that should have come between two that came `gap` apart.
    nonisolated static func droppedFrames(gap: CFTimeInterval, frameDuration: CFTimeInterval) -> Int {
        guard frameDuration > 0 else { return 0 }
        return max(0, Int((gap / frameDuration).rounded()) - 1)
    }

    /// Whether a frame that came `gap` after the one before it, where one frame lasts
    /// `frameDuration`, was a hitch.
    nonisolated static func isHitch(gap: CFTimeInterval, frameDuration: CFTimeInterval) -> Bool {
        gap > max(hitchThreshold, frameDuration * 2)
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusMoves += 1 }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
    }

    private func pause() {
        if lastTimestamp > 0 { flush(at: lastTimestamp) }
        link?.isPaused = true
        lastTimestamp = 0
    }

    private func resume() {
        lastTimestamp = 0
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else {
            windowStart = now
            return
        }
        let frameDuration = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
        let gap = now - lastTimestamp
        let dropped = Self.droppedFrames(gap: gap, frameDuration: frameDuration)
        droppedFrames += dropped
        frames += 1 + dropped
        if Self.isHitch(gap: gap, frameDuration: frameDuration) {
            hitches += 1
            lostTime += gap - frameDuration
            longest = max(longest, gap)
            if gap >= Self.stallThreshold {
                TestDiagnosticLog.ui("ui: stall \(Int(gap * 1_000)) ms on \(Self.screen)")
            }
        }
        if now - windowStart >= Self.summaryInterval { flush(at: now) }
    }

    private func flush(at now: CFTimeInterval) {
        if droppedFrames > 0 {
            let summary = Summary(
                seconds: max(1, Int((now - windowStart).rounded())),
                hitches: hitches,
                lostMilliseconds: Int(lostTime * 1_000),
                longestMilliseconds: Int(longest * 1_000),
                focusMoves: focusMoves,
                screen: Self.screen,
                glassCards: Self.glassCardsOn,
                droppedFrames: droppedFrames,
                frames: frames,
                experiments: Self.experiments
            )
            TestDiagnosticLog.ui(summary.text)
        }
        droppedFrames = 0
        frames = 0
        hitches = 0
        lostTime = 0
        longest = 0
        focusMoves = 0
        windowStart = now
    }

    /// "rows system, focus light" for the experiments that aren't Nuvio's default.
    private static var experiments: String {
        let defaults = ProfileSettings.current
        var parts: [String] = []
        if let rows = defaults.string(forKey: "nuvio.tv.test.rowScrolling"), rows != "nuvio" { parts.append("rows \(rows)") }
        if let focus = defaults.string(forKey: "nuvio.tv.test.focusEffect"), focus != "nuvio" { parts.append("focus \(focus)") }
        return parts.joined(separator: ", ")
    }

    private static var glassCardsOn: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.liquidGlassCards) as? Bool ?? true
    }
}
