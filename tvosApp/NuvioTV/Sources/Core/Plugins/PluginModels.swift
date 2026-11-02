import Foundation

/// A plugin repository's `manifest.json`, in the format the Nuvio Android and
/// iOS apps read: a name, a version and the scrapers it ships. Unknown fields
/// are ignored (Android parses with `ignoreUnknownKeys`), which is what lets a
/// manifest carry extensions such as `resources` without breaking Android.
struct PluginManifest: Decodable {
    let name: String
    let version: String
    let description: String?
    let author: String?
    let scrapers: [PluginManifestScraper]

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, scrapers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = PluginManifest.text(container, .name) ?? ""
        version = PluginManifest.text(container, .version) ?? ""
        description = PluginManifest.text(container, .description)
        author = PluginManifest.text(container, .author)
        scrapers = (try? container.decode(LossyList<PluginManifestScraper>.self, forKey: .scrapers))?.elements ?? []
    }

    /// Parses and validates a manifest the way Android does (name, version and
    /// at least one scraper are required).
    static func parse(_ data: Data) throws -> PluginManifest {
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginStoreError.invalidManifest("This is not a plugin manifest (manifest.json).")
        }
        guard !manifest.name.isEmpty else { throw PluginStoreError.invalidManifest("The manifest has no name.") }
        guard !manifest.version.isEmpty else { throw PluginStoreError.invalidManifest("The manifest has no version.") }
        guard !manifest.scrapers.isEmpty else { throw PluginStoreError.invalidManifest("The manifest lists no providers.") }
        return manifest
    }

    fileprivate static func text<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) {
            return number.rounded() == number ? String(Int(number)) : String(number)
        }
        return nil
    }
}

struct PluginManifestScraper: Decodable {
    let id: String
    let name: String
    let description: String?
    let version: String
    let filename: String
    let supportedTypes: [String]
    let enabled: Bool
    let hasSettings: Bool
    let logo: String?
    let contentLanguage: [String]
    let supportedPlatforms: [String]
    let disabledPlatforms: [String]
    let formats: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, filename, supportedTypes, enabled, hasSettings, logo
        case contentLanguage, supportedPlatforms, disabledPlatforms, formats, supportedFormats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = PluginManifest.text(container, .id),
              let filename = PluginManifest.text(container, .filename) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "id and filename are required"))
        }
        self.id = id
        self.filename = filename
        name = PluginManifest.text(container, .name) ?? id
        description = PluginManifest.text(container, .description)
        version = PluginManifest.text(container, .version) ?? "1.0.0"
        let types = (try? container.decodeIfPresent([String].self, forKey: .supportedTypes)) ?? nil
        supportedTypes = (types?.isEmpty == false ? types! : ["movie", "tv"]).map(PluginTypes.normalized)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        hasSettings = (try? container.decodeIfPresent(Bool.self, forKey: .hasSettings)) ?? false
        logo = PluginManifest.text(container, .logo)
        contentLanguage = ((try? container.decodeIfPresent([String].self, forKey: .contentLanguage)) ?? nil) ?? []
        supportedPlatforms = ((try? container.decodeIfPresent([String].self, forKey: .supportedPlatforms)) ?? nil) ?? []
        disabledPlatforms = ((try? container.decodeIfPresent([String].self, forKey: .disabledPlatforms)) ?? nil) ?? []
        formats = ((try? container.decodeIfPresent([String].self, forKey: .formats)) ?? nil)
            ?? ((try? container.decodeIfPresent([String].self, forKey: .supportedFormats)) ?? nil)
    }

    /// Apple TV runs a scraper unless the manifest disables `tvos`, or limits
    /// it to platforms that include neither `tvos` nor `ios` (the iOS app runs
    /// the same JavaScript).
    var isSupportedOnAppleTV: Bool {
        let disabled = Set(disabledPlatforms.map { $0.lowercased() })
        if disabled.contains(PluginTypes.platform) { return false }
        let supported = Set(supportedPlatforms.map { $0.lowercased() })
        guard !supported.isEmpty else { return true }
        return supported.contains(PluginTypes.platform) || supported.contains("ios")
    }
}

enum PluginTypes {
    /// Platform name plugins see in `NUVIO_PLATFORM` and manifests use in
    /// `supportedPlatforms` / `disabledPlatforms`.
    static let platform = "tvos"

    /// Plugins use Nuvio's `movie` / `tv`; Stremio content uses `series`.
    static func normalized(_ type: String) -> String {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "series", "show", "shows", "tv", "anime": return "tv"
        case "movies", "movie", "film": return "movie"
        case let other: return other
        }
    }
}

/// A repository added by its manifest URL. The URL is the identity, as in the
/// account's `plugins` table.
struct PluginRepositoryRecord: Codable, Identifiable, Equatable {
    var id: String { manifestURL }
    let manifestURL: String
    var name: String
    var description: String?
    var version: String?
    var author: String?
    var scraperCount: Int
    var lastUpdated: Date?
    var errorMessage: String?
}

/// One scraper from a repository. `id` matches Android's
/// `<manifest url lowercased>:<scraper id>`.
struct PluginScraperRecord: Codable, Identifiable, Equatable {
    let id: String
    let repositoryURL: String
    let scraperID: String
    var name: String
    var description: String
    var version: String
    var filename: String
    var supportedTypes: [String]
    /// The user's switch; a scraper the manifest disables stays off.
    var enabled: Bool
    var manifestEnabled: Bool
    var hasSettings: Bool
    var logo: String?
    var contentLanguage: [String]
    var formats: [String]?

    func supports(type: String) -> Bool {
        supportedTypes.contains(PluginTypes.normalized(type))
    }

    static func makeID(repositoryURL: String, scraperID: String) -> String {
        "\(repositoryURL.lowercased()):\(scraperID)"
    }
}

/// One field of the settings form a plugin describes in `onSettings()` —
/// the same layout Android renders: `text` (optionally a password), `select`,
/// `toggle` (also `switch` / `checkbox`) and `info`.
struct PluginSettingField: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(isPassword: Bool, placeholder: String?)
        case select(options: [Option])
        case toggle
        case info
    }

    struct Option: Equatable, Hashable {
        let label: String
        let value: String
    }

    let id: String
    let key: String
    let label: String
    let description: String?
    let kind: Kind
    /// The value used until the user picks one (`String` or `Bool`).
    let defaultText: String?
    let defaultBool: Bool?

    static func parseLayout(_ value: Any) -> [PluginSettingField] {
        guard let items = value as? [Any] else { return [] }
        return items.enumerated().compactMap { index, raw in
            guard let item = raw as? [String: Any] else { return nil }
            let type = (item["type"] as? String)?.lowercased() ?? "info"
            let key = (item["key"] as? String) ?? ""
            let label = (item["label"] as? String) ?? (item["title"] as? String) ?? key
            let description = item["description"] as? String
            let defaultValue = item["defaultValue"] ?? item["default"]
            let kind: Kind
            switch type {
            case "text", "string", "password", "number":
                kind = .text(
                    isPassword: (item["isPassword"] as? Bool) == true || type == "password",
                    placeholder: item["placeholder"] as? String
                )
            case "select", "dropdown", "choice":
                let options = ((item["options"] as? [Any]) ?? []).compactMap { option -> Option? in
                    if let text = option as? String { return Option(label: text, value: text) }
                    guard let object = option as? [String: Any] else { return nil }
                    let value = object["value"].map { "\($0)" } ?? (object["label"] as? String)
                    guard let value else { return nil }
                    return Option(label: (object["label"] as? String) ?? value, value: value)
                }
                guard !options.isEmpty else { return nil }
                kind = .select(options: options)
            case "toggle", "switch", "checkbox", "boolean", "bool":
                kind = .toggle
            default:
                kind = .info
            }
            if kind != .info, key.isEmpty { return nil }
            let defaultIsBool = defaultValue.map(PluginJSON.isBoolean) ?? false
            return PluginSettingField(
                id: key.isEmpty ? "info-\(index)" : key,
                key: key,
                label: label,
                description: description,
                kind: kind,
                defaultText: defaultIsBool ? nil : defaultValue.flatMap(PluginJSON.text),
                defaultBool: defaultIsBool ? (defaultValue as? Bool) : nil
            )
        }
    }
}

enum PluginStoreError: LocalizedError, Equatable {
    case invalidURL
    case invalidManifest(String)
    case download(String)
    case noSupportedScrapers

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter the address of a plugin manifest.json."
        case .invalidManifest(let message): return message
        case .download(let message): return message
        case .noSupportedScrapers: return "None of this repository's providers run on Apple TV."
        }
    }
}

/// Decodes the elements it can and skips the rest, so one malformed scraper
/// does not hide a whole repository.
struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(PluginAnyDecodable.self)) == nil {
                break
            }
        }
    }
}

private struct PluginAnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Helpers for values that came out of `JSONSerialization`.
enum PluginJSON {
    /// JSON `true` / `false` (not the numbers 1 / 0, which also bridge to Bool).
    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// A string, number or boolean as text; nil for null, arrays and objects.
    static func text(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if isBoolean(value) { return (value as? Bool) == true ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
