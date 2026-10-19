import SwiftUI

struct SettingsScreen: View {
    @AppStorage(SettingsKey.tmdbApiKey) private var tmdbApiKey = ""
    @AppStorage(SettingsKey.language) private var language = "cs-CZ"
    @AppStorage(SettingsKey.region) private var region = "CZ"
    @AppStorage(SettingsKey.horizonDays) private var horizonDays = 90

    var body: some View {
        NavigationStack {
            Form {
                Section("TMDB") {
                    TextField("TMDB API klíč (v3)", text: $tmdbApiKey)
                        .onSubmit { tmdbApiKey = tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
                    Text(tmdbApiKey.isEmpty ? "Klíč není zadaný." : "Klíč zadaný (\(tmdbApiKey.count) znaků).")
                        .foregroundStyle(.secondary)
                }
                Section("Jazyk názvů dílů") {
                    Picker("Jazyk", selection: $language) {
                        Text("Čeština").tag("cs-CZ")
                        Text("Angličtina").tag("en-US")
                    }
                }
                Section("Země pro data vydání filmů") {
                    Picker("Země", selection: $region) {
                        Text("Česko").tag("CZ")
                        Text("Slovensko").tag("SK")
                        Text("USA").tag("US")
                    }
                }
                Section("Rozsah kalendáře") {
                    Picker("Dní dopředu", selection: $horizonDays) {
                        Text("30 dní").tag(30)
                        Text("60 dní").tag(60)
                        Text("90 dní").tag(90)
                    }
                }
            }
            .navigationTitle("Nastavení")
        }
    }
}
