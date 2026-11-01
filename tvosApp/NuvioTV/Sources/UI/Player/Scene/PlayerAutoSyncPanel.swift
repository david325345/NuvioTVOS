import SwiftUI

/// The AutoSubSync tab of the bottom panel: run AutoSubSync on the playing add-on subtitle by
/// hand, switch between its synced copy and its own timing, and see what the last run looked at:
/// the reference tried, the parts with shifts of their own, and what couldn't be checked.
struct PlayerAutoSyncPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    let focusedControlID: FocusState<String?>.Binding
    let focusContext: ScenePanelWatchPartyFocusContext
    let onDismiss: () -> Void

    static let runID = "autosync.run"
    static let toggleID = "autosync.toggle"

    var body: some View {
        let subtitle = viewModel.activeAddonSubtitle
        let state = subtitle.flatMap { viewModel.subtitleAutoSyncStates[$0.url] }
        let report = subtitle.flatMap { viewModel.subtitleAutoSyncReports[$0.url] }
        let usingOriginal = subtitle.map { viewModel.isSubtitleAutoSyncUsingOriginal($0.url) } ?? false
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 16) {
                Text(subtitleTitle(subtitle))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(statusText(state, usingOriginal: usingOriginal))
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(statusColor(state))
                    .lineLimit(2)
                HStack(spacing: 18) {
                    controlButton(
                        id: Self.runID,
                        title: isChecking(state)
                            ? L10n.string("player_autosync_running", fallback: "Checking…")
                            : L10n.string("player_autosync_run", fallback: "Sync Now"),
                        systemImage: "arrow.triangle.2.circlepath",
                        enabled: subtitle != nil && !isChecking(state)
                    ) {
                        viewModel.runSubtitleAutoSyncNow()
                    }
                    if case .synced? = state {
                        controlButton(
                            id: Self.toggleID,
                            title: usingOriginal
                                ? L10n.string("player_autosync_use_synced", fallback: "Synced Timing")
                                : L10n.string("player_subtitle_autosync_original", fallback: "Original Timing"),
                            systemImage: usingOriginal ? "checkmark.circle" : "arrow.uturn.backward",
                            enabled: true
                        ) {
                            viewModel.toggleSubtitleAutoSyncTiming()
                        }
                    }
                }
                .padding(.top, 6)
            }
            .frame(width: 480, alignment: .leading)

            diagnostics(report, hasSubtitle: subtitle != nil, checked: state != nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 60)
        .padding(.top, 8)
        .onChange(of: focusedControlID.wrappedValue) { _, id in
            focusContext.onFocusChanged(id)
        }
    }

    // MARK: Controls

    private func controlButton(
        id: String,
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedControlID.wrappedValue == id
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? Color.white : Color.white.opacity(0.12))
                )
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused(focusedControlID, equals: id)
        .disabled(!enabled || (focusContext.entryLocked && id != focusContext.entryFocusTarget))
        .focusEffectDisabledIfAvailable()
        .onExitCommand(perform: onDismiss)
        .onMoveCommand { direction in
            if direction == .up { focusContext.onMoveUpFromContent() }
        }
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    // MARK: Text

    private func subtitleTitle(_ subtitle: NuvioSubtitle?) -> String {
        guard let subtitle else {
            return L10n.string("player_autosync_choose", fallback: "Choose add-on subtitles in the subtitle menu")
        }
        let language = SubtitleLanguageDisplay.name(for: subtitle.language)
        return [language, subtitle.label, subtitle.source]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
    }

    private func isChecking(_ state: SubtitleAutoSyncState?) -> Bool {
        if case .checking? = state { return true }
        return false
    }

    private func statusText(_ state: SubtitleAutoSyncState?, usingOriginal: Bool) -> String {
        switch state {
        case nil:
            return L10n.string("player_autosync_not_checked", fallback: "Not checked yet")
        case .checking:
            return L10n.string("player_autosync_running", fallback: "Checking…")
        case .synced(let result):
            let synced = L10n.format("subtitle_autosync_synced_toast", fallback: "Subtitles synced (%@)", result.shortLabel)
            return usingOriginal
                ? synced + " · " + L10n.string("player_subtitle_autosync_original", fallback: "Original Timing")
                : synced
        case .kept(let issue):
            return issue.message
        }
    }

    private func statusColor(_ state: SubtitleAutoSyncState?) -> Color {
        switch state {
        case .synced, .kept(.inSync): return Color(red: 0.42, green: 0.86, blue: 0.52)
        case .kept: return Color(red: 1.0, green: 0.74, blue: 0.36)
        case .checking, nil: return .white.opacity(0.7)
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private func diagnostics(_ report: SubtitleAutoSyncReport?, hasSubtitle: Bool, checked: Bool) -> some View {
        if let report {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    row(L10n.string("player_autosync_source", fallback: "Source"), report.source)
                    row(L10n.string("player_autosync_subtitles", fallback: "Subtitles"), report.subtitle)
                    row(L10n.string("player_autosync_index", fallback: "Index"), report.index)
                    if !report.tracks.isEmpty {
                        row("", report.tracks.joined(separator: ", "), secondary: true)
                    }
                    ForEach(Array(report.attempts.prefix(3).enumerated()), id: \.offset) { index, attempt in
                        row(index == 0 ? L10n.string("player_autosync_reference", fallback: "Reference") : "", attempt)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 8) {
                    row(L10n.string("player_autosync_result", fallback: "Result"),
                        report.result + (report.fromCache ? " · " + L10n.string("player_autosync_cached", fallback: "remembered") : ""))
                    ForEach(Array(report.parts.prefix(3).enumerated()), id: \.offset) { index, line in
                        row(index == 0 ? L10n.string("player_autosync_parts", fallback: "Parts") : "", line)
                    }
                    ForEach(Array(report.warnings.prefix(3).enumerated()), id: \.offset) { index, line in
                        row(index == 0 ? "⚠" : "", line, warning: true)
                    }
                    ForEach(Array(report.notes.prefix(3).enumerated()), id: \.offset) { index, line in
                        row(index == 0 ? L10n.string("player_autosync_notes", fallback: "Notes") : "", line, secondary: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            Text(hasSubtitle && !checked
                 ? L10n.string("player_autosync_hint", fallback: "Sync Now compares the subtitle's timing with the subtitles embedded in the video (MKV) and switches to a synced copy.")
                 : "")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(4)
        }
    }

    private func row(_ label: String, _ value: String, secondary: Bool = false, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(warning ? Color(red: 1.0, green: 0.74, blue: 0.36) : .white.opacity(0.55))
                .frame(width: 104, alignment: .leading)
            Text(value.isEmpty ? "–" : value)
                .font(.system(size: secondary ? 15 : 17, weight: .regular).monospacedDigit())
                .foregroundStyle(warning ? Color(red: 1.0, green: 0.82, blue: 0.55) : .white.opacity(secondary ? 0.55 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
