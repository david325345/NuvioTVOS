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

    private var isFocusInPanel: Bool {
        if case .entry = focus { return true }
        return false
    }

    /// Library titles for Add shows: the placed ones by "series:123", the
    /// ones the calendar couldn't place by "skipped:…".
    private var libraryItems: [String: CalendarItem] {
        guard case .loaded(let result, _) = model.state else { return [:] }
        var items = result.libraryItems
        for skip in result.skipped { items[CalendarSuggestions.skippedKey(skip)] = skip.item }
        return items
    }

    private var skippedByKey: [String: CalendarSkippedItem] {
        guard case .loaded(let result, _) = model.state else { return [:] }
        return Dictionary(result.skipped.map { (CalendarSuggestions.skippedKey($0), $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// The next day (today or later) each placed title has something on.
    private var nextDates: [String: CalendarDay] {
        guard case .loaded(let result, _) = model.state else { return [:] }
        var dates: [String: CalendarDay] = [:]
        for section in result.days where section.date >= today {
            for entry in section.entries {
                let key = "\(entry.kind.rawValue):\(entry.tmdbId)"
                if dates[key] == nil || section.date < dates[key]! { dates[key] = section.date }
            }
        }
        return dates
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
            CalendarSuggestionsView(
                libraryItems: libraryItems,
                nextDates: nextDates,
                skipped: skippedByKey,
                accent: accent
            ) { changed in
                showingSuggestions = false
                if changed > 0 { model.load() }
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
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                CalendarDayPanel(
                    result: result,
                    month: displayedMonth,
                    selectedDay: selectedDay,
                    today: today,
                    accent: accent,
                    focus: $focus,
                    onOpen: onOpenEntry
                )
                .frame(width: 610)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Use the screen's width: the system's side safe area (and the
            // collapsed sidebar) left a wide empty band on the left.
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 30)
            .ignoresSafeArea(.container, edges: [.leading, .trailing])
            .defaultFocus($focus, .day(today))
            .onAppear(perform: focusTodayOnFirstOpen)
            // Back from the episode list returns to the selected day instead
            // of jumping to the sidebar (which slides the whole grid over).
            // Elsewhere nil keeps the system's own Back.
            .onExitCommand(perform: isFocusInPanel ? { focus = .day(selectedDay) } : nil)
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
        let rows = max(1, cells.count / 7)
        // Minimum height; cells grow to fill the screen's height.
        let cellHeight: CGFloat = rows > 5 ? 110 : 130

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
            // Plain stacks instead of LazyVGrid: zIndex on the focused row and
            // cell is what lets the grown card cover its neighbours, and lazy
            // grids don't honour it.
            VStack(spacing: 10) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<7, id: \.self) { column in
                            let index = row * 7 + column
                            let day = index < cells.count ? cells[index] : nil
                            dayCell(day, result: result, column: column, row: row, rows: rows, height: cellHeight)
                        }
                    }
                    .zIndex(focusedRow(in: cells) == row ? 1 : 0)
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

    @ViewBuilder
    private func dayCell(
        _ day: CalendarDay?, result: CalendarResult, column: Int, row: Int, rows: Int, height: CGFloat
    ) -> some View {
        if let day {
            CalendarDayCell(
                day: day,
                entries: result.entries(on: day),
                isToday: day == today,
                isSelected: day == selectedDay,
                accent: accent,
                height: height,
                growth: CalendarDayCellGrowth(column: column, row: row, rows: rows)
            ) {
                if let first = result.entries(on: day).first {
                    focus = .entry(first.id)
                }
            }
            .frame(maxWidth: .infinity)
            .focused($focus, equals: .day(day))
            // The focused cell grows over its neighbours.
            .zIndex(focus == .day(day) ? 1 : 0)
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(minHeight: height, maxHeight: .infinity)
        }
    }

    private func focusedRow(in cells: [CalendarDay?]) -> Int? {
        guard case .day(let day) = focus, let index = cells.firstIndex(of: day) else { return nil }
        return index / 7
    }
}

enum CalendarFocus: Hashable {
    case previousMonth
    case nextMonth
    case day(CalendarDay)
    case entry(String)
}

// MARK: - Day cell

/// Which way a focused cell grows, so cells at the edges of the grid grow
/// inwards instead of off the grid.
struct CalendarDayCellGrowth: Equatable {
    let column: Int
    let row: Int
    let rows: Int

    var alignment: Alignment {
        let horizontal: HorizontalAlignment = column == 0 ? .leading : (column == 6 ? .trailing : .center)
        let vertical: VerticalAlignment = row == 0 ? .top : (row >= rows - 1 ? .bottom : .center)
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
}

private struct CalendarDayCell: View {
    let day: CalendarDay
    let entries: [CalendarEntry]
    let isToday: Bool
    let isSelected: Bool
    let accent: Color
    let height: CGFloat
    let growth: CalendarDayCellGrowth
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CalendarDayCellBody(
                day: day, entries: entries, isToday: isToday, isSelected: isSelected,
                accent: accent, height: height, growth: growth
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
    }
}

private struct CalendarDayCellBody: View {
    static let focusedScale: CGFloat = 1.7
    /// Posters shown side by side in a cell that isn't expanded.
    static let rowCapacity = 3
    /// How long the cursor has to rest on a day before it opens.
    static let expandDelay: Duration = .seconds(3)

    @Environment(\.isFocused) private var isFocused
    @State private var isExpanded = false
    @State private var expandTask: Task<Void, Never>?
    let day: CalendarDay
    let entries: [CalendarEntry]
    let isToday: Bool
    let isSelected: Bool
    let accent: Color
    let height: CGFloat
    let growth: CalendarDayCellGrowth

    private var posters: [CalendarEntry] {
        // One poster per title per day.
        var seen = Set<String>()
        return entries.filter { seen.insert("\($0.kind.rawValue):\($0.tmdbId)").inserted }
    }

    private var hiddenCount: Int { max(0, posters.count - Self.rowCapacity) }

    var body: some View {
        // The cell keeps its grid slot; the visible card is drawn on top of
        // it and grows past it once expanded.
        GeometryReader { proxy in
            let scale = isExpanded ? Self.focusedScale : 1
            ZStack(alignment: growth.alignment) {
                Color.clear
                card
                    .frame(width: proxy.size.width * scale, height: proxy.size.height * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: growth.alignment)
        }
        .frame(minHeight: height, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .onChange(of: isFocused) { _, focused in
            expandTask?.cancel()
            expandTask = nil
            guard focused else {
                isExpanded = false
                return
            }
            // Only days with hidden titles open, and only when the cursor
            // stays, so moving across the grid doesn't make cells jump.
            guard hiddenCount > 0 else { return }
            expandTask = Task { @MainActor in
                try? await Task.sleep(for: Self.expandDelay)
                // Losing focus cancels this task (onChange above).
                guard !Task.isCancelled else { return }
                isExpanded = true
            }
        }
        .onDisappear {
            expandTask?.cancel()
            isExpanded = false
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(day.day)")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(isToday ? CalendarFormat.textColor(on: accent) : .white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isToday ? accent : Color.clear))
                if isToday {
                    Text(L10n.string("calendar_today", fallback: "Today").uppercased())
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(accent)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isExpanded, entries.count > 0 {
                    Text(CalendarFormat.entryCount(entries.count))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            if isExpanded {
                CalendarPosterMosaic(entries: posters, columns: 4, rows: 3)
                Spacer(minLength: 0)
            } else if !posters.isEmpty {
                CalendarPosterRow(entries: Array(posters.prefix(Self.rowCapacity)), slots: Self.rowCapacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Opaque fills, so a grown card hides the cells under it and posters
        // can't spill out of their own cell.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: isExpanded ? 0.2 : (isToday ? 0.15 : (isSelected ? 0.12 : 0.09))))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(isExpanded ? 0.7 : 0), radius: 24)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isFocused ? Color.white : (isToday ? accent : Color.clear),
                    lineWidth: isFocused ? 4 : 3
                )
        )
    }
}

/// Whole posters (2:3) side by side, sized to fit the space they're given.
private struct CalendarPosterRow: View {
    let entries: [CalendarEntry]
    let slots: Int

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(0..<slots, id: \.self) { index in
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if index < entries.count {
                            let entry = entries[index]
                            CalendarImage(url: entry.posterURL, symbol: entry.kind == .movie ? "film" : "tv")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// Up to `columns × rows` cropped poster tiles; when there are more titles
/// the last tile shows how many are left.
private struct CalendarPosterMosaic: View {
    let entries: [CalendarEntry]
    let columns: Int
    let rows: Int

    var body: some View {
        let layout = CalendarFormat.mosaicLayout(count: entries.count, capacity: columns * rows)
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { column in
                        tile(at: row * columns + column, shown: layout.shown, overflow: layout.overflow)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(at index: Int, shown: Int, overflow: Int) -> some View {
        if index < shown {
            let entry = entries[index]
            CalendarImage(url: entry.posterURL, symbol: entry.kind == .movie ? "film" : "tv")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if overflow > 0, index == shown {
            Text("+\(overflow)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                let time = entry.airTime.map(CalendarFormat.time)
                if CalendarFormat.tag(entry) != nil || time != nil {
                    HStack(spacing: 10) {
                        if let time {
                            Label(time, systemImage: "clock")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        if let tag = CalendarFormat.tag(entry) {
                            Text(tag)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(accent)
                        }
                    }
                }
                Text(entry.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let subtitle = CalendarFormat.subtitle(entry) {
                    Text(subtitle)
                        .font(.system(size: 20))
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
    /// Local broadcast time, e.g. "16:00" or "4:00 PM" depending on the app locale.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocaleManager.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }

    /// How many posters fit and how many are left for the "+N" tile.
    static func mosaicLayout(count: Int, capacity: Int) -> (shown: Int, overflow: Int) {
        guard capacity > 0 else { return (0, count) }
        if count <= capacity { return (count, 0) }
        let shown = capacity - 1
        return (shown, count - shown)
    }

    static func entryCount(_ count: Int) -> String {
        count == 1
            ? L10n.string("calendar_one_entry", fallback: "1 episode")
            : L10n.format("calendar_entries", fallback: "%d episodes", count)
    }

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

    /// "Today", "Tomorrow" or "Next: 21 Oct".
    static func nextDate(_ day: CalendarDay, today: CalendarDay) -> String {
        if day == today { return L10n.string("calendar_today", fallback: "Today") }
        if day == today.adding(days: 1) { return L10n.string("calendar_tomorrow", fallback: "Tomorrow") }
        let formatter = DateFormatter()
        formatter.locale = AppLocaleManager.shared.locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return L10n.format("calendar_suggest_next", fallback: "Next: %@", formatter.string(from: day.noonDate))
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
