import Foundation

/// The player's bottom panel (Down during playback): which tabs it shows and in what order
/// (Settings → Playback → Bottom Panel). Stored as one string, e.g.
/// "chapters,scene,info,-upNext,watchParty", where "-" hides a tab. InSight is shown by its
/// own setting ("Scene (InSight)"), which also runs its recognition, so it is never hidden here.
enum PlayerPanelTabs {
    static let defaultOrder: [SceneTab] = [.chapters, .autoSync, .scene, .info, .upNext, .watchParty]
    /// Tabs added after people saved an order: they join it right after these, not at the end.
    static let addedLater: [SceneTab: SceneTab] = [.autoSync: .chapters]

    struct Config: Equatable {
        var order: [SceneTab]
        var hidden: Set<SceneTab>
    }

    static func decode(_ raw: String?) -> Config {
        var order: [SceneTab] = []
        var hidden = Set<SceneTab>()
        for part in (raw ?? "").split(separator: ",") {
            var token = part.trimmingCharacters(in: .whitespaces)
            let isHidden = token.hasPrefix("-")
            if isHidden { token.removeFirst() }
            guard let tab = tab(forKey: token), !order.contains(tab) else { continue }
            order.append(tab)
            if isHidden, tab != .scene { hidden.insert(tab) }
        }
        for tab in defaultOrder where !order.contains(tab) {
            if let neighbour = addedLater[tab], let index = order.firstIndex(of: neighbour) {
                order.insert(tab, at: index + 1)
            } else {
                order.append(tab)
            }
        }
        return Config(order: order, hidden: hidden)
    }

    static func encode(_ config: Config) -> String {
        config.order
            .map { (config.hidden.contains($0) && $0 != .scene ? "-" : "") + key(for: $0) }
            .joined(separator: ",")
    }

    static func key(for tab: SceneTab) -> String {
        switch tab {
        case .chapters: return "chapters"
        case .autoSync: return "autoSync"
        case .scene: return "scene"
        case .info: return "info"
        case .upNext: return "upNext"
        case .watchParty: return "watchParty"
        }
    }

    static func tab(forKey key: String) -> SceneTab? {
        defaultOrder.first { self.key(for: $0) == key }
    }

    /// The tabs the panel shows, in order: not hidden, and with something to show.
    static func tabs(
        config: Config,
        sceneEnabled: Bool,
        hasChapters: Bool,
        hasNextEpisode: Bool,
        watchPartyAvailable: Bool,
        autoSyncAvailable: Bool = false
    ) -> [SceneTab] {
        config.order.filter { tab in
            switch tab {
            case .scene: return sceneEnabled
            case .chapters: return hasChapters && !config.hidden.contains(tab)
            case .autoSync: return autoSyncAvailable && !config.hidden.contains(tab)
            case .info: return !config.hidden.contains(tab)
            case .upNext: return hasNextEpisode && !config.hidden.contains(tab)
            case .watchParty: return watchPartyAvailable && !config.hidden.contains(tab)
            }
        }
    }

    /// Moves `tab` one place up (`up`) or down in the order.
    static func moving(_ tab: SceneTab, up: Bool, in config: Config) -> Config {
        guard let index = config.order.firstIndex(of: tab) else { return config }
        let target = up ? index - 1 : index + 1
        guard config.order.indices.contains(target) else { return config }
        var moved = config
        moved.order.swapAt(index, target)
        return moved
    }
}
