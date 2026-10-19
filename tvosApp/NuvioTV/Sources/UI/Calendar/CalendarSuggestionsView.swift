import SwiftUI

/// Pick several titles from a TMDB list and add them to the library at once.
struct CalendarSuggestionsView: View {
    let libraryKeys: Set<String>
    let accent: Color
    let onClose: (_ added: Int) -> Void

    @State private var list: CalendarSuggestionList = .animeToday
    @State private var results: [CalendarSuggestionItem] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selected = Set<String>()
    @State private var isAdding = false
    @State private var loadTask: Task<Void, Never>?

    private let columns = Array(repeating: GridItem(.fixed(190), spacing: 28), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.string("calendar_suggest_title", fallback: "Add to library"))
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.white)
            HStack(spacing: 20) {
                ForEach(CalendarSuggestionList.allCases) { option in
                    Button {
                        guard option != list else { return }
                        list = option
                        load()
                    } label: {
                        Text(option.title)
                            .font(.system(size: 22, weight: option == list ? .bold : .regular))
                    }
                }
            }

            content

            HStack(spacing: 24) {
                Button {
                    addSelected()
                } label: {
                    Label(
                        isAdding
                            ? L10n.string("calendar_suggest_adding", fallback: "Adding…")
                            : L10n.format("calendar_suggest_add", fallback: "Add %d to library", selected.count),
                        systemImage: "plus"
                    )
                }
                .disabled(selected.isEmpty || isAdding)

                Button(L10n.string("calendar_suggest_select_all", fallback: "Select all")) {
                    selected = Set(results.filter { $0.isAddable && !libraryKeys.contains($0.key) }.map(\.key))
                }
                .disabled(results.isEmpty || isAdding)

                Spacer()

                Button(L10n.string("action_close", fallback: "Close")) { onClose(0) }
                    .disabled(isAdding)
            }
            .font(.system(size: 24, weight: .semibold))
        }
        .padding(.horizontal, 70)
        .padding(.vertical, 50)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
        .onAppear { load() }
        .onDisappear { loadTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            Text(errorText)
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(results) { result in
                        let itemKey = result.key
                        let inLibrary = libraryKeys.contains(itemKey)
                        Button {
                            if selected.contains(itemKey) {
                                selected.remove(itemKey)
                            } else {
                                selected.insert(itemKey)
                            }
                        } label: {
                            CalendarSuggestionCard(
                                result: result,
                                isSelected: selected.contains(itemKey),
                                inLibrary: inLibrary,
                                accent: accent
                            )
                        }
                        .buttonStyle(PosterCardButtonStyle())
                        .focusEffectDisabledIfAvailable()
                        .disabled(inLibrary || !result.isAddable || isAdding)
                    }
                }
                .padding(20)
            }
            .scrollClipDisabledIfAvailable()
        }
    }

    private func load() {
        loadTask?.cancel()
        selected = []
        errorText = nil
        isLoading = true
        let list = list
        let request = CalendarSuggestions.request(
            for: list, today: CalendarDay(date: Date()), region: CalendarLibrarySource.region
        )
        let client = CalendarLibrarySource.makeClient()
        loadTask = Task {
            do {
                let found: [CalendarSuggestionItem]
                if list == .animeToday && CalendarAnimeToday.isAvailable {
                    // Exact broadcast times from AniList, ids from Simkl.
                    found = try await CalendarAnimeToday.load()
                } else {
                    found = try await client.list(request.path, query: request.query, pages: CalendarSuggestions.pages)
                        .map { CalendarSuggestionItem(tmdb: $0, kind: list.kind) }
                }
                guard !Task.isCancelled else { return }
                results = found
                isLoading = false
                if found.isEmpty {
                    errorText = L10n.string("calendar_suggest_empty", fallback: "TMDB has nothing in this list right now.")
                }
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorText = CalendarService.describe(error)
            }
        }
    }

    private func addSelected() {
        let picked = results.filter { selected.contains($0.key) }
        guard !picked.isEmpty else { return }
        isAdding = true
        let client = CalendarLibrarySource.makeClient()
        Task {
            let added = await CalendarLibraryWriter.add(picked, client: client)
            isAdding = false
            onClose(added)
        }
    }
}

private struct CalendarSuggestionCard: View {
    @Environment(\.isFocused) private var isFocused
    let result: CalendarSuggestionItem
    let isSelected: Bool
    let inLibrary: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: result.posterURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "photo").foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: 190, height: 285)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(inLibrary || !result.isAddable ? 0.45 : 1)

                if isSelected || inLibrary {
                    Image(systemName: inLibrary ? "checkmark.circle" : "checkmark.circle.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(inLibrary ? .white.opacity(0.8) : accent)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isFocused ? Color.white : (isSelected ? accent : Color.clear),
                        lineWidth: isFocused || isSelected ? 4 : 0
                    )
            )
            Text(result.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(width: 190, alignment: .leading)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var subtitle: String {
        if inLibrary { return L10n.string("calendar_suggest_in_library", fallback: "In library") }
        if !result.isAddable { return L10n.string("calendar_suggest_no_ids", fallback: "Not found on Simkl") }
        return result.detail ?? result.year.map(String.init) ?? ""
    }
}
