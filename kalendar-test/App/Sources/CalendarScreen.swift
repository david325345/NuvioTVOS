import CalendarCore
import SwiftUI

@MainActor
final class CalendarViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(CalendarResult, loadedAt: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var loadedSignature: String?

    /// Reloads when the library or settings changed, or after `maxAge`.
    func loadIfNeeded(items: [CalendarItem], maxAge: TimeInterval = 6 * 3600) async {
        let signature = Self.signature(items)
        if case .loaded(_, let loadedAt) = state,
           signature == loadedSignature,
           Date().timeIntervalSince(loadedAt) < maxAge {
            return
        }
        await load(items: items)
    }

    func load(items: [CalendarItem]) async {
        if case .loading = state { return }
        state = .loading
        let client = AppSettings.makeClient()
        let service = CalendarService(
            client: client,
            resolver: IdResolver(client: client, store: UserDefaultsIdCache()),
            horizonDays: AppSettings.horizonDays,
            maxConcurrent: 4,
            region: AppSettings.region
        )
        do {
            let result = try await service.load(items: items, today: DayKey(date: Date()))
            state = .loaded(result, loadedAt: Date())
            loadedSignature = Self.signature(items)
        } catch CalendarLoadError.missingApiKey {
            state = .failed("Chybí TMDB API klíč. Zadej ho v Nastavení.")
        } catch CalendarLoadError.invalidApiKey {
            state = .failed("TMDB klíč byl odmítnut. Zkontroluj ho v Nastavení.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func signature(_ items: [CalendarItem]) -> String {
        let ids = items.map { "\($0.kind.rawValue):\($0.id)" }.sorted().joined(separator: ",")
        return [ids, DayKey(date: Date()).iso, AppSettings.tmdbApiKey, AppSettings.language, AppSettings.region, String(AppSettings.horizonDays)]
            .joined(separator: "|")
    }
}

struct CalendarScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = CalendarViewModel()
    @State private var selected: CalendarEntry?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Kalendář")
        }
        .onAppear { Task { await model.loadIfNeeded(items: library.items) } }
        .sheet(item: $selected) { entry in
            EntryDetailView(entry: entry)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 24) {
                ProgressView()
                Text("Načítám \(library.items.count) titulů…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 32) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 64))
                Text(message).multilineTextAlignment(.center)
                Button("Zkusit znovu") { Task { await model.load(items: library.items) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let result, let loadedAt):
            List {
                Section {
                    HStack {
                        Text("\(result.entryCount) položek do \(Formatting.shortDate(result.lastDay))")
                        Spacer()
                        Text("načteno \(loadedAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.load(items: library.items) }
                    } label: {
                        Label("Obnovit", systemImage: "arrow.clockwise")
                    }
                }

                if result.days.isEmpty {
                    Section {
                        Text("V nejbližších \(result.today.days(until: result.lastDay)) dnech nic nevychází.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(result.days) { day in
                    Section(Formatting.dayHeader(day.date, today: result.today)) {
                        ForEach(day.entries) { entry in
                            Button { selected = entry } label: { EntryRow(entry: entry) }
                        }
                    }
                }

                if !result.skipped.isEmpty {
                    Section("Nezobrazeno (\(result.skipped.count))") {
                        ForEach(result.skipped) { skipped in
                            HStack {
                                Text(skipped.item.name ?? skipped.item.id)
                                Spacer()
                                Text(Formatting.skipReason(skipped.reason))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

struct EntryRow: View {
    let entry: CalendarEntry

    var body: some View {
        HStack(spacing: 28) {
            Poster(url: entry.posterURL)
                .frame(width: 80, height: 120)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(entry.title).font(.headline)
                    if let label = Formatting.releaseLabel(entry.releaseKind) {
                        Text(label.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                }
                Text(Formatting.subtitle(entry))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct Poster: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Rectangle().fill(.gray.opacity(0.3))
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct EntryDetailView: View {
    let entry: CalendarEntry

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            Poster(url: entry.stillURL ?? entry.posterURL)
                .frame(width: entry.stillURL == nil ? 300 : 640, height: entry.stillURL == nil ? 450 : 360)
            VStack(alignment: .leading, spacing: 20) {
                Text(entry.title).font(.title2.bold())
                Text(Formatting.subtitle(entry)).font(.headline)
                HStack {
                    Text(Formatting.shortDate(entry.date))
                    if let label = Formatting.releaseLabel(entry.releaseKind) {
                        Text("· \(label)")
                    }
                }
                .foregroundStyle(.secondary)
                if let overview = entry.overview {
                    Text(overview).font(.callout).lineLimit(8)
                }
                Text("ID v knihovně: \(entry.itemId) · TMDB \(entry.tmdbId)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(60)
    }
}
