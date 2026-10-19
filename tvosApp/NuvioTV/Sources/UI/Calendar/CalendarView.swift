import SwiftUI

// MARK: - View model

@MainActor
final class CalendarViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case notConfigured
        case loaded(CalendarResult, loadedAt: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var loadedSignature: String?
    private var loadTask: Task<Void, Never>?

    /// Reloads when the day, profile or TMDB settings changed, or after `maxAge`.
    func loadIfNeeded(maxAge: TimeInterval = 30 * 60) {
        if case .loading = state { return }
        if case .loaded(_, let loadedAt) = state,
           loadedSignature == Self.signature(),
           Date().timeIntervalSince(loadedAt) < maxAge {
            return
        }
        load()
    }

    func load() {
        loadTask?.cancel()
        guard CalendarLibrarySource.isTmdbConfigured else {
            state = .notConfigured
            loadedSignature = nil
            return
        }
        state = .loading
        let signature = Self.signature()
        loadTask = Task { [weak self] in
            guard let metas = await CalendarLibrarySource.libraryMetas() else {
                guard !Task.isCancelled else { return }
                self?.state = .failed(L10n.string(
                    "calendar_error_library",
                    fallback: "Couldn't load your library. Check the library source in Settings and try again."
                ))
                return
            }
            guard !Task.isCancelled else { return }
            let items = metas.map(CalendarLibrarySource.item(for:))
            let period = CalendarBuilder.period(today: CalendarDay(date: Date()))
            let service = CalendarLibrarySource.makeService(metas: metas)
            do {
                let result = try await service.load(items: items, first: period.first, last: period.last)
                guard !Task.isCancelled else { return }
                self?.state = .loaded(result, loadedAt: Date())
                self?.loadedSignature = signature
            } catch CalendarLoadError.tmdbNotConfigured {
                self?.state = .notConfigured
            } catch CalendarLoadError.invalidApiKey {
                self?.state = .failed(L10n.string(
                    "calendar_error_tmdb_key",
                    fallback: "TMDB rejected the API key. Check it in Settings → Integrations → TMDB."
                ))
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    private static func signature() -> String {
        [
            CalendarDay(date: Date()).iso,
            LibraryStore.activeProfileId ?? "",
            TraktSettingsStore.librarySourceMode.rawValue,
            TmdbDetailsService.currentApiKey ?? "",
            TmdbDetailsService.preferredLanguage,
        ].joined(separator: "|")
    }
}

// MARK: - Screen

/// Month grid on the left, the episodes of the focused day on the right
/// (modelled on Stremio's calendar).
struct CalendarView: View {
    let onOpenEntry: (CalendarEntry) -> Void
    let onOpenSettings: () -> Void

    @StateObject private var model = CalendarViewModel()
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue

    private var accent: Color { SettingsAccent.color(for: theme) }

    @State private var displayedMonth = CalendarDay(date: Date()).firstOfMonth
    @State private var selectedDay = CalendarDay(date: Date())
    @State private var showingSkipped = false
    @State private var showingSuggestions = false
    @State private var didFocusToday = false
    @FocusState private var focus: CalendarFocus?

    private var today: CalendarDay { CalendarDay(date: Date()) }

    private var libraryKeys: Set<String> {
        if case .loaded(let result, _) = model.state { return result.libraryKeys }
        return []
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
            content
        }
        .onAppear { model.loadIfNeeded() }
        .sheet(isPresented: $showingSkipped) {
            if case .loaded(let result, _) = model.state {
                CalendarSkippedList(skipped: result.skipped)
            }
        }
        .fullScreenCover(isPresented: $showingSuggestions) {
            CalendarSuggestionsView(libraryKeys: libraryKeys, accent: accent) { added in
                showingSuggestions = false
                if added > 0 { model.load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 24) {
                ProgressView()
                Text(L10n.string("calendar_loading", fallback: "Loading your calendar…"))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .notConfigured:
            CalendarMessage(
                symbol: "calendar.badge.exclamationmark",
                text: L10n.string(
                    "calendar_tmdb_required",
                    fallback: "The calendar uses TMDB. Turn on TMDB and add your API key in Settings → Integrations."
                ),
                actionTitle: L10n.string("nav_settings", fallback: "Settings"),
                action: onOpenSettings
            )

        case .failed(let message):
            CalendarMessage(
                symbol: "exclamationmark.triangle",
                text: message,
                actionTitle: L10n.string("calendar_retry", fallback: "Try again"),
                action: { model.load() }
            )

        case .loaded(let result, let loadedAt):
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 18) {
                    header(result: result, loadedAt: loadedAt)
                    monthGrid(result: result)
                }
                .frame(maxWidth: .infinity)
                CalendarDayPanel(
                    result: result,
                    month: displayedMonth,
                    selectedDay: selectedDay,
                    today: today,
                    accent: accent,
                    focus: $focus,
                    onOpen: onOpenEntry
                )
                .frame(width: 520)
            }
            .padding(.horizontal, 60)
            .padding(.top, 30)
            .defaultFocus($focus, .day(today))
            .onAppear(perform: focusTodayOnFirstOpen)
        }
    }

    /// The first time the calendar shows, start on today's cell.
    private func focusTodayOnFirstOpen() {
        guard !didFocusToday else { return }
        didFocusToday = true
        displayedMonth = today.firstOfMonth
        selectedDay = today
        // After the focus engine's own first pass, as Details does for Play.
        DispatchQueue.main.async { focus = .day(today) }
    }

    // MARK: Header

    private func header(result: CalendarResult, loadedAt: Date) -> some View {
        let canGoBack = displayedMonth.addingMonths(-1) >= result.firstDay.firstOfMonth
        let canGoForward = displayedMonth.addingMonths(1) <= result.lastDay.firstOfMonth
        return HStack(spacing: 24) {
            Button {
                displayedMonth = displayedMonth.addingMonths(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)
            .focused($focus, equals: .previousMonth)

            VStack(alignment: .leading, spacing: 2) {
                Text(CalendarFormat.year(displayedMonth))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Text(CalendarFormat.month(displayedMonth))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(minWidth: 260, alignment: .leading)

            Button {
                displayedMonth = displayedMonth.addingMonths(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)
            .focused($focus, equals: .nextMonth)

            Spacer()

            Button {
                showingSuggestions = true
            } label: {
                Label(
                    L10n.string("calendar_add_shows", fallback: "Add shows"),
                    systemImage: "plus.rectangle.on.rectangle"
                )
            }

            if !result.skipped.isEmpty {
                Button {
                    showingSkipped = true
                } label: {
                    Label(
                        L10n.format("calendar_not_shown", fallback: "%d not shown", result.skipped.count),
                        systemImage: "eye.slash"
                    )
                }
            }

            Button {
                model.load()
            } label: {
                Label(
                    loadedAt.formatted(date: .omitted, time: .shortened),
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .font(.system(size: 24, weight: .semibold))
    }

    // MARK: Grid

    private func monthGrid(result: CalendarResult) -> some View {
        let firstWeekday = Calendar.current.firstWeekday
        let cells = CalendarBuilder.monthGrid(for: displayedMonth, firstWeekday: firstWeekday)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)
        let rows = max(1, cells.count / 7)
        let cellHeight: CGFloat = rows > 5 ? 118 : 140

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(CalendarBuilder.weekdayOrder(firstWeekday: firstWeekday), id: \.self) { weekday in
                    Text(CalendarFormat.weekdayName(weekday))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        CalendarDayCell(
                            day: day,
                            entries: result.entries(on: day),
                            isToday: day == today,
                            isSelected: day == selectedDay,
                            accent: accent,
                            height: cellHeight
                        ) {
                            if let first = result.entries(on: day).first {
                                focus = .entry(first.id)
                            }
                        }
                        .focused($focus, equals: .day(day))
                    } else {
                        Color.clear.frame(height: cellHeight)
                    }
                }
            }
        }
        .onChange(of: focus) { _, newValue in
            if case .day(let day) = newValue {
                selectedDay = day
            }
        }
        .onChange(of: displayedMonth) { _, month in
            selectedDay = month.isSameMonth(as: today) ? today : month
        }
    }
}

enum CalendarFocus: Hashable {
    case previousMonth
    case nextMonth
    case day(CalendarDay)
    case entry(String)
}

// MARK: - Day cell

private struct CalendarDayCell: View {
    let day: CalendarDay
    let entries: [CalendarEntry]
    let isToday: Bool
    let isSelected: Bool
    let accent: Color
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CalendarDayCellBody(
                day: day, entries: entries, isToday: isToday, isSelected: isSelected,
                accent: accent, height: height
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
    }
}

private struct CalendarDayCellBody: View {
    @Environment(\.isFocused) private var isFocused
    let day: CalendarDay
    let entries: [CalendarEntry]
    let isToday: Bool
    let isSelected: Bool
    let accent: Color
    let height: CGFloat

    private var posters: [CalendarEntry] {
        // One poster per title per day.
        var seen = Set<String>()
        return entries.filter { seen.insert("\($0.kind.rawValue):\($0.tmdbId)").inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(day.day)")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(isToday ? CalendarFormat.textColor(on: accent) : .white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isToday ? accent : Color.clear))
                if isToday {
                    Text(L10n.string("calendar_today", fallback: "Today").uppercased())
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(accent)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                ForEach(posters.prefix(2)) { entry in
                    CalendarImage(url: entry.posterURL, symbol: entry.kind == .movie ? "film" : "tv")
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(height: height - 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if posters.count > 2 {
                    Text("+\(posters.count - 2)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isFocused ? 0.2 : (isToday ? 0.14 : (isSelected ? 0.1 : 0.05))))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isFocused ? Color.white : (isToday ? accent : Color.clear),
                    lineWidth: isFocused ? 4 : 3
                )
        )
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Side panel

private struct CalendarDayPanel: View {
    let result: CalendarResult
    let month: CalendarDay
    let selectedDay: CalendarDay
    let today: CalendarDay
    let accent: Color
    var focus: FocusState<CalendarFocus?>.Binding
    let onOpen: (CalendarEntry) -> Void

    private var sections: [CalendarDaySection] {
        result.days.filter { $0.date.isSameMonth(as: month) }
    }

    /// The section to bring into view: the selected day, or the next day
    /// after it that has something.
    private var anchorID: String? {
        (sections.first { $0.date >= selectedDay } ?? sections.last)?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if sections.isEmpty {
                        Text(L10n.string("calendar_month_empty", fallback: "Nothing in your library airs this month."))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 40)
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(CalendarFormat.dayHeader(section.date, today: today))
                                .font(.system(size: 22, weight: section.date == today ? .heavy : .semibold))
                                .foregroundColor(section.date == today ? accent : .white.opacity(section.date == selectedDay ? 1 : 0.7))
                            ForEach(section.entries) { entry in
                                Button { onOpen(entry) } label: {
                                    CalendarEntryCard(entry: entry, accent: accent)
                                }
                                .buttonStyle(PosterCardButtonStyle())
                                .focusEffectDisabledIfAvailable()
                                .focused(focus, equals: .entry(entry.id))
                            }
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(section.date == selectedDay ? 0.1 : 0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(section.date == today ? accent.opacity(0.8) : Color.clear, lineWidth: 2)
                        )
                        .id(section.id)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 12)
            }
            .scrollClipDisabledIfAvailable()
            .onAppear { scroll(proxy) }
            .onChange(of: selectedDay) { _, _ in scroll(proxy) }
            .onChange(of: month) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let anchorID else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }
}

private struct CalendarEntryCard: View {
    @Environment(\.isFocused) private var isFocused
    let entry: CalendarEntry
    let accent: Color

    var body: some View {
        HStack(spacing: 16) {
            CalendarImage(url: entry.stillURL ?? entry.posterURL, symbol: entry.kind == .movie ? "film" : "tv")
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                if let tag = CalendarFormat.tag(entry) {
                    Text(tag)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(accent)
                }
                Text(entry.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let subtitle = CalendarFormat.subtitle(entry) {
                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isFocused ? 0.2 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Small pieces

private struct CalendarImage: View {
    let url: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: symbol).foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }
}

private struct CalendarMessage: View {
    let symbol: String
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: symbol)
                .font(.system(size: 70))
                .foregroundColor(.white.opacity(0.7))
            Text(text)
                .font(.system(size: 28))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Button(actionTitle, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CalendarSkippedList: View {
    let skipped: [CalendarSkippedItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.string("calendar_not_shown_title", fallback: "Not shown in the calendar"))
                    .font(.system(size: 36, weight: .bold))
                ForEach(skipped) { item in
                    Button {} label: {
                        HStack {
                            Text(item.item.name ?? item.item.id)
                            Spacer()
                            Text(CalendarFormat.skipReason(item.reason))
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 22))
                    }
                }
            }
            .padding(60)
        }
    }
}

enum CalendarFormat {
    /// Black on the white accent, white on the coloured ones.
    static func textColor(on accent: Color) -> Color {
        accent == .white ? .black : .white
    }

    private static var locale: Locale { AppLocaleManager.shared.locale }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static func month(_ day: CalendarDay) -> String {
        formatter("LLLL").string(from: day.noonDate).capitalized(with: locale)
    }

    static func year(_ day: CalendarDay) -> String {
        String(day.year)
    }

    static func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.standaloneWeekdaySymbols
        guard (1...symbols.count).contains(weekday) else { return "" }
        return symbols[weekday - 1].capitalized(with: locale)
    }

    static func dayHeader(_ day: CalendarDay, today: CalendarDay) -> String {
        let name = formatter("EEEE MMMM d").string(from: day.noonDate).capitalized(with: locale)
        switch today.days(until: day) {
        case 0: return L10n.string("calendar_today", fallback: "Today") + " · " + name
        case 1: return L10n.string("calendar_tomorrow", fallback: "Tomorrow") + " · " + name
        default: return name
        }
    }

    /// "S2E6", or a release label for movies and premieres.
    static func tag(_ entry: CalendarEntry) -> String? {
        var parts: [String] = []
        if let s = entry.seasonNumber, let e = entry.episodeNumber {
            parts.append("S\(s)E\(e)")
        }
        if let label = releaseLabel(entry.releaseKind) {
            parts.append(label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func subtitle(_ entry: CalendarEntry) -> String? {
        switch entry.kind {
        case .series: return entry.episodeName
        case .movie: return L10n.string("calendar_movie", fallback: "Movie")
        }
    }

    static func releaseLabel(_ kind: CalendarReleaseKind) -> String? {
        switch kind {
        case .episode: return nil
        case .seasonPremiere: return L10n.string("calendar_season_premiere", fallback: "Season premiere")
        case .seriesPremiere: return L10n.string("calendar_series_premiere", fallback: "Series premiere")
        case .seasonFinale: return L10n.string("calendar_season_finale", fallback: "Season finale")
        case .theatrical: return L10n.string("calendar_in_theaters", fallback: "In theaters")
        case .digital: return L10n.string("calendar_digital", fallback: "Digital release")
        case .physical: return L10n.string("calendar_physical", fallback: "Blu-ray / DVD")
        case .release: return L10n.string("calendar_release", fallback: "Release")
        }
    }

    static func skipReason(_ reason: CalendarSkipReason) -> String {
        switch reason {
        case .unsupportedId:
            return L10n.string("calendar_skip_unsupported", fallback: "No TMDB match")
        case .failed(let message):
            return message
        }
    }
}
