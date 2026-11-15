import Foundation
import QuartzCore
import SwiftUI

/// TEST: where focus goes as Details opens (the first six seconds), and Details' moves to its
/// sections, in the test log.
enum TVDetailsOpenTrace {
    nonisolated(unsafe) private static var openedAt: CFTimeInterval = 0

    static func begin(_ id: String) {
        openedAt = CACurrentMediaTime()
        TestDiagnosticLog.ui("details open \(id)")
    }

    /// Logged within the first six seconds after Details opened.
    static func note(_ text: String) {
        let elapsed = CACurrentMediaTime() - openedAt
        guard openedAt > 0, elapsed < 6 else { return }
        TestDiagnosticLog.ui("details open +\(Int(elapsed * 1_000)) ms: \(text)")
    }

    /// Logged any time.
    static func move(_ text: String) {
        TestDiagnosticLog.ui("details: \(text)")
    }
}

/// TEST: logs Details' action focus, focused section and number of sections as they change.
struct TVDetailsOpenTraceModifier: ViewModifier {
    let action: String
    let section: String
    let sections: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: action) { old, new in
                TVDetailsOpenTrace.note("action focus \(old) → \(new)")
            }
            .onChange(of: section) { old, new in
                TVDetailsOpenTrace.note("section \(old) → \(new)")
            }
            .onChange(of: sections) { old, new in
                TVDetailsOpenTrace.note("sections \(old) → \(new)")
            }
    }
}
