import UIKit
import QuartzCore

/// The fork's test build: how smooth the interface is, in the test log.
///
/// Counts frames the main thread was too busy to draw on time (a hitch: one frame came more
/// than two frames late) and writes a line for every five seconds that had any, with the
/// screen, how many focus moves happened and whether glass cards are on. A frame held up for a
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

        var text: String {
            "ui: \(hitches) hitch\(hitches == 1 ? "" : "es") in \(seconds) s, longest \(longestMilliseconds) ms, "
                + "\(lostMilliseconds) ms lost, \(focusMoves) focus move\(focusMoves == 1 ? "" : "s"), "
                + "\(screen), glass \(glassCards ? "on" : "off")"
        }
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
        if hitches > 0 {
            let summary = Summary(
                seconds: max(1, Int((now - windowStart).rounded())),
                hitches: hitches,
                lostMilliseconds: Int(lostTime * 1_000),
                longestMilliseconds: Int(longest * 1_000),
                focusMoves: focusMoves,
                screen: Self.screen,
                glassCards: Self.glassCardsOn
            )
            TestDiagnosticLog.ui(summary.text)
        }
        hitches = 0
        lostTime = 0
        longest = 0
        focusMoves = 0
        windowStart = now
    }

    private static var glassCardsOn: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.liquidGlassCards) as? Bool ?? true
    }
}
