import Foundation
import CryptoKit
import Security

/// The active profile's plugin repositories and scrapers.
///
/// Repositories are added by the URL of their `manifest.json` (as on Android),
/// their scrapers' JavaScript is downloaded next to the manifest and kept in
/// files (`LargePayloadStore`, never `UserDefaults`), and the list of
/// repository URLs syncs with the account's `plugins` table so it matches the
/// Android and iOS apps. Scraper settings stay on this Apple TV, in Keychain.
@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    /// Posted when the user adds, removes or reorders repositories, with the
    /// editing profile's id under `profileIdUserInfoKey`; account sync pushes it.
    nonisolated static let repositoriesChangedNotification = Notification.Name("nuvio.tv.plugins.repositoriesChanged")
    nonisolated static let profileIdUserInfoKey = "profileId"

    struct State: Codable, Equatable {
        var pluginsEnabled = true
        var repositories: [PluginRepositoryRecord] = []
        var scrapers: [PluginScraperRecord] = []
    }

    @Published private(set) var state = State()
    /// Manifest URLs being downloaded right now.
    @Published private(set) var refreshing: Set<String> = []

    private var loadedScope: String?
    private static let directory = "NuvioPlugins"

    private init() {}

    // MARK: - Reading

    /// Reloads when the active profile changed since the last read.
    func ensureLoaded() {
        let scope = ProfileSettings.activeProfileScope
        guard scope != loadedScope else { return }
        loadedScope = scope
        state = Self.loadState(scope: scope)
    }

    var pluginsEnabled: Bool {
        ensureLoaded()
        return state.pluginsEnabled
    }

    var repositories: [PluginRepositoryRecord] {
        ensureLoaded()
        return state.repositories
    }

    func scrapers(in repositoryURL: String) -> [PluginScraperRecord] {
        ensureLoaded()
        return state.scrapers.filter { $0.repositoryURL == repositoryURL }
    }

    func scraper(id: String) -> PluginScraperRecord? {
        ensureLoaded()
        return state.scrapers.first { $0.id == id }
    }

    /// Scrapers to ask for this content type, in repository order.
    func activeScrapers(for type: String) -> [PluginScraperRecord] {
        ensureLoaded()
        guard state.pluginsEnabled else { return [] }
        let order = Dictionary(state.repositories.enumerated().map { ($1.manifestURL, $0) }, uniquingKeysWith: { first, _ in first })
        return state.scrapers
            .filter { $0.enabled && $0.manifestEnabled && $0.supports(type: type) }
            .sorted { (order[$0.repositoryURL] ?? .max) < (order[$1.repositoryURL] ?? .max) }
    }

    /// The scraper's JavaScript; downloads it again when the system purged the
    /// cached copy.
    func code(for scraper: PluginScraperRecord) async -> String? {
        let scope = ProfileSettings.activeProfileScope
        if let code = Self.readCode(scope: scope, scraperID: scraper.id) { return code }
        guard let url = Self.codeURL(repositoryURL: scraper.repositoryURL, filename: scraper.filename),
              let code = try? await Self.downloadText(url) else { return nil }
        Self.writeCode(code, scope: scope, scraperID: scraper.id)
        return code
    }

    // MARK: - Editing

    func setPluginsEnabled(_ enabled: Bool) {
        ensureLoaded()
        state.pluginsEnabled = enabled
        persist()
    }

    func setScraperEnabled(_ id: String, enabled: Bool) {
        ensureLoaded()
        guard let index = state.scrapers.firstIndex(where: { $0.id == id }) else { return }
        state.scrapers[index].enabled = enabled
        persist()
    }

    /// Adds a repository by its manifest URL (a GitHub page link to the file
    /// works too) and downloads its scrapers. Throws a message for the user.
    @discardableResult
    func addRepository(_ input: String) async throws -> PluginRepositoryRecord {
        ensureLoaded()
        guard let url = Self.normalizedManifestURL(input) else { throw PluginStoreError.invalidURL }
        let manifestURL = url.absoluteString
        if let existing = state.repositories.first(where: { $0.manifestURL == manifestURL }) {
            await refreshRepository(existing.manifestURL)
            return state.repositories.first { $0.manifestURL == manifestURL } ?? existing
        }
        let profileID = ProfileSettings.activeProfileID
        let (repository, scrapers) = try await Self.download(manifestURL: manifestURL, previous: [])
        guard ProfileSettings.activeProfileID == profileID else { throw CancellationError() }
        ensureLoaded()
        state.repositories.removeAll { $0.manifestURL == manifestURL }
        state.repositories.append(repository)
        state.scrapers.removeAll { $0.repositoryURL == manifestURL }
        state.scrapers.append(contentsOf: scrapers)
        persist()
        notifyRepositoriesChanged()
        return repository
    }

    /// Downloads the manifest and scrapers again; keeps the old copy and shows
    /// the error on the repository when that fails.
    func refreshRepository(_ manifestURL: String) async {
        ensureLoaded()
        guard state.repositories.contains(where: { $0.manifestURL == manifestURL }),
              !refreshing.contains(manifestURL) else { return }
        let profileID = ProfileSettings.activeProfileID
        refreshing.insert(manifestURL)
        defer { refreshing.remove(manifestURL) }
        let previous = state.scrapers.filter { $0.repositoryURL == manifestURL }
        do {
            let (repository, scrapers) = try await Self.download(manifestURL: manifestURL, previous: previous)
            guard ProfileSettings.activeProfileID == profileID else { return }
            ensureLoaded()
            guard let index = state.repositories.firstIndex(where: { $0.manifestURL == manifestURL }) else { return }
            state.repositories[index] = repository
            state.scrapers.removeAll { $0.repositoryURL == manifestURL }
            state.scrapers.append(contentsOf: scrapers)
            let kept = Set(scrapers.map(\.id))
            for old in previous where !kept.contains(old.id) {
                Self.removeCode(scope: ProfileSettings.activeProfileScope, scraperID: old.id)
            }
        } catch {
            guard ProfileSettings.activeProfileID == profileID,
                  let index = state.repositories.firstIndex(where: { $0.manifestURL == manifestURL }) else { return }
            state.repositories[index].errorMessage = error.localizedDescription
        }
        persist()
    }

    func refreshAll() async {
        for repository in repositories {
            await refreshRepository(repository.manifestURL)
        }
    }

    func removeRepository(_ manifestURL: String) {
        ensureLoaded()
        let scope = ProfileSettings.activeProfileScope
        for scraper in state.scrapers where scraper.repositoryURL == manifestURL {
            Self.removeCode(scope: scope, scraperID: scraper.id)
            PluginSettingsVault.remove(scraperID: scraper.id)
            PluginStorageFile.remove(scraperID: scraper.id, scope: scope)
            PluginLogStore.shared.clear(scraper.id)
        }
        state.repositories.removeAll { $0.manifestURL == manifestURL }
        state.scrapers.removeAll { $0.repositoryURL == manifestURL }
        persist()
        notifyRepositoriesChanged()
    }

    func moveRepository(_ manifestURL: String, up: Bool) {
        ensureLoaded()
        guard let index = state.repositories.firstIndex(where: { $0.manifestURL == manifestURL }) else { return }
        let target = up ? index - 1 : index + 1
        guard state.repositories.indices.contains(target) else { return }
        state.repositories.swapAt(index, target)
        persist()
        notifyRepositoriesChanged()
    }

    // MARK: - Account sync

    /// The repository URLs in order, for `sync_push_plugins`.
    var repositoryURLsForSync: [(url: String, name: String)] {
        repositories.map { ($0.manifestURL, $0.name) }
    }

    /// Makes the local list match the account's: installs repositories that
    /// are new, drops ones the account no longer has, keeps the account's
    /// order. Returns false (and changes nothing) when the account has no
    /// plugins while this Apple TV does, so the caller can push instead —
    /// Android's first-sync rule.
    @discardableResult
    func applyRemoteRepositories(_ urls: [String], profileID: String) async -> Bool {
        guard ProfileSettings.activeProfileID == profileID else { return true }
        ensureLoaded()
        var seen = Set<String>()
        let remote = urls.compactMap { Self.normalizedManifestURL($0)?.absoluteString }.filter { seen.insert($0).inserted }
        if remote.isEmpty, !state.repositories.isEmpty { return false }
        if remote == state.repositories.map(\.manifestURL) { return true }

        let scope = ProfileSettings.activeProfileScope
        let remoteSet = Set(remote)
        for scraper in state.scrapers where !remoteSet.contains(scraper.repositoryURL) {
            Self.removeCode(scope: scope, scraperID: scraper.id)
        }
        state.scrapers.removeAll { !remoteSet.contains($0.repositoryURL) }
        let existing = Dictionary(state.repositories.map { ($0.manifestURL, $0) }, uniquingKeysWith: { first, _ in first })
        state.repositories = remote.map { url in
            existing[url] ?? PluginRepositoryRecord(
                manifestURL: url,
                name: Self.fallbackName(for: url),
                scraperCount: 0
            )
        }
        persist()

        for url in remote where existing[url] == nil {
            guard ProfileSettings.activeProfileID == profileID else { break }
            await refreshRepository(url)
        }
        return true
    }

    // MARK: - Internals

    private func persist() {
        guard let scope = loadedScope,
              let data = try? JSONEncoder().encode(state) else { return }
        LargePayloadStore.write(data, key: "\(scope).state", directory: Self.directory)
    }

    private func notifyRepositoriesChanged() {
        NotificationCenter.default.post(
            name: Self.repositoriesChangedNotification,
            object: nil,
            userInfo: [Self.profileIdUserInfoKey: ProfileSettings.activeProfileID ?? ""]
        )
    }

    private static func loadState(scope: String) -> State {
        guard let data = LargePayloadStore.read(key: "\(scope).state", directory: directory),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    private static func download(
        manifestURL: String,
        previous: [PluginScraperRecord]
    ) async throws -> (PluginRepositoryRecord, [PluginScraperRecord]) {
        guard let url = URL(string: manifestURL) else { throw PluginStoreError.invalidURL }
        let data: Data
        do {
            data = try await downloadData(url)
        } catch {
            throw PluginStoreError.download("The manifest could not be downloaded: \(error.localizedDescription)")
        }
        let manifest = try PluginManifest.parse(data)
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scope = ProfileSettings.activeProfileScope

        var scrapers: [PluginScraperRecord] = []
        var failures: [String] = []
        for info in manifest.scrapers where info.isSupportedOnAppleTV {
            guard let codeURL = codeURL(repositoryURL: manifestURL, filename: info.filename) else {
                failures.append(info.name)
                continue
            }
            do {
                let code = try await downloadText(codeURL)
                let id = PluginScraperRecord.makeID(repositoryURL: manifestURL, scraperID: info.id)
                writeCode(code, scope: scope, scraperID: id)
                let old = previousByID[id]
                scrapers.append(PluginScraperRecord(
                    id: id,
                    repositoryURL: manifestURL,
                    scraperID: info.id,
                    name: info.name,
                    description: info.description ?? "",
                    version: info.version,
                    filename: info.filename,
                    supportedTypes: info.supportedTypes,
                    enabled: info.enabled ? (old?.enabled ?? true) : false,
                    manifestEnabled: info.enabled,
                    hasSettings: info.hasSettings,
                    logo: info.logo,
                    contentLanguage: info.contentLanguage,
                    formats: info.formats
                ))
            } catch {
                failures.append(info.name)
            }
        }
        guard !scrapers.isEmpty else {
            if manifest.scrapers.contains(where: \.isSupportedOnAppleTV) {
                throw PluginStoreError.download("The providers' code could not be downloaded.")
            }
            throw PluginStoreError.noSupportedScrapers
        }
        let repository = PluginRepositoryRecord(
            manifestURL: manifestURL,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            author: manifest.author,
            scraperCount: scrapers.count,
            lastUpdated: Date(),
            errorMessage: failures.isEmpty ? nil : "Not downloaded: \(failures.joined(separator: ", "))"
        )
        return (repository, scrapers)
    }

    /// Accepts a raw manifest URL, a GitHub `blob` page link or a repository
    /// root (where `manifest.json` is appended), always over http(s).
    nonisolated static func normalizedManifestURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.fragment = nil
        if host == "github.com" {
            // github.com/<owner>/<repo>/blob/<branch>/<path> → raw file.
            let parts = components.path.split(separator: "/").map(String.init)
            if parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
                components.host = "raw.githubusercontent.com"
                components.path = "/" + ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
                components.query = nil
            }
        }
        if !components.path.lowercased().hasSuffix(".json") {
            components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "manifest.json"
        }
        return components.url
    }

    /// The scraper file next to the manifest, as Android resolves it.
    nonisolated static func codeURL(repositoryURL: String, filename: String) -> URL? {
        if filename.lowercased().hasPrefix("http://") || filename.lowercased().hasPrefix("https://") {
            return URL(string: filename)
        }
        let base = repositoryURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? repositoryURL
        let directory = base.hasSuffix("/manifest.json")
            ? String(base.dropLast("/manifest.json".count))
            : String(base[..<(base.lastIndex(of: "/") ?? base.endIndex)])
        let path = filename.drop { $0 == "/" }
        return URL(string: "\(directory)/\(path)")
    }

    nonisolated static func fallbackName(for manifestURL: String) -> String {
        guard let url = URL(string: manifestURL) else { return manifestURL }
        if url.host == "raw.githubusercontent.com" {
            let parts = url.path.split(separator: "/")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return url.host ?? manifestURL
    }

    private static func downloadData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(PluginRuntime.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PluginStoreError.download("HTTP \(http.statusCode)")
        }
        return data
    }

    private static func downloadText(_ url: URL) async throws -> String {
        let data = try await downloadData(url)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PluginStoreError.download("Empty file")
        }
        return text
    }

    private static func codeKey(scope: String, scraperID: String) -> String {
        let digest = SHA256.hash(data: Data(scraperID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(scope).code.\(digest)"
    }

    private static func readCodeFile(key: String) -> String? {
        LargePayloadStore.read(key: key, directory: directory).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func readCode(scope: String, scraperID: String) -> String? {
        readCodeFile(key: codeKey(scope: scope, scraperID: scraperID))
    }

    private static func writeCode(_ code: String, scope: String, scraperID: String) {
        LargePayloadStore.write(Data(code.utf8), key: codeKey(scope: scope, scraperID: scraperID), directory: directory)
    }

    private static func removeCode(scope: String, scraperID: String) {
        LargePayloadStore.remove(key: codeKey(scope: scope, scraperID: scraperID), directory: directory)
    }
}

/// Each scraper's settings (the values of its `onSettings()` form) as a JSON
/// object in Keychain, per profile: they often hold API keys.
enum PluginSettingsVault {
    private static let service = "com.nuvio.tv.plugins.settings"

    static func settings(scraperID: String, profileScope: String = ProfileSettings.activeProfileScope) -> [String: Any] {
        var query = baseQuery(scraperID, profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    @discardableResult
    static func save(_ settings: [String: Any], scraperID: String, profileScope: String = ProfileSettings.activeProfileScope) -> Bool {
        guard JSONSerialization.isValidJSONObject(settings),
              let data = try? JSONSerialization.data(withJSONObject: settings) else { return false }
        var add = baseQuery(scraperID, profileScope)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(
                baseQuery(scraperID, profileScope) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func remove(scraperID: String, profileScope: String = ProfileSettings.activeProfileScope) -> Bool {
        let status = SecItemDelete(baseQuery(scraperID, profileScope) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(_ scraperID: String, _ profileScope: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(scraperID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(profileScope)"
        ]
    }
}
