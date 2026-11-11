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
///
/// Every move (up, down, left or right) gets a line too, once its scroll has had time to finish: how many frames
/// came late meanwhile, how many Home rows were built and how many cards were rebuilt (moves in a
/// quick run share one line).
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
    /// The screen before it (where Details was opened from, for the test log).
    nonisolated(unsafe) static var previousScreen = "launch"

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
    private var move: MoveWindow?
    /// Cards rebuilt just before a move's line opened: SwiftUI may redraw as focus moves, before
    /// the focus system tells about the move.
    private var recentCards: [String: Int] = [:]
    private var recentCardsAt: CFTimeInterval = 0

    /// How long after the last move its line waits: past Home's and Details' scrolls.
    static let moveWindow: CFTimeInterval = 0.5
    /// Posted by Home whenever it builds a row (test build), counted for the move lines.
    static let rowBuiltNotification = Notification.Name("nuvio.test.rowBuilt")

    private struct MoveWindow {
        var direction: String
        var moves: Int
        var firstMoveAt: CFTimeInterval
        var lastMoveAt: CFTimeInterval
        var frames = 0
        var droppedFrames = 0
        var longest: CFTimeInterval = 0
        /// When the longest gap ended, after the first move.
        var longestAt: CFTimeInterval = 0
        var rowsBuilt = 0
        var cardsBuilt: [String: Int] = [:]
        var screen: String
    }

    /// How long before a move's line opens a card rebuilt still counts for it.
    static let cardLeadTime: CFTimeInterval = 0.1

    /// One move's numbers (or a quick run of them), for the log line and the tests.
    struct MoveSummary: Equatable {
        var direction: String
        var moves: Int
        var screen: String
        var droppedFrames: Int
        var frames: Int
        var longestMilliseconds: Int
        var rowsBuilt: Int
        var glassCards: Bool
        var experiments: String = ""
        /// When the longest gap ended, in milliseconds after the move: within the scroll's
        /// animation (about 300 ms) or after it. Nil when no frame was late.
        var longestAtMilliseconds: Int? = nil
        /// Cards whose view was rebuilt meanwhile, by kind ("episode", "poster"...).
        var cardsBuilt: [String: Int] = [:]

        var text: String {
            "ui: move \(direction)\(moves > 1 ? " ×\(moves)" : "") on \(screen): "
                + "\(droppedFrames) of \(frames) frames dropped (longest \(longestMilliseconds) ms"
                + (longestAtMilliseconds.map { " at \($0) ms" } ?? "") + "), "
                + "\(rowsBuilt) row\(rowsBuilt == 1 ? "" : "s") built, "
                + cardsText
                + "glass \(glassCards ? "on" : "off")"
                + (experiments.isEmpty ? "" : ", " + experiments)
        }

        /// "20 cards built (12 episode, 8 person), ", most first; empty when none were.
        private var cardsText: String {
            let total = cardsBuilt.values.reduce(0, +)
            guard total > 0 else { return "" }
            let kinds = cardsBuilt
                .filter { $0.value > 0 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.value) \($0.key)" }
                .joined(separator: ", ")
            return "\(total) card\(total == 1 ? "" : "s") built (\(kinds)), "
        }
    }

    /// A card's view was built (its `body` ran): counted for the move lines.
    static func noteCardBuilt(_ kind: String) {
        shared.cardBuilt(kind)
    }

    private func cardBuilt(_ kind: String) {
        if var open = move {
            open.cardsBuilt[kind, default: 0] += 1
            move = open
            return
        }
        let now = CACurrentMediaTime()
        if now - recentCardsAt > Self.cardLeadTime { recentCards = [:] }
        recentCards[kind, default: 0] += 1
        recentCardsAt = now
    }

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
        observers.append(center.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.focusMoves += 1
                if let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext {
                    self?.noteMove(context.focusHeading)
                }
            }
        })
        observers.append(center.addObserver(forName: Self.rowBuiltNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.move?.rowsBuilt += 1 }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
    }

    private func noteMove(_ heading: UIFocusHeading) {
        let direction: String
        if heading.contains(.down) {
            direction = "down"
        } else if heading.contains(.up) {
            direction = "up"
        } else if heading.contains(.right) {
            // Along a row or Details' episode strip: a quick run of them shares one line.
            direction = "right"
        } else if heading.contains(.left) {
            direction = "left"
        } else {
            return
        }
        let now = CACurrentMediaTime()
        if var open = move, open.direction == direction {
            open.moves += 1
            open.lastMoveAt = now
            move = open
        } else {
            flushMove()
            var open = MoveWindow(direction: direction, moves: 1, firstMoveAt: now, lastMoveAt: now, screen: Self.screen)
            if now - recentCardsAt <= Self.cardLeadTime { open.cardsBuilt = recentCards }
            recentCards = [:]
            move = open
        }
    }

    private func flushMove() {
        guard let open = move else { return }
        move = nil
        let summary = MoveSummary(
            direction: open.direction,
            moves: open.moves,
            screen: open.screen,
            droppedFrames: open.droppedFrames,
            frames: open.frames,
            longestMilliseconds: Int(open.longest * 1_000),
            rowsBuilt: open.rowsBuilt,
            glassCards: Self.glassCardsOn,
            experiments: Self.experiments,
            longestAtMilliseconds: open.droppedFrames > 0 ? Int(open.longestAt * 1_000) : nil,
            cardsBuilt: open.cardsBuilt
        )
        TestDiagnosticLog.ui(summary.text)
    }

    private func pause() {
        flushMove()
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
        if var open = move {
            open.frames += 1 + dropped
            open.droppedFrames += dropped
            if gap > open.longest {
                open.longest = gap
                open.longestAt = now - open.firstMoveAt
            }
            move = open
            if now - open.lastMoveAt >= Self.moveWindow { flushMove() }
        }
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
        if let vertical = defaults.string(forKey: "nuvio.tv.test.verticalScrolling"), vertical != "nuvio" { parts.append("vertical \(vertical)") }
        if let opening = defaults.string(forKey: "nuvio.tv.test.detailsOpening"), opening != "nuvio" { parts.append("opening \(opening)") }
        if let cards = defaults.string(forKey: "nuvio.tv.test.cardBuild"), cards != "nuvio" { parts.append("cards \(cards)") }
        if let scope = defaults.string(forKey: "nuvio.tv.test.focusScope"), scope != "screen" { parts.append("focus scope \(scope)") }
        return parts.joined(separator: ", ")
    }

    private static var glassCardsOn: Bool {
        ProfileSettings.current.object(forKey: SettingsKey.liquidGlassCards) as? Bool ?? true
    }
}
