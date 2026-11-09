import SwiftUI

/// The settings every poster card reads, read once for the whole app instead of by each card.
///
/// A card used to hold its own `@AppStorage` for each of these, so every card that came on
/// screen while a row scrolled set up a dozen settings observers of its own. ContentView now
/// reads them once (against the active profile's settings) and hands them down; a change in
/// Settings still reaches every card at once.
struct CardAppearance: Equatable {
    var customPosterURLPattern = ""
    var customPosterEnabledScreens = "all"
    var trailersEnabled = true
    var trailerDelay = 7
    var cardCornerRadius = AppCardStyle.defaultCornerRadiusRaw
    var liquidGlassCards = true
    var posterLabels = false
    var smoothFocus = true
    var focusHighlighter = false
    var amoled = false
    var amoledSurfaces = false
    /// Test build experiments (Settings → Advanced → Crash Reports & Test Log), to compare
    /// variants on the Apple TV. Defaults keep Nuvio as it is.
    var rowScrolling = CardExperiment.rowScrollingNuvio
    var focusEffect = CardExperiment.focusEffectNuvio

    var usesSystemRowScrolling: Bool { rowScrolling == CardExperiment.rowScrollingSystem }
    var usesSystemFocusEffect: Bool { focusEffect == CardExperiment.focusEffectSystem }
    var usesLightFocusEffect: Bool { focusEffect == CardExperiment.focusEffectLight }

    /// The values saved in `defaults`, for views outside ContentView's tree.
    static func stored(in defaults: UserDefaults) -> CardAppearance {
        var appearance = CardAppearance()
        if let value = defaults.string(forKey: SettingsKey.customPosterURLPattern) { appearance.customPosterURLPattern = value }
        if let value = defaults.string(forKey: SettingsKey.customPosterEnabledScreens) { appearance.customPosterEnabledScreens = value }
        if let value = defaults.object(forKey: SettingsKey.trailersEnabled) as? Bool { appearance.trailersEnabled = value }
        if let value = defaults.object(forKey: SettingsKey.trailerDelay) as? Int { appearance.trailerDelay = value }
        if let value = defaults.string(forKey: SettingsKey.cardCornerRadius) { appearance.cardCornerRadius = value }
        if let value = defaults.object(forKey: SettingsKey.liquidGlassCards) as? Bool { appearance.liquidGlassCards = value }
        if let value = defaults.object(forKey: SettingsKey.posterLabels) as? Bool { appearance.posterLabels = value }
        if let value = defaults.object(forKey: SettingsKey.smoothFocus) as? Bool { appearance.smoothFocus = value }
        if let value = defaults.object(forKey: SettingsKey.focusHighlighter) as? Bool { appearance.focusHighlighter = value }
        if let value = defaults.object(forKey: SettingsKey.amoled) as? Bool { appearance.amoled = value }
        if let value = defaults.object(forKey: SettingsKey.amoledSurfaces) as? Bool { appearance.amoledSurfaces = value }
        if let value = defaults.string(forKey: CardExperiment.rowScrollingKey) { appearance.rowScrolling = value }
        if let value = defaults.string(forKey: CardExperiment.focusEffectKey) { appearance.focusEffect = value }
        return appearance
    }
}

private struct CardAppearanceKey: EnvironmentKey {
    static var defaultValue: CardAppearance { .stored(in: ProfileSettings.current) }
}

extension EnvironmentValues {
    var cardAppearance: CardAppearance {
        get { self[CardAppearanceKey.self] }
        set { self[CardAppearanceKey.self] = newValue }
    }
}

/// Reads the card settings once and hands them to every card below. Applied inside
/// `.defaultAppStorage`, so the values are the active profile's.
struct CardAppearanceProvider: ViewModifier {
    @AppStorage(SettingsKey.customPosterURLPattern) private var customPosterURLPattern = ""
    @AppStorage(SettingsKey.customPosterEnabledScreens) private var customPosterEnabledScreens = "all"
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadius = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.amoledSurfaces) private var amoledSurfaces = false
    @AppStorage(CardExperiment.rowScrollingKey) private var rowScrolling = CardExperiment.rowScrollingNuvio
    @AppStorage(CardExperiment.focusEffectKey) private var focusEffect = CardExperiment.focusEffectNuvio

    func body(content: Content) -> some View {
        content.environment(
            \.cardAppearance,
            CardAppearance(
                customPosterURLPattern: customPosterURLPattern,
                customPosterEnabledScreens: customPosterEnabledScreens,
                trailersEnabled: trailersEnabled,
                trailerDelay: trailerDelay,
                cardCornerRadius: cardCornerRadius,
                liquidGlassCards: liquidGlassCards,
                posterLabels: posterLabels,
                smoothFocus: smoothFocus,
                focusHighlighter: focusHighlighter,
                amoled: amoled,
                amoledSurfaces: amoledSurfaces,
                rowScrolling: rowScrolling,
                focusEffect: focusEffect
            )
        )
    }
}

/// The fork's test build: variants to compare how smooth Home moves.
enum CardExperiment {
    static let rowScrollingKey = "nuvio.tv.test.rowScrolling"
    static let focusEffectKey = "nuvio.tv.test.focusEffect"

    /// Rows move by Nuvio's own animated offset (focused card kept at the left).
    static let rowScrollingNuvio = "nuvio"
    /// Rows are system scroll views: tvOS scrolls them as focus moves, outside the main thread.
    static let rowScrollingSystem = "system"

    /// Nuvio's focus look: outline, shadow, glass border.
    static let focusEffectNuvio = "nuvio"
    /// The same outline without the shadow and with a plain glass border.
    static let focusEffectLight = "light"
    /// tvOS's own card focus effect (lift and tilt), drawn by the system.
    static let focusEffectSystem = "system"
}
