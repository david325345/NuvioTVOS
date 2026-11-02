import Foundation
import JavaScriptCore
import CryptoKit
import Security

/// Why a plugin call did not return a value.
enum PluginRuntimeError: LocalizedError, Equatable {
    /// The plugin exports no function with this name (module.exports or a global).
    case missingFunction(String)
    case timedOut(TimeInterval)
    /// The script threw, or rejected, with this message.
    case script(String)

    var errorDescription: String? {
        switch self {
        case .missingFunction(let name):
            return "The plugin has no \(name)() function."
        case .timedOut(let seconds):
            return "The plugin did not answer within \(Int(seconds)) s."
        case .script(let message):
            return message.split(separator: "\n").first.map(String.init) ?? message
        }
    }
}

/// Runs plugin JavaScript in JavaScriptCore, one fresh context per call, the
/// way the Android app runs each scraper in its own QuickJS runtime. A call
/// evaluates the polyfills, sets `SCRAPER_ID` / `SCRAPER_SETTINGS`, loads the
/// plugin inside the same `module.exports` wrapper Android uses, then calls an
/// exported function and waits for its (possibly async) result as JSON.
///
/// Any exported function can be called this way — `getStreams` today, and
/// `onSettings`, `onVerify` or later resources (catalogs, metadata,
/// subtitles) without changes here.
enum PluginRuntime {
    /// Matches Android's per-call plugin timeout.
    static let defaultTimeout: TimeInterval = 60
    /// Stream searches run beside add-ons, so they get a shorter budget.
    static let streamTimeout: TimeInterval = 30
    static let maxResponseBytes = 20 * 1024 * 1024
    static let userAgent = "Mozilla/5.0 (AppleTV; tvOS 18.0) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// Network for plugin `fetch`. No cookies and no cache, like Android's
    /// plain OkHttp client, so one plugin never sees another plugin's cookies.
    /// Tests replace it with a session whose protocol classes stub responses.
    static var session: URLSession = makeSession(configuration: .ephemeral)

    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// Calls `function` in the plugin and returns its JSON result
    /// (`JSONSerialization` objects; `NSNull` for null / undefined).
    static func call(
        code: String,
        scraperId: String,
        settings: [String: Any] = [:],
        function: String,
        arguments: [Any] = [],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> Any {
        let execution = PluginExecution(
            scraperId: scraperId,
            session: session,
            storageScope: ProfileSettings.activeProfileScope
        )
        return try await withTaskCancellationHandler {
            try await execution.run(
                code: code,
                settings: settings,
                function: function,
                arguments: arguments,
                timeout: timeout
            )
        } onCancel: {
            execution.cancel()
        }
    }

    /// JSON text for a value JavaScript can read as a literal (strings and
    /// other fragments included).
    static func jsonLiteral(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// One plugin call: its JSContext, timers and requests. All JavaScript runs on
/// `queue`; the result is delivered once, by the script, the timeout or a
/// cancel, whichever comes first. The timeout fires from another queue, so a
/// script stuck in a loop still returns control to the caller.
final class PluginExecution: @unchecked Sendable {
    private let scraperId: String
    private let session: URLSession
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Any, Error>?
    private var finished = false

    // Confined to `queue`.
    private var context: JSContext?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var pendingException: String?
    private var functionName = ""
    private let storageScope: String
    private var storage: [String: String]?
    private var storageBytes = 0
    private var storageDirty = false

    init(scraperId: String, session: URLSession, storageScope: String) {
        self.scraperId = scraperId
        self.session = session
        self.storageScope = storageScope
        self.queue = DispatchQueue(label: "nuvio.plugin.execution", qos: .userInitiated)
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func run(
        code: String,
        settings: [String: Any],
        function: String,
        arguments: [Any],
        timeout: TimeInterval
    ) async throws -> Any {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(PluginRuntimeError.timedOut(timeout)))
            }
            queue.async {
                self.start(code: code, settings: settings, function: function, arguments: arguments)
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    // MARK: - Lifecycle

    private func start(code: String, settings: [String: Any], function: String, arguments: [Any]) {
        guard !isFinished else { return }
        guard let context = JSContext() else {
            finish(.failure(PluginRuntimeError.script("JavaScript could not start.")))
            return
        }
        self.context = context
        functionName = function
        context.name = "Nuvio plugin"
        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            let message = PluginExecution.describe(exception)
            self.pendingException = message
            PluginLogStore.shared.append(self.scraperId, level: .error, message: message)
        }
        installNatives(in: context)

        context.evaluateScript(PluginPolyfills.source, withSourceURL: URL(string: "nuvio://polyfills.js"))
        if let message = takeException() {
            finish(.failure(PluginRuntimeError.script("The plugin environment failed to load: \(message)")))
            return
        }

        let idLiteral = PluginRuntime.jsonLiteral(scraperId) ?? "\"\""
        let settingsLiteral = PluginRuntime.jsonLiteral(settings) ?? "{}"
        context.evaluateScript("globalThis.SCRAPER_ID = \(idLiteral);\nglobalThis.SCRAPER_SETTINGS = \(settingsLiteral);")

        let wrapped = "var module = { exports: {} };\nvar exports = module.exports;\n(function() {\n\(code)\n})();"
        context.evaluateScript(wrapped, withSourceURL: URL(string: "plugin://scraper.js"))
        if let message = takeException() {
            finish(.failure(PluginRuntimeError.script(message)))
            return
        }

        let nameLiteral = PluginRuntime.jsonLiteral(function) ?? "\"\""
        let argumentsLiteral = PluginRuntime.jsonLiteral(arguments) ?? "[]"
        context.evaluateScript("__nuvioInvoke(\(nameLiteral), \(argumentsLiteral));")
        if let message = takeException() {
            finish(.failure(PluginRuntimeError.script(message)))
        }
    }

    private func finish(_ result: Result<Any, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
        queue.async { self.teardown() }
    }

    private func teardown() {
        if storageDirty, let storage {
            PluginStorageFile.save(storage, scraperID: scraperId, scope: storageScope)
            storageDirty = false
        }
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        context?.exceptionHandler = nil
        context = nil
    }

    private func takeException() -> String? {
        defer { pendingException = nil }
        return pendingException
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "Unknown JavaScript error" }
        var message = exception.toString() ?? "Unknown JavaScript error"
        if let line = exception.objectForKeyedSubscript("line"), line.isNumber {
            message += " (line \(line.toInt32()))"
        }
        if let stack = exception.objectForKeyedSubscript("stack"), stack.isString,
           let text = stack.toString(), !text.isEmpty {
            message += "\n" + text
        }
        return message
    }

    // MARK: - Natives

    private func installNatives(in context: JSContext) {
        guard let native = JSValue(newObjectIn: context) else { return }

        let log: @convention(block) (JSValue, JSValue) -> Void = { [weak self] level, message in
            guard let self else { return }
            let logLevel = PluginLogLevel(rawValue: level.toString() ?? "") ?? .log
            PluginLogStore.shared.append(self.scraperId, level: logLevel, message: message.toString() ?? "")
        }
        let setTimer: @convention(block) (JSValue, JSValue) -> Void = { [weak self] id, milliseconds in
            self?.setTimer(Int(id.toInt32()), milliseconds: max(0, milliseconds.toDouble()))
        }
        let clearTimer: @convention(block) (JSValue) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: Int(id.toInt32()))?.cancel()
        }
        let fetch: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] id, url, options in
            self?.startFetch(id: Int(id.toInt32()), url: url.toString() ?? "", optionsJSON: options.toString() ?? "{}")
        }
        let abortFetch: @convention(block) (JSValue) -> Void = { [weak self] id in
            self?.tasks.removeValue(forKey: Int(id.toInt32()))?.cancel()
        }
        let digest: @convention(block) (JSValue, JSValue) -> String = { algorithm, base64 in
            let data = Data(base64Encoded: base64.toString() ?? "") ?? Data()
            return PluginExecution.digest(algorithm.toString() ?? "", data)?.base64EncodedString() ?? ""
        }
        let hmac: @convention(block) (JSValue, JSValue, JSValue) -> String = { algorithm, key, base64 in
            let keyData = Data(base64Encoded: key.toString() ?? "") ?? Data()
            let data = Data(base64Encoded: base64.toString() ?? "") ?? Data()
            return PluginExecution.hmac(algorithm.toString() ?? "", key: keyData, data: data)?.base64EncodedString() ?? ""
        }
        let randomBytes: @convention(block) (JSValue) -> String = { count in
            let length = min(max(Int(count.toInt32()), 0), 65_536)
            var bytes = [UInt8](repeating: 0, count: length)
            if length > 0, SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
                for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            }
            return Data(bytes).base64EncodedString()
        }
        let storageGet: @convention(block) (JSValue) -> JSValue = { [weak self] key in
            let context = JSContext.current()
            guard let self, let value = self.loadedStorage()[key.toString() ?? ""] else {
                return JSValue(nullIn: context)
            }
            return JSValue(object: value, in: context)
        }
        let storageSet: @convention(block) (JSValue, JSValue) -> Bool = { [weak self] key, value in
            self?.storageSet(key.toString() ?? "", value.toString() ?? "") ?? false
        }
        let storageRemove: @convention(block) (JSValue) -> Void = { [weak self] key in
            _ = self?.storageSet(key.toString() ?? "", nil)
        }
        let storageClear: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            self.storage = [:]
            self.storageBytes = 0
            self.storageDirty = true
        }
        let storageKeys: @convention(block) () -> [String] = { [weak self] in
            self?.loadedStorage().keys.sorted() ?? []
        }
        let done: @convention(block) (JSValue, JSValue) -> Void = { [weak self] json, error in
            guard let self else { return }
            if !error.isNull, !error.isUndefined {
                let message = error.toString() ?? "The plugin failed."
                if message == "__missing__" {
                    self.finish(.failure(PluginRuntimeError.missingFunction(self.functionName)))
                } else {
                    self.finish(.failure(PluginRuntimeError.script(message)))
                }
                return
            }
            let text = (json.isNull || json.isUndefined) ? "null" : (json.toString() ?? "null")
            let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? NSNull()
            self.finish(.success(value))
        }

        native.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        native.setObject(unsafeBitCast(setTimer, to: AnyObject.self), forKeyedSubscript: "setTimer" as NSString)
        native.setObject(unsafeBitCast(clearTimer, to: AnyObject.self), forKeyedSubscript: "clearTimer" as NSString)
        native.setObject(unsafeBitCast(fetch, to: AnyObject.self), forKeyedSubscript: "fetch" as NSString)
        native.setObject(unsafeBitCast(abortFetch, to: AnyObject.self), forKeyedSubscript: "abortFetch" as NSString)
        native.setObject(unsafeBitCast(digest, to: AnyObject.self), forKeyedSubscript: "digest" as NSString)
        native.setObject(unsafeBitCast(hmac, to: AnyObject.self), forKeyedSubscript: "hmac" as NSString)
        native.setObject(unsafeBitCast(randomBytes, to: AnyObject.self), forKeyedSubscript: "randomBytes" as NSString)
        native.setObject(unsafeBitCast(storageGet, to: AnyObject.self), forKeyedSubscript: "storageGet" as NSString)
        native.setObject(unsafeBitCast(storageSet, to: AnyObject.self), forKeyedSubscript: "storageSet" as NSString)
        native.setObject(unsafeBitCast(storageRemove, to: AnyObject.self), forKeyedSubscript: "storageRemove" as NSString)
        native.setObject(unsafeBitCast(storageClear, to: AnyObject.self), forKeyedSubscript: "storageClear" as NSString)
        native.setObject(unsafeBitCast(storageKeys, to: AnyObject.self), forKeyedSubscript: "storageKeys" as NSString)
        native.setObject(unsafeBitCast(done, to: AnyObject.self), forKeyedSubscript: "done" as NSString)
        context.setObject(native, forKeyedSubscript: "__nuvioNative" as NSString)
    }

    private func loadedStorage() -> [String: String] {
        if let storage { return storage }
        let loaded = PluginStorageFile.load(scraperID: scraperId, scope: storageScope)
        storage = loaded
        storageBytes = loaded.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        return loaded
    }

    /// Sets (or with nil removes) one `localStorage` item; false when the
    /// plugin's storage would grow past its limit.
    @discardableResult
    private func storageSet(_ key: String, _ value: String?) -> Bool {
        var current = loadedStorage()
        let oldSize = current[key].map { key.utf8.count + $0.utf8.count } ?? 0
        let newSize = value.map { key.utf8.count + $0.utf8.count } ?? 0
        if value != nil, storageBytes - oldSize + newSize > PluginStorageFile.maxBytes { return false }
        current[key] = value
        storage = current
        storageBytes += newSize - oldSize
        storageDirty = true
        return true
    }

    private func setTimer(_ id: Int, milliseconds: Double) {
        timers[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isFinished, let context = self.context else { return }
            self.timers[id] = nil
            context.objectForKeyedSubscript("__nuvioTimerFired")?.call(withArguments: [id])
        }
        timers[id] = item
        queue.asyncAfter(deadline: .now() + milliseconds / 1_000, execute: item)
    }

    private func startFetch(id: Int, url rawURL: String, optionsJSON: String) {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            deliverFetch(id, ["error": "Unsupported URL: \(rawURL)"])
            return
        }
        let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any] ?? [:]
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String)?.uppercased() ?? "GET"
        var hasUserAgent = false
        for (name, value) in (options["headers"] as? [String: Any]) ?? [:] {
            request.setValue("\(value)", forHTTPHeaderField: name)
            if name.caseInsensitiveCompare("User-Agent") == .orderedSame { hasUserAgent = true }
        }
        if !hasUserAgent {
            request.setValue(PluginRuntime.userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let body = options["body"] as? String {
            request.httpBody = Data(body.utf8)
        } else if let base64 = options["bodyBase64"] as? String {
            request.httpBody = Data(base64Encoded: base64)
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                // Gone when the script aborted it or the call already ended.
                guard self.tasks.removeValue(forKey: id) != nil else { return }
                self.deliverFetch(id, PluginExecution.fetchPayload(data: data, response: response, error: error, requestedURL: url))
            }
        }
        tasks[id] = task
        task.resume()
    }

    private func deliverFetch(_ id: Int, _ payload: [String: Any]) {
        guard !isFinished, let context else { return }
        let json = PluginRuntime.jsonLiteral(payload) ?? "{\"error\":\"The response could not be read.\"}"
        context.objectForKeyedSubscript("__nuvioFetchDone")?.call(withArguments: [id, json])
    }

    static func fetchPayload(data: Data?, response: URLResponse?, error: Error?, requestedURL: URL) -> [String: Any] {
        if let error {
            return ["error": (error as NSError).localizedDescription]
        }
        guard let http = response as? HTTPURLResponse else {
            return ["error": "No response from the server."]
        }
        let body = data ?? Data()
        guard body.count <= PluginRuntime.maxResponseBytes else {
            return ["error": "The response is larger than \(PluginRuntime.maxResponseBytes / 1_048_576) MB."]
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var payload: [String: Any] = [
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "headers": headers,
            "url": http.url?.absoluteString ?? requestedURL.absoluteString,
            "redirected": (http.url.map { $0 != requestedURL }) ?? false
        ]
        if let text = String(data: body, encoding: .utf8) {
            payload["text"] = text
        } else {
            payload["base64"] = body.base64EncodedString()
        }
        return payload
    }

    static func digest(_ algorithm: String, _ data: Data) -> Data? {
        switch algorithm {
        case "SHA-1": return Data(Insecure.SHA1.hash(data: data))
        case "SHA-256": return Data(SHA256.hash(data: data))
        case "SHA-384": return Data(SHA384.hash(data: data))
        case "SHA-512": return Data(SHA512.hash(data: data))
        case "MD5": return Data(Insecure.MD5.hash(data: data))
        default: return nil
        }
    }

    static func hmac(_ algorithm: String, key: Data, data: Data) -> Data? {
        let symmetricKey = SymmetricKey(data: key)
        switch algorithm {
        case "SHA-1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey))
        case "SHA-256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey))
        case "SHA-384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: symmetricKey))
        case "SHA-512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey))
        case "MD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: symmetricKey))
        default: return nil
        }
    }
}

// MARK: - Storage

/// A plugin's `localStorage`, per scraper and profile, kept in a file on this
/// Apple TV (an Apple TV extension; the system may purge it like any cache).
enum PluginStorageFile {
    static let maxBytes = 2 * 1024 * 1024
    private static let directory = "NuvioPlugins"

    static func load(scraperID: String, scope: String) -> [String: String] {
        guard let data = LargePayloadStore.read(key: key(scraperID, scope), directory: directory),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    static func save(_ storage: [String: String], scraperID: String, scope: String) {
        if storage.isEmpty {
            remove(scraperID: scraperID, scope: scope)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: storage) else { return }
        LargePayloadStore.write(data, key: key(scraperID, scope), directory: directory)
    }

    static func remove(scraperID: String, scope: String) {
        LargePayloadStore.remove(key: key(scraperID, scope), directory: directory)
    }

    private static func key(_ scraperID: String, _ scope: String) -> String {
        let digest = SHA256.hash(data: Data(scraperID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(scope).storage.\(digest)"
    }
}

// MARK: - Logs

enum PluginLogLevel: String, Sendable {
    case log, info, debug, warn, error
}

struct PluginLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let level: PluginLogLevel
    let message: String
}

/// The last few hundred console lines per scraper, shown in Settings so a
/// plugin author (or the user) can see why a plugin found nothing.
final class PluginLogStore: @unchecked Sendable {
    static let shared = PluginLogStore()
    static let limit = 300
    private static let maxMessageLength = 4_000

    private let lock = NSLock()
    private var entries: [String: [PluginLogEntry]] = [:]

    func append(_ scraperId: String, level: PluginLogLevel, message: String) {
        let text = message.count > Self.maxMessageLength
            ? String(message.prefix(Self.maxMessageLength)) + "…"
            : message
        lock.lock()
        var list = entries[scraperId] ?? []
        list.append(PluginLogEntry(date: Date(), level: level, message: text))
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        entries[scraperId] = list
        lock.unlock()
        #if DEBUG
        print("[Plugin] \(level.rawValue): \(text.prefix(300))")
        #endif
    }

    func entries(for scraperId: String) -> [PluginLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries[scraperId] ?? []
    }

    func clear(_ scraperId: String) {
        lock.lock()
        entries[scraperId] = nil
        lock.unlock()
    }
}
