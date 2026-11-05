import Foundation
import Security

/// Settings → Integrations → AniList → Account: the viewer's AniList account.
///
/// AniList has no sign-in for TVs. The viewer opens AniList on a phone (a QR code), allows their
/// own API client, and pastes the token AniList shows into the TV; it lasts a year. With it,
/// Nuvio reads the viewer's lists and writes how far they have watched. AniList keeps, per anime,
/// a status, a count of watched episodes, a rewatch count, a score and dates — no playback
/// position and no per-episode history.
enum AniListAccount {
    static let changedNotification = Notification.Name("nuvio.tv.anilist.account.changed")

    /// Where AniList shows the token, the Redirect URL the viewer's API client must have.
    static let tokenPage = "https://anilist.co/api/v2/oauth/pin"
    static let developerPage = "https://anilist.co/settings/developer"

    static let decoder = JSONDecoder()

    enum AccountError: LocalizedError {
        case emptyToken
        case notAccepted(String)

        var errorDescription: String? {
            switch self {
            case .emptyToken: return "Paste the token AniList shows after you allow access."
            case .notAccepted(let reason): return "AniList didn't accept the token (\(reason))."
            }
        }
    }

    struct Login: Codable, Equatable {
        let token: String
        let viewerID: Int
        let viewerName: String
        var avatar: String? = nil
        let savedAt: Date
    }

    static var storage: AniListTokenStorage = AniListKeychainTokenStorage()

    static var login: Login? { storage.login(for: ProfileSettings.activeProfileScope) }

    static var isLoggedIn: Bool { AniListSettings.isEnabled && login != nil }

    // MARK: Logging in

    /// The page that asks the viewer to allow their API client; AniList then shows the token.
    static func authorizeURL(clientID: String) -> URL? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(id)&response_type=token")
    }

    /// The token in what the viewer pasted: the token itself, or the whole address of AniList's
    /// page with `access_token=` in it.
    static func token(fromPasted pasted: String) -> String {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "access_token=") {
            text = String(text[range.upperBound...])
            if let end = text.firstIndex(where: { $0 == "&" || $0 == "#" }) {
                text = String(text[..<end])
            }
        }
        return text.filter { !$0.isWhitespace }
    }

    /// Checks the pasted token with AniList and keeps it for this profile.
    @discardableResult
    static func logIn(pasted: String) async throws -> Login {
        let token = token(fromPasted: pasted)
        guard !token.isEmpty else { throw AccountError.emptyToken }
        let answer: AniListClient.Answer
        do {
            answer = try await AniListClient.shared.answer(AniListQueries.viewer, ttl: 0, notesStatus: false, token: token, saves: false)
        } catch {
            throw AccountError.notAccepted(AniListDiagnostics.describe(error))
        }
        guard let viewer = try? decoder.decode(AniListViewerResponse.self, from: answer.data).data?.Viewer else {
            throw AccountError.notAccepted("no account in its answer")
        }
        let login = Login(token: token, viewerID: viewer.id, viewerName: viewer.name, avatar: viewer.avatar?.large, savedAt: Date())
        storage.save(login, for: ProfileSettings.activeProfileScope)
        clearStates()
        AniListDiagnostics.note(.account, "Logged in as \(viewer.name)")
        changed(homeToo: true)
        return login
    }

    static func logOut() {
        storage.remove(for: ProfileSettings.activeProfileScope)
        clearStates()
        AniListDiagnostics.note(.account, "Logged out")
        changed(homeToo: true)
    }

    /// Tells the details screens, and Home when its rows change.
    static func changed(homeToo: Bool = false) {
        let post = {
            NotificationCenter.default.post(name: changedNotification, object: nil)
            if homeToo { AniListSettings.notifyHomeChanged() }
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    // MARK: The viewer's entries

    /// Episode counts and favourites of anime, kept beside the viewer's entries.
    struct MediaState: Equatable {
        var episodes: Int?
        var isFavourite: Bool
    }

    private static let lock = NSLock()
    private static var entries: [Int: AniListListEntry] = [:]
    private static var mediaStates: [Int: MediaState] = [:]
    /// Anime whose entry AniList was asked for (an anime missing from `entries` is not on a list).
    private static var asked: Set<Int> = []

    static func entry(for mediaID: Int) -> AniListListEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[mediaID]
    }

    static func mediaState(for mediaID: Int) -> MediaState? {
        lock.lock()
        defer { lock.unlock() }
        return mediaStates[mediaID]
    }

    static func hasAsked(_ mediaID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return asked.contains(mediaID)
    }

    static func clearStates() {
        lock.lock()
        defer { lock.unlock() }
        entries = [:]
        mediaStates = [:]
        asked = []
    }

    static func store(entries newEntries: [AniListListEntry], media: [AniListMedia], asked askedIDs: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        for id in askedIDs where !newEntries.contains(where: { $0.mediaId == id }) {
            entries[id] = nil
        }
        for entry in newEntries {
            entries[entry.mediaId] = entry
        }
        for item in media {
            mediaStates[item.id] = MediaState(episodes: item.episodes, isFavourite: item.isFavourite ?? false)
        }
        asked.formUnion(askedIDs)
    }

    private static func store(saved entry: AniListListEntry) {
        lock.lock()
        defer { lock.unlock() }
        var merged = entry
        if merged.media == nil { merged.media = entries[entry.mediaId]?.media }
        entries[entry.mediaId] = merged
        asked.insert(entry.mediaId)
    }

    private static func storeRemoved(_ mediaID: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries[mediaID] = nil
        asked.insert(mediaID)
    }

    private static func storeFavourite(_ mediaID: Int, _ isFavourite: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var state = mediaStates[mediaID] ?? MediaState(episodes: nil, isFavourite: false)
        state.isFavourite = isFavourite
        mediaStates[mediaID] = state
    }

    /// The AniList entries a title is made of: its tabs, from its episodes' ids, or the film itself.
    static func entryIDs(of meta: NuvioMeta) -> [Int] {
        var ids: [Int] = []
        for video in meta.videos ?? [] {
            guard let id = AniListMetaBuilder.aniListID(from: video.id), !ids.contains(id) else { continue }
            ids.append(id)
        }
        if ids.isEmpty, let id = AniListMetaBuilder.aniListID(from: meta.id) {
            ids.append(id)
        }
        return ids
    }

    /// Asks AniList for the viewer's entries of these anime (one request, two when some aren't
    /// on a list yet and their episode counts are needed).
    static func refreshStates(ids: [Int]) async {
        guard isLoggedIn, let login, !ids.isEmpty else { return }
        let ids = Array(ids.prefix(50))
        let variables: [String: Any?] = ["userId": login.viewerID, "ids": ids, "perPage": ids.count]
        let list: [AniListListEntry]
        do {
            let answer = try await AniListClient.shared.answer(AniListQueries.entryStates, variables: variables, ttl: 0, token: login.token, saves: false)
            list = try decoder.decode(AniListEntryPageResponse.self, from: answer.data).data?.Page?.mediaList ?? []
        } catch {
            AniListDiagnostics.note(.account, "Couldn't read your list: \(AniListDiagnostics.describe(error))")
            return
        }
        var media = list.compactMap(\.media)
        let missing = ids.filter { id in !list.contains { $0.mediaId == id } }
        if !missing.isEmpty,
           let answer = try? await AniListClient.shared.answer(
               AniListQueries.mediaStates,
               variables: ["ids": missing, "perPage": missing.count],
               ttl: 0, token: login.token, saves: false
           ),
           let page = try? decoder.decode(AniListPageResponse.self, from: answer.data).data?.Page?.media {
            media += page
        }
        store(entries: list, media: media, asked: ids)
        changed()
    }

    static func refreshStates(for meta: NuvioMeta) async {
        await refreshStates(ids: entryIDs(of: meta))
    }

    /// "season:episode" keys of the episodes of an AniList title the viewer has watched,
    /// as far as their AniList progress goes.
    static func watchedEpisodeKeys(meta: NuvioMeta) -> Set<String> {
        guard isLoggedIn, AniListMetaBuilder.isAniListID(meta.id), let videos = meta.videos else { return [] }
        lock.lock()
        let known = entries
        lock.unlock()
        var keys = Set<String>()
        for video in videos {
            guard let entryID = AniListMetaBuilder.aniListID(from: video.id), let entry = known[entryID],
                  let episode = Self.episodeNumber(in: video.id) ?? Optional(video.episode) else { continue }
            if entry.status == "COMPLETED" || (entry.progress ?? 0) >= episode {
                keys.insert("\(video.season):\(video.episode)")
            }
        }
        return keys
    }

    /// The episode number in `anilist:ENTRY:EP`.
    static func episodeNumber(in id: String) -> Int? {
        let parts = id.split(separator: ":")
        guard parts.count >= 3, parts[0].lowercased() == "anilist" else { return nil }
        return Int(parts[2])
    }

    // MARK: How an entry changes

    enum Action: Equatable {
        /// An episode watched to the end in the player (`byPlaying`) or marked in details.
        case watched(episode: Int, byPlaying: Bool)
        /// An episode marked unwatched: progress goes back to the one before it.
        case unwatched(episode: Int)
    }

    /// What to write to an entry. nil fields stay as they are.
    struct Change: Equatable {
        var status: String? = nil
        var progress: Int? = nil
        var repeatCount: Int? = nil
        var scoreRaw: Int? = nil
        var startsToday = false
        var completesToday = false
    }

    /// What an action changes in the viewer's entry (`entry`, nil when the anime is on no list)
    /// of an anime with `total` episodes (nil or 0 while unknown), or nil when nothing.
    ///
    /// Progress only moves forward while watching: an episode at or below it changes nothing,
    /// so watching an older episode again never sets the count back. Finishing the last episode
    /// completes the entry; playing the first episode of a completed one starts a rewatch.
    static func change(for action: Action, entry: AniListListEntry?, total rawTotal: Int?) -> Change? {
        let total = (rawTotal ?? 0) > 0 ? rawTotal : nil
        let status = entry?.status
        let progress = entry?.progress ?? 0
        let hasStarted = entry?.startedAt?.year != nil

        switch action {
        case .watched(let episode, let byPlaying):
            guard episode > 0 else { return nil }
            switch status {
            case "COMPLETED":
                guard byPlaying, episode == 1, total != 1 else { return nil }
                return Change(status: "REPEATING", progress: 1)
            case "REPEATING":
                guard episode > progress else { return nil }
                if let total, episode >= total {
                    return Change(status: "COMPLETED", progress: total, repeatCount: (entry?.repeatCount ?? 0) + 1, completesToday: true)
                }
                return Change(progress: episode)
            default:
                if status == "CURRENT", episode <= progress { return nil }
                let reached = max(progress, episode)
                if let total, reached >= total {
                    return Change(status: "COMPLETED", progress: total, startsToday: !hasStarted, completesToday: true)
                }
                return Change(status: "CURRENT", progress: reached, startsToday: !hasStarted)
            }
        case .unwatched(let episode):
            guard let entry, episode > 0 else { return nil }
            let isDone = status == "COMPLETED"
            guard isDone || progress >= episode else { return nil }
            return Change(status: isDone ? "CURRENT" : nil, progress: episode - 1)
        }
    }

    // MARK: Writing

    /// Applies an action to one entry: asks for the entry first when it isn't known yet.
    static func perform(_ action: Action, entryID: Int, reason: String) async {
        guard isLoggedIn else { return }
        if !hasAsked(entryID) {
            await refreshStates(ids: [entryID])
        }
        guard let update = change(for: action, entry: entry(for: entryID), total: mediaState(for: entryID)?.episodes) else {
            AniListDiagnostics.note(.account, "\(reason): nothing to change on AniList")
            return
        }
        await save(update, entryID: entryID, reason: reason)
    }

    /// Sets the list an entry is on (CURRENT, PLANNING, COMPLETED, PAUSED, DROPPED, REPEATING).
    static func setStatus(_ status: String, entryID: Int) async {
        let current = entry(for: entryID)
        var update = Change(status: status)
        if status == "COMPLETED" {
            update.progress = mediaState(for: entryID)?.episodes
            update.completesToday = true
        }
        if status == "CURRENT", current?.startedAt?.year == nil {
            update.startsToday = true
        }
        await save(update, entryID: entryID, reason: "List changed")
    }

    /// The viewer's score out of 100; 0 removes it.
    static func setScore(_ score: Int, entryID: Int) async {
        await save(Change(scoreRaw: max(0, min(100, score))), entryID: entryID, reason: "Score changed")
    }

    static func save(_ change: Change, entryID: Int, reason: String) async {
        guard isLoggedIn, let login else { return }
        var variables: [String: Any?] = [
            "mediaId": entryID,
            "status": change.status,
            "progress": change.progress,
            "repeat": change.repeatCount,
            "scoreRaw": change.scoreRaw,
        ]
        if change.startsToday { variables["startedAt"] = today() }
        if change.completesToday { variables["completedAt"] = today() }
        do {
            let answer = try await AniListClient.shared.answer(AniListQueries.saveEntry, variables: variables, ttl: 0, token: login.token, saves: false)
            if let saved = try decoder.decode(AniListSavedEntryResponse.self, from: answer.data).data?.SaveMediaListEntry {
                store(saved: saved)
                AniListDiagnostics.note(.account, "\(reason): \(describe(saved))")
            }
        } catch {
            AniListDiagnostics.note(.account, "\(reason): couldn't write to AniList: \(AniListDiagnostics.describe(error))")
        }
        forgetLists()
        // A new status moves the title between the list rows on Home; progress alone doesn't.
        changed(homeToo: change.status != nil)
    }

    static func remove(entryID: Int) async {
        guard isLoggedIn, let login, let entry = entry(for: entryID) else { return }
        do {
            _ = try await AniListClient.shared.answer(AniListQueries.deleteEntry, variables: ["id": entry.id], ttl: 0, token: login.token, saves: false)
            storeRemoved(entryID)
            AniListDiagnostics.note(.account, "Removed from your list")
        } catch {
            AniListDiagnostics.note(.account, "Couldn't remove from your list: \(AniListDiagnostics.describe(error))")
        }
        forgetLists()
        changed(homeToo: true)
    }

    static func toggleFavourite(entryID: Int) async {
        guard isLoggedIn, let login else { return }
        let was = mediaState(for: entryID)?.isFavourite ?? false
        do {
            _ = try await AniListClient.shared.answer(AniListQueries.toggleFavourite, variables: ["animeId": entryID], ttl: 0, token: login.token, saves: false)
            storeFavourite(entryID, !was)
            AniListDiagnostics.note(.account, was ? "Removed from favourites" : "Added to favourites")
        } catch {
            AniListDiagnostics.note(.account, "Couldn't change favourites: \(AniListDiagnostics.describe(error))")
        }
        changed()
    }

    static func describe(_ entry: AniListListEntry) -> String {
        let total = mediaState(for: entry.mediaId)?.episodes
        let count = total.map { "\(entry.progress ?? 0)/\($0)" } ?? "\(entry.progress ?? 0)"
        return "\(statusLabel(entry.status)) · \(count)"
    }

    static func statusLabel(_ status: String?) -> String {
        switch status {
        case "CURRENT": return "Watching"
        case "PLANNING": return "Planning"
        case "COMPLETED": return "Completed"
        case "DROPPED": return "Dropped"
        case "PAUSED": return "Paused"
        case "REPEATING": return "Rewatching"
        default: return "Not on a list"
        }
    }

    static let statuses = ["CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED", "REPEATING"]

    private static func today() -> [String: Int] {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        return ["year": parts.year ?? 1970, "month": parts.month ?? 1, "day": parts.day ?? 1]
    }

    // MARK: Lists on Home

    /// The Home rows made of the viewer's lists, each with the statuses it shows.
    static let listRows: [(id: String, title: String, statuses: [String])] = [
        ("list-watching", "Watching", ["CURRENT", "REPEATING"]),
        ("list-planning", "Planning", ["PLANNING"]),
        ("list-paused", "Paused", ["PAUSED"]),
    ]

    static let listTTL: TimeInterval = 5 * 60

    private static func listVariables(_ login: Login) -> [String: Any?] {
        ["userId": login.viewerID, "statuses": listRows.flatMap(\.statuses)]
    }

    /// The viewer's entries by row id, last changed first. Kept five minutes, and dropped
    /// whenever Nuvio changes the list.
    static func listEntries() async -> [String: [AniListListEntry]]? {
        guard isLoggedIn, let login else { return nil }
        guard let answer = try? await AniListClient.shared.answer(AniListQueries.lists, variables: listVariables(login), ttl: listTTL, token: login.token),
              let lists = try? decoder.decode(AniListListCollectionResponse.self, from: answer.data).data?.MediaListCollection?.lists else {
            return nil
        }
        let all = lists.filter { $0.isCustomList != true }.flatMap { $0.entries ?? [] }
        store(entries: all, media: all.compactMap(\.media), asked: [])
        var byRow: [String: [AniListListEntry]] = [:]
        for row in listRows {
            byRow[row.id] = all
                .filter { row.statuses.contains($0.status ?? "") }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        }
        return byRow
    }

    static func forgetLists() {
        guard let login else { return }
        Task { await AniListClient.shared.forget(AniListQueries.lists, variables: listVariables(login), token: login.token) }
    }
}

// MARK: - Token storage

protocol AniListTokenStorage: AnyObject {
    func login(for profileScope: String) -> AniListAccount.Login?
    func save(_ login: AniListAccount.Login, for profileScope: String)
    func remove(for profileScope: String)
}

/// The token in the Keychain, one per profile, never synced.
final class AniListKeychainTokenStorage: AniListTokenStorage {
    private static let service = "com.nuvio.tv.anilist.auth"
    private static let lock = NSLock()
    private static var cache: [String: AniListAccount.Login] = [:]
    private static var missing: Set<String> = []

    func login(for profileScope: String) -> AniListAccount.Login? {
        let (cached, isMissing) = Self.lock.withLock { (Self.cache[profileScope], Self.missing.contains(profileScope)) }
        if let cached { return cached }
        if isMissing { return nil }
        var query = keychainQuery(for: profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let login = try? JSONDecoder().decode(AniListAccount.Login.self, from: data) else {
            Self.lock.withLock { _ = Self.missing.insert(profileScope) }
            return nil
        }
        Self.lock.withLock {
            Self.cache[profileScope] = login
            Self.missing.remove(profileScope)
        }
        return login
    }

    func save(_ login: AniListAccount.Login, for profileScope: String) {
        guard let data = try? JSONEncoder().encode(login) else { return }
        var add = keychainQuery(for: profileScope)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            _ = SecItemUpdate(keychainQuery(for: profileScope) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        Self.lock.withLock {
            Self.cache[profileScope] = login
            Self.missing.remove(profileScope)
        }
    }

    func remove(for profileScope: String) {
        Self.lock.withLock {
            Self.cache[profileScope] = nil
            Self.missing.insert(profileScope)
        }
        _ = SecItemDelete(keychainQuery(for: profileScope) as CFDictionary)
    }

    private func keychainQuery(for profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "login.\(profileScope)",
        ]
    }
}

/// For tests.
final class AniListMemoryTokenStorage: AniListTokenStorage {
    private var values: [String: AniListAccount.Login] = [:]
    func login(for profileScope: String) -> AniListAccount.Login? { values[profileScope] }
    func save(_ login: AniListAccount.Login, for profileScope: String) { values[profileScope] = login }
    func remove(for profileScope: String) { values[profileScope] = nil }
}
