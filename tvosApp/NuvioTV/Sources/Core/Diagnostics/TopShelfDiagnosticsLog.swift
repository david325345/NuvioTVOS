import Foundation

/// The fork's test build: the Top Shelf in the test log, at launch and each time the app comes back
/// to the front. Whether the App Group is there, what the feeds hold, how many images are rendered,
/// and each time the system asked the extension for the shelf since the last such line (the
/// extension writes those into the App Group, see `TopShelfDiagnostics`).
enum TopShelfDiagnosticsLog {
    private static let lastBuildKey = "nuvio.test.topShelf.lastBuild"
    private static let lastReportedKey = "nuvio.test.topShelf.lastReportedEntry"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func noteLaunch() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: lastBuildKey)
        defaults.set(build, forKey: lastBuildKey)
        let install: String
        switch previous {
        case nil: install = "first launch of build \(build) since it was installed (no earlier build on record)"
        case build?: install = "build \(build), launched before"
        case let previous?: install = "first launch of build \(build), installed over build \(previous)"
        }
        report("at launch, " + install)
    }

    static func noteForeground() {
        report("back in front")
    }

    private static func report(_ when: String) {
        DispatchQueue.global(qos: .utility).async {
            let defaults = UserDefaults.standard
            let entries = TopShelfDiagnostics.entries()
            let since = defaults.object(forKey: lastReportedKey) as? Date ?? .distantPast
            let unseen = entries.filter { $0.at > since }
            if let last = entries.last { defaults.set(last.at, forKey: lastReportedKey) }
            let style = TopShelfFeedStore.containerURL
                .flatMap { TopShelfConfigurationStore.read(in: $0) }?.style.rawValue ?? "default"
            var line = "topshelf: \(when) · App Group \(TopShelfDiagnostics.appGroupText) · style \(style) · "
                + "feeds: \(TopShelfDiagnostics.feedsText()) · \(TopShelfDiagnostics.artworkFileCount()) rendered images"
            let asked = unseen.filter { $0.by == "extension" }
            if asked.isEmpty {
                if let last = entries.last(where: { $0.by == "extension" }) {
                    line += " · extension not asked since the last line (last asked \(TopShelfDiagnostics.age(of: last.at)) ago)"
                } else {
                    line += " · no request from the system on record"
                }
            } else {
                line += " · extension asked \(asked.count)× since the last line"
            }
            TestDiagnosticLog.ui(line)
            for entry in unseen {
                TestDiagnosticLog.ui("topshelf: at \(timeFormatter.string(from: entry.at)) \(entry.by): \(entry.text)")
            }
        }
    }
}
