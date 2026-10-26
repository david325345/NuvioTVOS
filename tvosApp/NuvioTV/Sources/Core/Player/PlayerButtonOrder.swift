import Foundation

/// A button in the player's transport row that the user can show, hide and
/// move. Settings (⋯) is not one of them: it always stays last.
enum PlayerButtonKind: String, CaseIterable, Identifiable {
    case pip
    case chapters
    case episodes
    case sources
    case subtitles
    case audio

    var id: String { rawValue }
}

/// The left-to-right order of the player buttons, stored as
/// "pip,chapters,episodes,…".
enum PlayerButtonOrder {
    static let defaultOrder: [PlayerButtonKind] = PlayerButtonKind.allCases

    /// The stored order. Unknown names and repeats are dropped; a button the
    /// stored order doesn't have (a new one after an update) goes after the
    /// button it follows by default.
    static func parse(_ raw: String) -> [PlayerButtonKind] {
        var result: [PlayerButtonKind] = []
        for part in raw.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            guard let kind = PlayerButtonKind(rawValue: name), !result.contains(kind) else { continue }
            result.append(kind)
        }
        for (position, kind) in defaultOrder.enumerated() where !result.contains(kind) {
            let anchor = defaultOrder[..<position].last { result.contains($0) }
            let index = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(kind, at: index)
        }
        return result
    }

    static func serialize(_ order: [PlayerButtonKind]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    /// `kind` moved by `offset` places (−1 left, +1 right), kept inside the row.
    static func moving(_ kind: PlayerButtonKind, by offset: Int, in order: [PlayerButtonKind]) -> [PlayerButtonKind] {
        guard let index = order.firstIndex(of: kind) else { return order }
        let target = min(max(index + offset, 0), order.count - 1)
        guard target != index else { return order }
        var result = order
        result.remove(at: index)
        result.insert(kind, at: target)
        return result
    }
}
