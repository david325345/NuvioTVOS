import Foundation

// Remote gestures in the player (fork test build): which gesture does which action, kept in the
// profile, and what the player does with a gesture nobody bound.

/// What a gesture can do during playback.
enum PlayerGestureAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case nextChapter, previousChapter, openChapters, skipIntro
    case forward30, back30, playPause, nextEpisode
    case toggleSubtitles, cycleAudio, faster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextChapter: return "Další kapitola"
        case .previousChapter: return "Předchozí kapitola"
        case .openChapters: return "Otevřít kapitoly"
        case .skipIntro: return "Přeskočit úvod / závěr"
        case .forward30: return "Skok +30 s"
        case .back30: return "Skok −30 s"
        case .playPause: return "Přehrát / pauza"
        case .nextEpisode: return "Další díl"
        case .toggleSubtitles: return "Titulky zap/vyp"
        case .cycleAudio: return "Přepnout zvukovou stopu"
        case .faster: return "Rychlost přehrávání"
        }
    }
}

struct PlayerGestureBinding: Codable, Hashable, Sendable {
    var gesture: RemoteGesture
    var action: PlayerGestureAction
}

/// Which gesture does which action: one gesture per action and one action per gesture.
struct PlayerGestureBindings: Codable, Equatable, Sendable {
    private(set) var bindings: [PlayerGestureBinding]

    init(bindings: [PlayerGestureBinding]) {
        self.bindings = bindings
    }

    /// A long swipe jumps chapters; everything else keeps the player's own meaning.
    static let defaults = PlayerGestureBindings(bindings: [
        PlayerGestureBinding(gesture: .swipe(.right, long: true), action: .nextChapter),
        PlayerGestureBinding(gesture: .swipe(.left, long: true), action: .previousChapter),
    ])

    func action(for gesture: RemoteGesture) -> PlayerGestureAction? {
        bindings.first { $0.gesture == gesture }?.action
    }

    func gesture(for action: PlayerGestureAction) -> RemoteGesture? {
        bindings.first { $0.action == action }?.gesture
    }

    /// Gives `action` this gesture. The action that had it before loses it and is returned.
    @discardableResult
    mutating func bind(_ gesture: RemoteGesture, to action: PlayerGestureAction) -> PlayerGestureAction? {
        let previous = bindings.first { $0.gesture == gesture && $0.action != action }?.action
        bindings.removeAll { $0.action == action || $0.gesture == gesture }
        bindings.append(PlayerGestureBinding(gesture: gesture, action: action))
        return previous
    }

    mutating func unbind(_ action: PlayerGestureAction) {
        bindings.removeAll { $0.action == action }
    }
}

/// The switch and the bindings, per profile.
enum PlayerGestureSettings {
    static let enabledKey = "nuvio.tv.settings.playback.remoteGesturesEnabled"
    static let bindingsKey = "nuvio.tv.settings.playback.remoteGestureBindings"

    /// Off until switched on in the player (Gestures tab).
    static func isEnabled(in settings: UserDefaults = ProfileSettings.current) -> Bool {
        settings.object(forKey: enabledKey) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool, in settings: UserDefaults = ProfileSettings.current) {
        settings.set(enabled, forKey: enabledKey)
    }

    static func bindings(in settings: UserDefaults = ProfileSettings.current) -> PlayerGestureBindings {
        guard let data = settings.data(forKey: bindingsKey),
              let saved = try? JSONDecoder().decode(PlayerGestureBindings.self, from: data) else {
            return .defaults
        }
        return saved
    }

    static func save(_ bindings: PlayerGestureBindings, in settings: UserDefaults = ProfileSettings.current) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        settings.set(data, forKey: bindingsKey)
    }
}

/// What the player does with a gesture nobody bound (while playing with the controls hidden).
enum PlayerBuiltInGesture {
    case seekBack, seekForward
    case holdSeekBack, holdSeekForward
    case select, playPause
    case revealControls, openPanel
    case peek

    static func action(for gesture: RemoteGesture) -> PlayerBuiltInGesture? {
        switch gesture {
        case .click(.select, .single): return .select
        case .click(.playPause, .single): return .playPause
        case .click(.left, .single): return .seekBack
        case .click(.right, .single): return .seekForward
        case .click(.left, .long): return .holdSeekBack
        case .click(.right, .long): return .holdSeekForward
        case .click(.up, .single), .swipe(.up, _): return .revealControls
        case .click(.down, .single), .swipe(.down, _): return .openPanel
        case let .tap(side, double: false):
            switch side {
            case .left, .topLeft, .bottomLeft: return .seekBack
            case .right, .topRight, .bottomRight: return .seekForward
            case .center, .top, .bottom: return .peek
            }
        default: return nil
        }
    }

    /// For the Gestures tab: what binding this gesture takes away.
    var title: String {
        switch self {
        case .seekBack: return "skok zpět"
        case .seekForward: return "skok vpřed"
        case .holdSeekBack: return "přetáčení zpět"
        case .holdSeekForward: return "přetáčení vpřed"
        case .select: return "pauza"
        case .playPause: return "přehrát / pauza"
        case .revealControls: return "ukázat ovládání"
        case .openPanel: return "InSight"
        case .peek: return "krátký přehled"
        }
    }
}
