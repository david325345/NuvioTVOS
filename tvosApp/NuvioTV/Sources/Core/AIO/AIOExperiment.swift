import Foundation
import Darwin
import Security
import os

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
///
/// Everything Node.js prints goes straight to a log file, and a crash or an
/// exit() leaves a note with the native stack in it, so the next app run can
/// show how the last one ended (there is no other way to see a crash on an
/// Apple TV without a Mac).
@MainActor
final class AIOExperiment: ObservableObject {
    static let shared = AIOExperiment()

    nonisolated static let aioPort = 8770
    nonisolated static let lanPort = 8767
    private nonisolated static let autoStartKey = "aio.experiment.autoStart"
    private nonisolated static let addonKey = "aio.experiment.addonEnabled"
    private nonisolated static let secretKey = "aio.experiment.secret"
    private nonisolated static let runRecordKey = "aio.experiment.lastRun"

    enum Phase: Equatable {
        case stopped
        case starting
        case running
        case notAnswering
        case exited(Int32)
        case unavailable(String)
    }

    enum RunKind: String {
        case aio
        case nodeTest = "node-test"
    }

    /// How the previous app run ended, from its log file.
    struct PreviousRun {
        let summary: String
        let unexpected: Bool
        let date: Date?
        let lines: [String]
    }

    @Published private(set) var phase = Phase.stopped
    @Published private(set) var runKind: RunKind?
    @Published private(set) var packageVersion = ""
    @Published private(set) var startupSeconds: Double?
    @Published private(set) var nodeMemoryMB: Int?
    @Published private(set) var appMemoryMB: Int?
    @Published private(set) var manifestURL: String?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var previousRun: PreviousRun?
    @Published private(set) var notice: String?
    @Published private(set) var autoStart: Bool
    @Published private(set) var addonEnabled: Bool

    private var stateTimer: Timer?
    private var started = false
    private var startDate: Date?
    private var markedReady = false
    private var lastStartUnfinished = false

    private init() {
        autoStart = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        addonEnabled = UserDefaults.standard.object(forKey: Self.addonKey) as? Bool ?? true
        packageVersion = Self.packageInfo()
        loadPreviousRun()
        _ = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
            object: nil,
            queue: nil
        ) { _ in
            Self.note("memory warning · \(Self.memoryDescription())")
        }
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
        guard autoStart else { return }
        // A start that crashed must not crash every launch.
        if lastStartUnfinished {
            notice = "Not started automatically: the last start did not finish (see Last run). Start it here when you want to try again."
            return
        }
        start()
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

        launch(
            .aio,
            nodeStart: nodeStart,
            arguments: ["node", "--max-old-space-size=1024", bootstrap.path, package.path, install.path],
            stateFile: stateFile
        )
    }

    /// Only Node.js with a short self-test, no AIOStreams: tells a crash of
    /// Node.js itself on this Apple TV from one in AIOStreams.
    func testNodeOnly() {
        guard !started else { return }
        guard let nodeStart = Self.nodeStartFunction() else {
            phase = .unavailable("Node.js (NodeMobile.framework) is not in this build.")
            return
        }
        setenv("TMPDIR", NSTemporaryDirectory(), 1)
        launch(.nodeTest, nodeStart: nodeStart, arguments: ["node", "--input-type=module", "-e", Self.nodeTestScript], stateFile: nil)
    }

    private func launch(_ kind: RunKind, nodeStart: NodeStart, arguments: [String], stateFile: URL?) {
        started = true
        runKind = kind
        startDate = Date()
        phase = .starting
        notice = nil
        Self.saveRunRecord(kind: kind, ready: false)
        openLog()
        Self.note("start: \(kind == .aio ? "AIOStreams \(packageVersion)" : "Node.js test") · \(Self.deviceDescription()) · \(Self.memoryDescription())")
        Self.note("arguments: " + arguments.dropFirst().map { $0.count > 200 ? "<script>" : $0 }.joined(separator: " "))

        let thread = Thread {
            Self.note("Node.js thread: stack \(Thread.current.stackSize / 1_048_576) MB · calling node_start")
            let status = Self.run(nodeStart, arguments: arguments)
            Self.note("Node.js exited with code \(status)")
            Task { @MainActor in
                let shared = AIOExperiment.shared
                shared.phase = .exited(status)
                shared.refreshLog()
                shared.publishAddon()
            }
        }
        thread.name = "Node.js (AIOStreams)"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()

        stateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let shared = AIOExperiment.shared
                if let stateFile { shared.readState(stateFile) }
                shared.refreshLog()
            }
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
        if phase == .running, !markedReady {
            markedReady = true
            Self.saveRunRecord(kind: .aio, ready: true)
            Self.note("ready · \(Self.memoryDescription())")
        }
        publishAddon()
    }

    private nonisolated static func saveRunRecord(kind: RunKind, ready: Bool) {
        UserDefaults.standard.set(["kind": kind.rawValue, "ready": ready, "date": Date()], forKey: runRecordKey)
    }

    // MARK: - Log file

    private nonisolated static var logFile: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("AIOStreams-logs", isDirectory: true).appendingPathComponent("run.log")
    }

    /// stdout and stderr (Node.js, AIOStreams and Nuvio's own prints) go
    /// straight to the log file: what was written survives a crash.
    private func openLog() {
        let file = Self.logFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        aioLogDescriptor = descriptor
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(descriptor, STDOUT_FILENO)
        dup2(descriptor, STDERR_FILENO)
        Self.installCrashNotes()
    }

    /// A line of Nuvio's own in the log file.
    nonisolated static func note(_ text: String) {
        let descriptor = aioLogDescriptor
        guard descriptor >= 0 else { return }
        let line = "[nuvio] \(text)\n"
        line.withCString { _ = write(descriptor, $0, strlen($0)) }
    }

    func refreshLog() {
        guard let text = Self.tail(of: Self.logFile, bytes: 48 * 1024) else { return }
        logLines = Array(text.split(separator: "\n").suffix(400).map { Self.shorten(String($0)) })
        // AIOStreams logs every request: keep the file small.
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.logFile.path))?[.size] as? UInt64 ?? 0
        if size > 16 << 20, aioLogDescriptor >= 0 {
            ftruncate(aioLogDescriptor, 0)
            Self.note("log trimmed")
        }
    }

    private func loadPreviousRun() {
        guard let text = Self.tail(of: Self.logFile, bytes: 32 * 1024), !text.isEmpty else { return }
        let record = UserDefaults.standard.dictionary(forKey: Self.runRecordKey)
        let kind = RunKind(rawValue: record?["kind"] as? String ?? "") ?? .aio
        let ready = record?["ready"] as? Bool ?? true
        let lines = text.split(separator: "\n").map(String.init)
        var summary = "Ended when Nuvio was closed"
        var unexpected = true
        if let crash = lines.last(where: { $0.hasPrefix("[nuvio] CRASH:") }) {
            summary = "Crashed — " + String(crash.dropFirst("[nuvio] CRASH: ".count))
        } else if lines.contains(where: { $0.hasPrefix("[nuvio] exit() was called") }) {
            summary = "Node.js closed the app (exit)"
        } else if let exited = lines.last(where: { $0.hasPrefix("[nuvio] Node.js exited") }) {
            summary = String(exited.dropFirst("[nuvio] ".count))
            unexpected = !exited.hasSuffix("code 0")
        } else if kind == .aio && !ready {
            summary = "Ended during the start without a message — tvOS probably closed Nuvio (memory?)"
        } else {
            unexpected = false
        }
        lastStartUnfinished = kind == .aio && !ready
        let date = record?["date"] as? Date
        previousRun = PreviousRun(
            summary: (kind == .nodeTest ? "Node.js test: " : "") + summary,
            unexpected: unexpected,
            date: date,
            lines: Array(lines.suffix(80).map(Self.shorten))
        )
    }

    private nonisolated static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
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

    // MARK: - Crash notes

    private nonisolated static func installCrashNotes() {
        guard !aioCrashNotesInstalled else { return }
        aioCrashNotesInstalled = true
        // Touch the buffers now: never for the first time inside a signal handler.
        _ = aioFrames
        _ = aioPreviousActions
        for number in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS] {
            let name = String(cString: strsignal(number))
            aioSignalNotes[Int(number)] = strdup("\n[nuvio] CRASH: signal \(number) (\(name))\n[nuvio] native stack:\n")
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = aioNoteSignal
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(number, &action, aioPreviousActions + Int(number))
        }
        atexit(aioNoteExit)
    }

    private nonisolated static func deviceDescription() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(machine) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    nonisolated static func memoryDescription() -> String {
        let available = os_proc_available_memory() / 1_048_576
        return "Nuvio \(appFootprintMB() ?? -1) MB, tvOS allows \(available) MB more"
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

    /// What "Test Node.js only" runs: each step prints its result or its error.
    private nonisolated static let nodeTestScript = #"""
    const out = (text) => console.log('[node-test] ' + text);
    const step = async (name, run) => {
      const begin = Date.now();
      try { out(`${name}: ${await run()} (${Date.now() - begin} ms)`); }
      catch (error) { out(`${name} FAILED: ${(error && error.stack) || error}`); }
    };
    out(`Node ${process.version} · V8 ${process.versions.v8} · ${process.platform}/${process.arch} · flags ${process.config.variables.node_v8_options || '-'}`);
    await step('memory', () => Object.entries(process.memoryUsage()).map(([key, value]) => `${key} ${Math.round(value / 1048576)} MB`).join(', '));
    await step('WebAssembly', () => typeof WebAssembly);
    await step('crypto', async () => (await import('node:crypto')).createHash('sha256').update('nuvio').digest('hex').slice(0, 16));
    await step('zlib', async () => { const zlib = await import('node:zlib'); return zlib.gunzipSync(zlib.gzipSync('nuvio')).toString(); });
    await step('files', async () => { const fs = await import('node:fs'); const file = (process.env.TMPDIR || '/tmp') + '/nuvio-node-test.txt'; fs.writeFileSync(file, 'ok'); return fs.readFileSync(file, 'utf8'); });
    await step('sqlite', async () => { const { DatabaseSync } = await import('node:sqlite'); const db = new DatabaseSync(':memory:'); return db.prepare('select sqlite_version() as version').get().version; });
    await step('http server', async () => {
      const http = await import('node:http');
      const server = http.createServer((request, response) => response.end('pong'));
      await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
      const text = await (await fetch(`http://127.0.0.1:${server.address().port}/`)).text();
      server.close();
      return text;
    });
    await step('fetch https', async () => { const response = await fetch('https://www.apple.com/library/test/success.html'); return `${response.status}, ${(await response.text()).length} B`; });
    await step('cpu', () => { let sum = 0; for (let i = 0; i < 20000000; i++) sum += i % 7; return `20M loop, sum ${sum}`; });
    await step('memory after', () => `${Math.round(process.memoryUsage().rss / 1048576)} MB`);
    out('done');
    """#

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

// MARK: - Crash notes (plain C-style state: used from signal handlers)

/// The log file, once opened (stdout and stderr point to it as well).
private nonisolated(unsafe) var aioLogDescriptor: Int32 = -1
private nonisolated(unsafe) var aioCrashNotesInstalled = false

private nonisolated(unsafe) let aioFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
    let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
    frames.initialize(repeating: nil, count: 128)
    return frames
}()

private nonisolated(unsafe) let aioPreviousActions: UnsafeMutablePointer<sigaction> = {
    let actions = UnsafeMutablePointer<sigaction>.allocate(capacity: 32)
    actions.initialize(repeating: sigaction(), count: 32)
    return actions
}()

private nonisolated(unsafe) let aioSignalNotes: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
    let notes = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32)
    notes.initialize(repeating: nil, count: 32)
    return notes
}()

/// A fatal signal: the note and the native stack into the log file, then the
/// previous handling takes over (the faulting instruction or abort() raises
/// the signal again, and the app crashes as it would have).
private func aioNoteSignal(_ number: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?) {
    guard number > 0, number < 32 else { return }
    let descriptor = aioLogDescriptor
    if descriptor >= 0, let note = aioSignalNotes[Int(number)] {
        _ = write(descriptor, note, strlen(note))
        let count = backtrace(aioFrames, 128)
        backtrace_symbols_fd(aioFrames, count, descriptor)
    }
    sigaction(number, aioPreviousActions + Int(number), nil)
}

/// exit() closes the whole app; Node.js calls it on a fatal error.
private func aioNoteExit() {
    let descriptor = aioLogDescriptor
    guard descriptor >= 0 else { return }
    let text: StaticString = "\n[nuvio] exit() was called: the app is closing\n[nuvio] native stack:\n"
    _ = write(descriptor, text.utf8Start, text.utf8CodeUnitCount)
    let count = backtrace(aioFrames, 128)
    backtrace_symbols_fd(aioFrames, count, descriptor)
}
