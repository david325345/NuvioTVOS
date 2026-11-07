import Foundation
import Darwin
import Security

/// Experiment (fork branch `aio-node`, never part of a PR): the original
/// AIOStreams running inside Nuvio on Apple TV, in Node.js 24 built for tvOS
/// (nodejs-mobile). The app carries `NodeMobile.framework` and the AIOStreams
/// package (`AIOPackage/aio.tar.gz` + `bootstrap.mjs`, built by CI from the
/// AIOStreams release); `bootstrap.mjs` unpacks the package on first start and
/// runs `nuvio-main.mjs`, which starts AIOStreams on 127.0.0.1 and a proxy for
/// its configuration page on the network.
///
/// Node can be started once per app run. When the configuration page saves a
/// configuration, `nuvio-main.mjs` writes its addon address to the state file
/// and Nuvio adds that addon on this Apple TV only (never synced).
@MainActor
final class AIOExperiment: ObservableObject {
    static let shared = AIOExperiment()

    nonisolated static let aioPort = 8770
    nonisolated static let lanPort = 8767
    private nonisolated static let autoStartKey = "aio.experiment.autoStart"
    private nonisolated static let addonKey = "aio.experiment.addonEnabled"
    private nonisolated static let secretKey = "aio.experiment.secret"

    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case notAnswering
        case exited(Int32)
        case unavailable(String)
    }

    @Published private(set) var phase = Phase.stopped
    @Published private(set) var packageVersion = ""
    @Published private(set) var startupSeconds: Double?
    @Published private(set) var nodeMemoryMB: Int?
    @Published private(set) var appMemoryMB: Int?
    @Published private(set) var manifestURL: String?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var autoStart: Bool
    @Published private(set) var addonEnabled: Bool

    private var stateTimer: Timer?
    private var started = false
    private var startDate: Date?

    private init() {
        autoStart = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        addonEnabled = UserDefaults.standard.object(forKey: Self.addonKey) as? Bool ?? true
        packageVersion = Self.packageInfo()
    }

    // MARK: - The addon, for CatalogRepository

    private nonisolated(unsafe) static var currentAddonURL: URL?
    private nonisolated static let addonLock = NSLock()

    /// The AIOStreams addon while it runs and is turned on; read by
    /// `CatalogRepository.configuredStreamAddonManifestURLs`.
    nonisolated static var addonManifestURLs: [URL] {
        addonLock.lock()
        defer { addonLock.unlock() }
        return currentAddonURL.map { [$0] } ?? []
    }

    private func publishAddon() {
        let url = (phase == .running && addonEnabled) ? manifestURL.flatMap(URL.init(string:)) : nil
        Self.addonLock.lock()
        Self.currentAddonURL = url
        Self.addonLock.unlock()
    }

    // MARK: - Settings

    func setAutoStart(_ enabled: Bool) {
        autoStart = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoStartKey)
    }

    func setAddonEnabled(_ enabled: Bool) {
        addonEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.addonKey)
        publishAddon()
    }

    /// The configuration page from a computer on the same network.
    var configurationPageURL: String? {
        guard let host = PluginHTTPServerCore.localIPv4Address() else { return nil }
        return "http://\(host):\(Self.lanPort)/stremio/configure"
    }

    nonisolated static var isBundled: Bool {
        Bundle.main.url(forResource: "aio", withExtension: "tar.gz") != nil
            && Bundle.main.url(forResource: "bootstrap", withExtension: "mjs") != nil
    }

    // MARK: - Start

    func startIfWanted() {
        if autoStart { start() }
    }

    func start() {
        guard !started else { return }
        guard let package = Bundle.main.url(forResource: "aio", withExtension: "tar.gz"),
              let bootstrap = Bundle.main.url(forResource: "bootstrap", withExtension: "mjs") else {
            phase = .unavailable("The AIOStreams package is not in this build.")
            return
        }
        guard let nodeStart = Self.nodeStartFunction() else {
            phase = .unavailable("Node.js (NodeMobile.framework) is not in this build.")
            return
        }
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            phase = .unavailable("No caches folder.")
            return
        }
        // The database (with the saved configuration) belongs in Application
        // Support; tvOS may refuse it, then Caches.
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        var dataDirectory = (support ?? caches).appendingPathComponent("AIOStreams", isDirectory: true)
        if (try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)) == nil {
            dataDirectory = caches.appendingPathComponent("AIOStreams", isDirectory: true)
            try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        }
        let install = caches.appendingPathComponent("AIOStreams-package", isDirectory: true)
        let cache = caches.appendingPathComponent("AIOStreams-cache", isDirectory: true)
        let compileCache = caches.appendingPathComponent("AIOStreams-compile-cache", isDirectory: true)
        for directory in [install, cache, compileCache] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let stateFile = dataDirectory.appendingPathComponent("nuvio-state.json")
        try? fileManager.removeItem(at: stateFile)

        let host = PluginHTTPServerCore.localIPv4Address() ?? "127.0.0.1"
        let environment: [String: String] = [
            "HOME": dataDirectory.path,
            "TMPDIR": NSTemporaryDirectory(),
            "NODE_ENV": "production",
            "NODE_COMPILE_CACHE": compileCache.path,
            "NODE_COMPILE_CACHE_PORTABLE": "1",
            "UV_THREADPOOL_SIZE": "4",
            "PORT": String(Self.aioPort),
            "NUVIO_LAN_PORT": String(Self.lanPort),
            "NUVIO_STATE_FILE": stateFile.path,
            "BASE_URL": "http://\(host):\(Self.lanPort)",
            "DATABASE_URI": "sqlite://" + (dataDirectory.appendingPathComponent("db.sqlite").path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""),
            "DISK_CACHE_DIR": cache.path,
            "SECRET_KEY": Self.secret(),
            "ANIME_DB_LEVEL_OF_DETAIL": "required",
            "LOG_LEVEL": "info",
            // process.exit() would close Nuvio: nuvio-main.mjs turns it into a stop.
            "NUVIO_EMBEDDED": "1",
        ]
        for (name, value) in environment {
            setenv(name, value, 1)
        }
        // AIOStreams' title and year matching need TMDB: Nuvio's own key.
        if let tmdbKey = TmdbDetailsService.currentApiKey, !tmdbKey.isEmpty {
            setenv("TMDB_API_KEY", tmdbKey, 1)
        }

        started = true
        startDate = Date()
        phase = .starting
        captureOutput()
        let arguments = ["node", "--max-old-space-size=1024", bootstrap.path, package.path, install.path]
        let thread = Thread {
            let status = Self.run(nodeStart, arguments: arguments)
            Task { @MainActor in
                AIOExperiment.shared.phase = .exited(status)
                AIOExperiment.shared.publishAddon()
            }
        }
        thread.name = "Node.js (AIOStreams)"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()

        stateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AIOExperiment.shared.readState(stateFile) }
        }
    }

    // MARK: - State

    private func readState(_ file: URL) {
        appMemoryMB = Self.appFootprintMB()
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let status = state["status"] as? String {
            switch (status, phase) {
            case ("running", .starting): phase = .running
            case ("not answering", .starting): phase = .notAnswering
            case ("failed", _), ("stopped", _):
                phase = .unavailable("AIOStreams stopped: \(state["error"] as? String ?? "see the log") — restart Nuvio to try again")
            default: break
            }
        }
        if let seconds = state["startupSeconds"] as? Double { startupSeconds = seconds }
        if let rss = state["rssMB"] as? Int { nodeMemoryMB = rss }
        if let manifest = state["manifest"] as? String { manifestURL = manifest }
        publishAddon()
    }

    // MARK: - Output

    private var outputPipe: Pipe?

    /// Node writes to the process's stdout / stderr; they go to a pipe whose
    /// lines are kept for the screen (and passed on to the original stderr).
    private func captureOutput() {
        let pipe = Pipe()
        outputPipe = pipe
        let original = dup(STDERR_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let pending = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if original >= 0 {
                chunk.withUnsafeBytes { buffer in _ = write(original, buffer.baseAddress, buffer.count) }
            }
            let lines = pending.lines(after: chunk).map(AIOExperiment.shorten)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                let shared = AIOExperiment.shared
                shared.logLines.append(contentsOf: lines)
                if shared.logLines.count > 400 { shared.logLines.removeFirst(shared.logLines.count - 400) }
            }
        }
    }

    /// AIOStreams logs JSON (pino); the message is what matters on a TV.
    private nonisolated static func shorten(_ line: String) -> String {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return String(line.prefix(400))
        }
        let level = (object["level"] as? Int).map { $0 >= 50 ? "✕ " : $0 >= 40 ? "! " : "" } ?? ""
        let module = (object["module"] as? String).map { "[\($0)] " } ?? ""
        let message = object["msg"] as? String ?? line
        return String((level + module + message).prefix(400))
    }

    /// Bytes from the pipe until a whole line has arrived (one reader at a time).
    private final class OutputBuffer: @unchecked Sendable {
        private var pending = Data()

        func lines(after chunk: Data) -> [String] {
            pending.append(chunk)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }

    // MARK: - Node

    private typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

    private nonisolated static func nodeStartFunction() -> NodeStart? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "node_start") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: NodeStart.self)
    }

    /// node_start with argv in one contiguous block, as Node expects.
    private nonisolated static func run(_ nodeStart: NodeStart, arguments: [String]) -> Int32 {
        let bytes = arguments.reduce(0) { $0 + $1.utf8.count + 1 }
        let block = UnsafeMutablePointer<CChar>.allocate(capacity: bytes)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        var cursor = block
        for (index, argument) in arguments.enumerated() {
            argv[index] = cursor
            argument.withCString { source in
                let length = strlen(source)
                cursor.update(from: source, count: length + 1)
                cursor += length + 1
            }
        }
        argv[arguments.count] = nil
        // Node keeps pointers into argv for the life of the process.
        return nodeStart(Int32(arguments.count), argv)
    }

    private nonisolated static func secret() -> String {
        if let saved = UserDefaults.standard.string(forKey: secretKey), saved.count == 64 { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(secret, forKey: secretKey)
        return secret
    }

    private nonisolated static func packageInfo() -> String {
        guard let url = Bundle.main.url(forResource: "nuvio-package", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let version = object["aiostreams"] as? String ?? ""
        let commit = object["commit"] as? String ?? ""
        return commit.isEmpty ? version : "\(version) (\(commit))"
    }

    private nonisolated static func appFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}
