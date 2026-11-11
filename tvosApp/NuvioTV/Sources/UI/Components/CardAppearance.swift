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
    var verticalScrolling = CardExperiment.verticalScrollingNuvio
    var detailsOpening = CardExperiment.detailsOpeningNuvio
    var cardBuild = CardExperiment.cardBuildNuvio
    var focusScope = CardExperiment.focusScopeScreen

    var usesSystemRowScrolling: Bool { rowScrolling == CardExperiment.rowScrollingSystem }
    var usesSystemFocusEffect: Bool { focusEffect == CardExperiment.focusEffectSystem }
    var usesLightFocusEffect: Bool { focusEffect == CardExperiment.focusEffectLight }
    /// Smooth, and Sections (which is Smooth too).
    var usesSmoothVerticalScrolling: Bool {
        verticalScrolling == CardExperiment.verticalScrollingSmooth
            || verticalScrolling == CardExperiment.verticalScrollingSections
    }
    var usesSectionSnapping: Bool { verticalScrolling == CardExperiment.verticalScrollingSections }
    var usesSteadyDetailsOpening: Bool { detailsOpening == CardExperiment.detailsOpeningSteady }
    var usesLightCards: Bool { cardBuild == CardExperiment.cardBuildLight }
    var usesRowFocusScope: Bool { focusScope == CardExperiment.focusScopeRows }

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
        if let value = defaults.string(forKey: CardExperiment.verticalScrollingKey) { appearance.verticalScrolling = value }
        if let value = defaults.string(forKey: CardExperiment.detailsOpeningKey) { appearance.detailsOpening = value }
        if let value = defaults.string(forKey: CardExperiment.cardBuildKey) { appearance.cardBuild = value }
        if let value = defaults.string(forKey: CardExperiment.focusScopeKey) { appearance.focusScope = value }
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
    @AppStorage(CardExperiment.verticalScrollingKey) private var verticalScrolling = CardExperiment.verticalScrollingNuvio
    @AppStorage(CardExperiment.detailsOpeningKey) private var detailsOpening = CardExperiment.detailsOpeningNuvio
    @AppStorage(CardExperiment.cardBuildKey) private var cardBuild = CardExperiment.cardBuildNuvio
    @AppStorage(CardExperiment.focusScopeKey) private var focusScope = CardExperiment.focusScopeScreen

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
                focusEffect: focusEffect,
                verticalScrolling: verticalScrolling,
                detailsOpening: detailsOpening,
                cardBuild: cardBuild,
                focusScope: focusScope
            )
        )
    }
}

/// The fork's test build: variants to compare how smooth Home moves.
enum CardExperiment {
    static let rowScrollingKey = "nuvio.tv.test.rowScrolling"
    static let focusEffectKey = "nuvio.tv.test.focusEffect"
    static let verticalScrollingKey = "nuvio.tv.test.verticalScrolling"
    static let detailsOpeningKey = "nuvio.tv.test.detailsOpening"
    static let cardBuildKey = "nuvio.tv.test.cardBuild"
    static let focusScopeKey = "nuvio.tv.test.focusScope"

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

    /// Up and down as Nuvio does it.
    static let verticalScrollingNuvio = "nuvio"
    /// Home keeps one more row ready on each side and builds the farthest only once a move has
    /// finished; Details fades in a backdrop blurred once instead of animating the blur.
    static let verticalScrollingSmooth = "smooth"
    /// Smooth, and Details' up and down left to its scroll view: tvOS scrolls to what focus goes
    /// to and the scroll settles on section tops, instead of Details scrolling there itself with
    /// its own animation.
    static let verticalScrollingSections = "sections"

    /// Details fades in over Home as a whole: for a moment both screens show through each other.
    static let detailsOpeningNuvio = "nuvio"
    /// Details' backdrop (the same title art Home shows) is there at once and only its content
    /// fades in, so nothing shows twice and the screen doesn't wash out.
    static let detailsOpeningSteady = "steady"

    /// Poster cards as Nuvio builds them.
    static let cardBuildNuvio = "nuvio"
    /// The same cards, cheaper to build: the watched mark shares one set of observers with every
    /// other card instead of eight of its own and is only drawn for watched titles, the card's
    /// overlays are one layer, its focus-only work starts once it is focused, its border is drawn
    /// without the glass modifier's timer, and Continue Watching's texts are worked out once a
    /// minute instead of each time the row is built.
    static let cardBuildLight = "light"

    /// Focus held by the whole screen: Home (and Details for its episodes) knows which card is
    /// focused, so every move from card to card redraws all of it.
    static let focusScopeScreen = "screen"
    /// Focus held by each row (and Details' episode strip): a move redraws only the row it happens
    /// in; Home hears of it, and puts focus back, through the row.
    static let focusScopeRows = "rows"
}
