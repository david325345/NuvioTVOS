import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// The fork's test build: what Details does after focus moves to another of its sections (the
/// first move down from Play stutters). One test log line about 1.5 s after the move:
///
///     ui: details: focus actions → episodes — +0 scrolled down, +3 build below asked,
///         +41 sections 2 → 3 · bodies: content ×3, episodes ×2, backdrop ×2, episodeCard ×14
///
/// Times are milliseconds after the move, bodies the views of Details worked out again in
/// that time. Main thread only.
enum TVDetailsMoveTrace {
    private static let window: CFTimeInterval = 1.5
    private static var start: CFTimeInterval = 0
    private static var label = ""
    private static var events: [String] = []
    private static var bodies: [String: Int] = [:]
    private static var generation = 0

    private static var isOpen: Bool {
        start > 0 && CACurrentMediaTime() - start < window
    }

    /// Focus moved to another section: a new line starts.
    static func begin(_ what: String) {
        flush()
        start = CACurrentMediaTime()
        label = what
        events = []
        bodies = [:]
        generation &+= 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + window) {
            guard generation == current else { return }
            flush()
        }
    }

    static func note(_ event: String) {
        guard isOpen else { return }
        let ms = Int((CACurrentMediaTime() - start) * 1000)
        events.append("+\(ms) \(event)")
    }

    static func body(_ name: String) {
        guard isOpen else { return }
        bodies[name, default: 0] += 1
    }

    private static func flush() {
        guard start > 0 else { return }
        start = 0
        let bodyText = bodies.sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
        TestDiagnosticLog.ui(
            "details: \(label) — \(events.isEmpty ? "nothing else" : events.joined(separator: ", "))"
                + (bodyText.isEmpty ? "" : " · bodies: \(bodyText)")
        )
    }
}

/// TEST: how Details goes from section to section: tvOS's scroll for focus (Nuvio), that
/// scroll stopped as it starts and a Core Animation move to the section's top in its place (CA),
/// or Details' scroll view not scrolling for focus at all and every move by Core Animation
/// (CA full). tvOS's scroll moves Details frame by frame on the main thread, so a move that
/// costs some work there (the first move down from Play) stutters.
enum TVDetailsMoveTest {
    static let key = "nuvio.tv.test.detailsMove"
    static let nuvio = "nuvio"
    static let ca = "ca"
    static let caFull = "caFull"

    static func isCA(_ value: String) -> Bool {
        value == ca || value == caFull
    }

    static func label(_ value: String) -> String {
        switch value {
        case ca: return "CA"
        case caFull: return "CA full"
        default: return "Nuvio"
        }
    }

    static func next(after value: String) -> String {
        switch value {
        case nuvio: return ca
        case ca: return caFull
        default: return nuvio
        }
    }
}

/// TEST (Details Move CA): Details' UIKit scroll view and where each of its sections starts in
/// its content.
final class TVDetailsSectionTops {
    let scrollBox = TVScrollViewBox()
    private(set) var tops: [String: CGFloat] = [:]

    /// `visibleMinY`: the section's top in the scroll view's own space (where the content is
    /// on screen); with the scroll's offset, where it is in the content.
    func record(_ key: String, visibleMinY: CGFloat) {
        tops[key] = visibleMinY + (scrollBox.scrollView?.contentOffset.y ?? 0)
    }
}

struct TVDetailsSectionTopReader: ViewModifier {
    let key: String
    let box: TVDetailsSectionTops
    let space: String

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(space)).minY
        } action: { minY in
            box.record(key, visibleMinY: minY)
        }
    }
}
