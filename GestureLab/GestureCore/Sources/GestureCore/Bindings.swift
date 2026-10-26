import Foundation

/// What a gesture can do on the test timeline.
public enum LabAction: String, Codable, CaseIterable, Sendable {
    case nextChapter, previousChapter, skipIntro
    case forward10, back10, forward30, back30
    case playPause, nextEpisode, toggleSubtitles, cycleAudio, faster

    public var title: String {
        switch self {
        case .nextChapter: return "Další kapitola"
        case .previousChapter: return "Předchozí kapitola"
        case .skipIntro: return "Přeskočit úvod"
        case .forward10: return "Skok +10 s"
        case .back10: return "Skok −10 s"
        case .forward30: return "Skok +30 s"
        case .back30: return "Skok −30 s"
        case .playPause: return "Přehrát / pauza"
        case .nextEpisode: return "Další díl"
        case .toggleSubtitles: return "Titulky zap/vyp"
        case .cycleAudio: return "Přepnout zvuk"
        case .faster: return "Rychlost přehrávání"
        }
    }
}

/// What a drawn digit does.
public enum DigitMode: String, Codable, CaseIterable, Sendable {
    /// 3 → chapter 3.
    case chapter
    /// 3 → 30 % of the video.
    case percent

    public var title: String {
        switch self {
        case .chapter: return "Číslice = kapitola"
        case .percent: return "Číslice = desítky procent"
        }
    }
}

public struct GestureBinding: Codable, Hashable, Sendable {
    public var gesture: Gesture
    public var action: LabAction

    public init(gesture: Gesture, action: LabAction) {
        self.gesture = gesture
        self.action = action
    }
}

/// Which gesture does which action: one gesture per action and one action per
/// gesture. Digits are not bound one by one; `digitMode` says what they do.
public struct GestureBindings: Codable, Equatable, Sendable {
    public private(set) var bindings: [GestureBinding]
    public var digitMode: DigitMode

    public init(bindings: [GestureBinding], digitMode: DigitMode = .chapter) {
        self.bindings = bindings
        self.digitMode = digitMode
    }

    /// Long swipes jump chapters (the first proposal); the usual clicks keep
    /// their player meaning.
    public static let defaults = GestureBindings(bindings: [
        GestureBinding(gesture: .swipe(.right, long: true), action: .nextChapter),
        GestureBinding(gesture: .swipe(.left, long: true), action: .previousChapter),
        GestureBinding(gesture: .click(.right, .single), action: .forward10),
        GestureBinding(gesture: .click(.left, .single), action: .back10),
        GestureBinding(gesture: .click(.playPause, .single), action: .playPause),
    ])

    public func action(for gesture: Gesture) -> LabAction? {
        bindings.first { $0.gesture == gesture }?.action
    }

    public func gesture(for action: LabAction) -> Gesture? {
        bindings.first { $0.action == action }?.gesture
    }

    /// The other action that already uses `gesture`, if any.
    public func conflict(for gesture: Gesture, action: LabAction) -> LabAction? {
        bindings.first { $0.gesture == gesture && $0.action != action }?.action
    }

    /// Gives `action` this gesture. The action that had it before loses it and
    /// is returned. Digits can't be bound (see `digitMode`).
    @discardableResult
    public mutating func bind(_ gesture: Gesture, to action: LabAction) -> LabAction? {
        if case .digit = gesture { return nil }
        let previous = conflict(for: gesture, action: action)
        bindings.removeAll { $0.action == action || $0.gesture == gesture }
        bindings.append(GestureBinding(gesture: gesture, action: action))
        return previous
    }

    public mutating func unbind(_ action: LabAction) {
        bindings.removeAll { $0.action == action }
    }

    /// A single click or tap only has to wait for a second one when its double does something.
    public func waitsForDouble(_ double: Gesture) -> Bool {
        action(for: double) != nil
    }
}
