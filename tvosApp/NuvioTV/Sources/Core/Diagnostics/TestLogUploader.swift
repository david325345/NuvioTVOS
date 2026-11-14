import Foundation
import Security

/// The fork's test build: sends the crash reports and the test log, as one file, to a GitHub
/// repository (Settings → Advanced → Crash Reports & Test Log → Send to GitHub), so they don't
/// have to go through a phone.
///
/// The token is typed on this Apple TV (or pasted from an iPhone, which offers its keyboard
/// when the field is selected) and kept in this Apple TV's Keychain; it is never part of the
/// build. A fine-grained token for the one repository with Contents: Read and write is enough.
/// Each send is one commit adding `nuvio-logs/<date>/<time>.json`.
enum TestLogUploader {
    static let defaultRepository = "david325345/nuvio-test-logs"
    private static let service = "nuvio.test.githubLogs"
    private static let account = "token"
    private static let repositoryKey = "nuvio.tv.testDiagnostics.githubRepository"

    enum Outcome: Equatable {
        case sent(path: String)
        case failed(String)
    }

    // MARK: - Settings

    static var repository: String {
        get { UserDefaults.standard.string(forKey: repositoryKey) ?? defaultRepository }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: repositoryKey) }
    }

    /// "owner/name" with the characters GitHub allows.
    static func isValidRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    static var hasToken: Bool { token != nil }

    static var token: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func forgetToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: - Sending

    /// "nuvio-logs/2026-11-09/18-47-05.json", in this Apple TV's time.
    static func path(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'/'HH-mm-ss"
        return "nuvio-logs/" + formatter.string(from: date) + ".json"
    }

    static func upload(_ data: Data, date: Date = Date()) async -> Outcome {
        guard let token else { return .failed("No GitHub token yet: set one above.") }
        let repository = repository
        guard isValidRepository(repository) else { return .failed("The repository should look like owner/name.") }
        let path = path(at: date)
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/contents/\(path)") else {
            return .failed("The repository name doesn't make a valid address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nuvio-Test-Build", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "message": "Nuvio test log " + String(path.dropFirst("nuvio-logs/".count).dropLast(".json".count)),
            "content": data.base64EncodedString()
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return .sent(path: path) }
            let message = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?["message"] as? String
            return .failed(describe(status: status, message: message, repository: repository))
        } catch {
            return .failed("Not sent: \(error.localizedDescription)")
        }
    }

    static func describe(status: Int, message: String?, repository: String) -> String {
        switch status {
        case 401:
            return "GitHub refused the token (401). It may have expired; set a new one."
        case 403:
            return "The token can't write to \(repository) (403). Give it Contents: Read and write for this repository."
        case 404:
            return "GitHub can't see \(repository) (404). Check the name, and that the token is for this repository."
        default:
            return "GitHub answered \(status)" + (message.map { ": \($0)" } ?? ".")
        }
    }
}
