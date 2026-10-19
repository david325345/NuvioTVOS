import SwiftUI

@main
struct KalendarTestApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                CalendarScreen()
                    .tabItem { Label("Kalendář", systemImage: "calendar") }
                LibraryScreen()
                    .tabItem { Label("Seznam", systemImage: "list.bullet") }
                SettingsScreen()
                    .tabItem { Label("Nastavení", systemImage: "gearshape") }
            }
            .environmentObject(library)
        }
    }
}
