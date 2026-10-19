import CalendarCore
import SwiftUI

struct LibraryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var results: [TmdbSearchResult] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Přidat film nebo seriál") {
                    TextField("Název", text: $query)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        Label(searching ? "Hledám…" : "Hledat na TMDB", systemImage: "magnifyingglass")
                    }
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let searchError {
                        Text(searchError).foregroundStyle(.red)
                    }
                    ForEach(results, id: \.uniqueKey) { result in
                        let id = "tmdb:\(result.id)"
                        Button {
                            if let kind = result.kind {
                                library.add(LibraryItem(id: id, kind: kind, name: result.displayTitle, posterPath: result.posterPath))
                            }
                        } label: {
                            HStack {
                                Image(systemName: result.kind == .movie ? "film" : "tv")
                                Text(result.displayTitle)
                                if let year = result.year {
                                    Text(year).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let kind = result.kind, library.contains(id, kind: kind) {
                                    Image(systemName: "checkmark")
                                } else {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                    }
                }

                Section("Ve Seznamu (\(library.items.count)) · podržením odebrat") {
                    ForEach(library.items, id: \.self) { item in
                        Button {} label: {
                            HStack {
                                Image(systemName: item.kind == .movie ? "film" : "tv")
                                Text(item.name ?? item.id)
                                Spacer()
                                Text(item.id).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Odebrat", role: .destructive) { library.remove(item) }
                        }
                    }
                    Button("Obnovit výchozí seznam") { library.resetToDefaults() }
                }
            }
            .navigationTitle("Seznam")
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        searchError = nil
        defer { searching = false }
        do {
            results = try await AppSettings.makeClient().search(text)
            if results.isEmpty { searchError = "Nic nenalezeno." }
        } catch TmdbError.missingApiKey {
            searchError = "Nejdřív zadej TMDB klíč v Nastavení."
        } catch TmdbError.unauthorized {
            searchError = "TMDB klíč byl odmítnut."
        } catch {
            searchError = "Hledání selhalo: \(error.localizedDescription)"
        }
    }
}
