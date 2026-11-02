import CoreGraphics
import Foundation

/// How the list of sources looks when an episode or a film is opened (Settings → Playback →
/// Stream List): the text size, the size of the cards, how wide the list is, and how much of a
/// stream's name and description shows before it is cut. The defaults are the list as it was.
struct StreamListStyle: Equatable {
    enum CardSize: String, CaseIterable {
        case compact
        case standard = "default"
        case large

        var label: String {
            switch self {
            case .compact: return "Compact"
            case .standard: return "Default"
            case .large: return "Large"
            }
        }
    }

    enum Width: String, CaseIterable {
        case standard = "default"
        case wide
        case full

        var label: String {
            switch self {
            case .standard: return "Default"
            case .wide: return "Wide"
            case .full: return "Full"
            }
        }
    }

    /// Spacing of the cards and around them, in points.
    struct Metrics: Equatable {
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var minHeight: CGFloat
        var cardSpacing: CGFloat
        var lineSpacing: CGFloat
        var panelPadding: CGFloat
        var logoSize: CGFloat
    }

    /// Where the summary (logo, episode) and the list go on the screen.
    struct Layout: Equatable {
        var summaryWidth: CGFloat
        var panelWidth: CGFloat
        var panelHeight: CGFloat
        /// The filters, the episode line when shown, and the list.
        var stackHeight: CGFloat
        var stackSpacing: CGFloat
        var showsSummary: Bool
        var showsHeader: Bool
    }

    static let textScales = [60, 70, 80, 90, 100, 115, 130]
    static let nameLineChoices = [2, 0]
    static let descriptionLineChoices = [3, 6, 10, 0]
    static let filterRowHeight: CGFloat = 90
    static let headerHeight: CGFloat = 112

    /// Text size in percent of the default.
    var textScale: Int = 100
    var cardSize: CardSize = .standard
    var width: Width = .standard
    /// Lines of the name and of the description before they are cut; nil shows all.
    var nameLines: Int? = 2
    var descriptionLines: Int? = 6
    /// With the full width, the logo and the episode go above the list.
    var episodeHeader = true
    /// The focused card shows its whole name and description.
    var expandFocused = false

    init() {}

    init(
        textScale: Int,
        cardSize: String,
        width: String,
        nameLines: Int,
        descriptionLines: Int,
        episodeHeader: Bool,
        expandFocused: Bool
    ) {
        self.textScale = Self.textScales.contains(textScale) ? textScale : 100
        self.cardSize = CardSize(rawValue: cardSize) ?? .standard
        self.width = Width(rawValue: width) ?? .standard
        self.nameLines = nameLines > 0 ? nameLines : nil
        self.descriptionLines = descriptionLines > 0 ? descriptionLines : nil
        self.episodeHeader = episodeHeader
        self.expandFocused = expandFocused
    }

    static func current(in settings: UserDefaults = ProfileSettings.current) -> StreamListStyle {
        func int(_ key: String, _ fallback: Int) -> Int {
            settings.object(forKey: key) == nil ? fallback : settings.integer(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            settings.object(forKey: key) == nil ? fallback : settings.bool(forKey: key)
        }
        return StreamListStyle(
            textScale: int(SettingsKey.streamListTextScale, 100),
            cardSize: settings.string(forKey: SettingsKey.streamListCardSize) ?? CardSize.standard.rawValue,
            width: settings.string(forKey: SettingsKey.streamListWidth) ?? Width.standard.rawValue,
            nameLines: int(SettingsKey.streamListNameLines, 2),
            descriptionLines: int(SettingsKey.streamListDescriptionLines, 6),
            episodeHeader: bool(SettingsKey.streamListEpisodeHeader, true),
            expandFocused: bool(SettingsKey.streamListExpandFocused, false))
    }

    /// A text size of the list at this style's scale.
    func font(_ size: CGFloat) -> CGFloat {
        (size * CGFloat(textScale) / 100).rounded()
    }

    var metrics: Metrics {
        switch cardSize {
        case .compact:
            return Metrics(horizontalPadding: 24, verticalPadding: 18, minHeight: 0,
                           cardSpacing: 14, lineSpacing: 8, panelPadding: 28, logoSize: 72)
        case .standard:
            return Metrics(horizontalPadding: 36, verticalPadding: 34, minHeight: 250,
                           cardSpacing: 28, lineSpacing: 14, panelPadding: 40, logoSize: 96)
        case .large:
            return Metrics(horizontalPadding: 44, verticalPadding: 40, minHeight: 290,
                           cardSpacing: 32, lineSpacing: 16, panelPadding: 44, logoSize: 96)
        }
    }

    /// The summary on the left and the list on the right of a `width` × `height` screen. The
    /// default is the list as it was; wide narrows the summary; full leaves it out, and the
    /// episode then goes above the list when `episodeHeader` is on.
    func layout(width canvasWidth: CGFloat, height canvasHeight: CGFloat) -> Layout {
        let standardSummary = min(canvasWidth * 0.34, 620)
        let standardPanelHeight = min(max(canvasHeight - 300, 440), 720)
        switch width {
        case .standard:
            let panelWidth = min(canvasWidth * 0.56, 1_080)
            return Layout(
                summaryWidth: standardSummary, panelWidth: panelWidth,
                panelHeight: standardPanelHeight,
                stackHeight: standardPanelHeight + Self.filterRowHeight + 28, stackSpacing: 28,
                showsSummary: true, showsHeader: false)
        case .wide:
            let panelWidth = min(canvasWidth * 0.70, 1_344)
            // The rest, less the margins (96 left, 64 right) and a gap of 40.
            let summaryWidth = max(min(standardSummary, canvasWidth - panelWidth - 200), 0)
            return Layout(
                summaryWidth: summaryWidth, panelWidth: panelWidth,
                panelHeight: standardPanelHeight,
                stackHeight: standardPanelHeight + Self.filterRowHeight + 28, stackSpacing: 28,
                showsSummary: summaryWidth >= 240, showsHeader: false)
        case .full:
            let panelWidth = max(canvasWidth - 128, 0)
            guard episodeHeader else {
                return Layout(
                    summaryWidth: 0, panelWidth: panelWidth,
                    panelHeight: standardPanelHeight,
                    stackHeight: standardPanelHeight + Self.filterRowHeight + 28, stackSpacing: 28,
                    showsSummary: false, showsHeader: false)
            }
            let spacing: CGFloat = 20
            let room = canvasHeight - 88 - Self.filterRowHeight - Self.headerHeight - 2 * spacing
            let panelHeight = min(max(room, 360), 760)
            return Layout(
                summaryWidth: 0, panelWidth: panelWidth, panelHeight: panelHeight,
                stackHeight: Self.filterRowHeight + Self.headerHeight + panelHeight + 2 * spacing,
                stackSpacing: spacing,
                showsSummary: false, showsHeader: true)
        }
    }

    // MARK: Settings rows

    static func textScaleLabel(_ percent: Int) -> String { "\(percent) %" }

    static func textScale(fromLabel label: String) -> Int {
        Int(label.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 100
    }

    static func linesLabel(_ lines: Int) -> String { lines > 0 ? "\(lines)" : "All" }

    static func lines(fromLabel label: String) -> Int { Int(label) ?? 0 }
}
