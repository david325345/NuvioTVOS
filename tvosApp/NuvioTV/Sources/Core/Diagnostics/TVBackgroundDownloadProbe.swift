import BackgroundTasks
import Foundation
import QuartzCore
import UIKit

/// TEST: whether the Apple TV downloads while Nuvio is in the background, or while the Apple TV
/// sleeps, for a planned "download / preload" feature. Settings → Crash Reports & Test Log.
///
/// The background test tries two ways at once, both logged (Background Assets, tried too, had
/// tvOS end Nuvio as soon as it was used, at every launch after):
/// - system downloads (a background `URLSession`), which the system goes on with while Nuvio is
///   suspended: a big file and a 100 MB one, to tell a size limit from no download at all;
/// - a background task (`BGProcessingTask`) that, when the system runs it, downloads for as long
///   as it is let.
/// The foreground test downloads with Nuvio open and the screen saver and sleep held off, for an
/// Apple TV left on with only the TV turned off.
///
/// Test files are public speed test files, not kept: the system download's file is deleted as
/// soon as it arrives, the others are read and thrown away. Each test first fetches 1 MB from
/// every test server and uses the fastest that answered (one dropped the Apple TV's connection
/// at once).
final class TVBackgroundDownloadProbe: NSObject {
    static let shared = TVBackgroundDownloadProbe()

    /// Listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let processingTaskID = "com.nuvio.tv.test.download-probe"
    static let sessionID = "com.nuvio.tv.test.download-probe.session"

    private static let activeKey = "test.downloadProbe.backgroundActive"
    private static let foregroundKey = "test.downloadProbe.foregroundActive"
    /// Set while a launch with the background test running is under way; still set at the next
    /// launch, that launch crashed, and the test is stopped so Nuvio opens.
    private static let launchGuardKey = "test.downloadProbe.launchGuard"
    /// The test server the last test picked, for the background task.
    private static let hostKey = "test.downloadProbe.host"

    /// Shown in Settings: the last thing the probe noted.
    private(set) var status = "Not started"

    private var isRegistered = false
    private var backgroundCompletionHandler: (() -> Void)?
    private var wentToBackgroundAt: (wall: Date, uptime: TimeInterval)?
    /// Main thread only: the system downloads' state, logged while Nuvio is open.
    private var statusTimer: Timer?
    private var watchingSince = Date()
    /// Main thread only: how often the foreground test started again after a network error.
    private var foregroundRestarts = 0

    /// In-app downloads (background task, foreground test): bytes so far, by task description.
    /// Reached from the sessions' queues and the main thread: only under `lock`.
    private let lock = NSLock()
    private var received: [String: Int64] = [:]
    private var startedAt: [String: Date] = [:]
    private var lastProgressLog: [String: Date] = [:]
    private var processingTask: BGTask?

    private func begin(_ key: String) {
        lock.withLock {
            received[key] = 0
            startedAt[key] = Date()
            lastProgressLog[key] = nil
        }
    }

    /// Whether a progress line for `key` is due (one every `interval` seconds).
    private func progressDue(_ key: String, every interval: TimeInterval) -> Bool {
        lock.withLock {
            let now = Date()
            if let last = lastProgressLog[key], now.timeIntervalSince(last) < interval { return false }
            lastProgressLog[key] = now
            return true
        }
    }

    /// The background task, taken once (by its end or by the system's time limit).
    private func takeProcessingTask() -> BGTask? {
        lock.withLock {
            let task = processingTask
            processingTask = nil
            return task
        }
    }

    // MARK: - Sessions

    /// The system downloads' session, made and used on its own queue: making it waits for the
    /// system's download service, which on some systems never answers (and tvOS ends an app
    /// kept waiting on the main thread at launch).
    private let sessionQueue = DispatchQueue(label: "nuvio.test.download-probe.session")
    /// Only on `sessionQueue`.
    private var madeBackgroundSession: URLSession?

    private func withBackgroundSession(_ body: @escaping (URLSession) -> Void) {
        sessionQueue.async { [self] in
            if madeBackgroundSession == nil {
                let start = Date()
                let late = DispatchWorkItem { [weak self] in
                    self?.log("system download service hasn't answered for 5 s")
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: late)
                let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
                configuration.sessionSendsLaunchEvents = true
                configuration.isDiscretionary = false
                configuration.timeoutIntervalForResource = 60 * 60 * 24
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                late.cancel()
                madeBackgroundSession = session
                log(
                    "system download session ready in \(TestDiagnosticLog.elapsed(since: start)) "
                        + "(discretionary \(session.configuration.isDiscretionary))"
                )
            }
            if let session = madeBackgroundSession { body(session) }
        }
    }

    private lazy var inAppSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// The 1 MB server checks: no delegate, nothing kept.
    private lazy var checkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    var isBackgroundTestActive: Bool { UserDefaults.standard.bool(forKey: Self.activeKey) }
    var isForegroundTestActive: Bool { UserDefaults.standard.bool(forKey: Self.foregroundKey) }

    // MARK: - Launch

    /// From the app's init: the background task's handler (BGTaskScheduler only accepts it before
    /// launch finishes), the system downloads' session again (so a download the system finished
    /// meanwhile reports back), and the app's comings and goings.
    func registerAtLaunch() {
        guard !isRegistered else { return }
        isRegistered = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.launchGuardKey) {
            // The last launch with the test running didn't get through: stop it, so Nuvio opens.
            defaults.set(false, forKey: Self.launchGuardKey)
            defaults.set(false, forKey: Self.activeKey)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskID)
            log("the last launch with the background test running crashed: test stopped (see Crash Reports)")
            cancelSystemDownloads()
        }
        var accepted = false
        if let exception = NuvioTestCatchException({
            accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskID, using: nil) { [weak self] task in
                self?.handleProcessing(task)
            }
        }) {
            log("background task handler raised: \(exception.name.rawValue) \(exception.reason ?? "")")
        } else if !accepted {
            log("background task handler not accepted")
        }
        if isBackgroundTestActive {
            defaults.set(true, forKey: Self.launchGuardKey)
            log("launched while the background test runs" + uptimeText)
            withBackgroundSession { _ in }
            status = "Background test running — open this screen after the Apple TV slept, then send the log"
            // Launch finished and two seconds on (also when the system launches Nuvio in the
            // background, which may suspend it soon after): the launch went through.
            NotificationCenter.default.addObserver(
                forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    UserDefaults.standard.set(false, forKey: Self.launchGuardKey)
                }
                guard let self, UIApplication.shared.applicationState != .background else { return }
                self.reportSystemDownloads()
                self.watchSystemDownloads()
            }
        }
        // A foreground test doesn't survive Nuvio closing.
        UserDefaults.standard.set(false, forKey: Self.foregroundKey)

        let center = NotificationCenter.default
        // Inactive covers the Home screen, the screen saver and sleep; back is when Nuvio is
        // active again.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wentAway(to: "inactive")
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wentAway(to: "in the background")
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cameBack()
        }
    }

    private var uptimeText: String {
        " (Apple TV awake for \(Self.duration(ProcessInfo.processInfo.systemUptime)) since it last started)"
    }

    private func wentAway(to state: String) {
        guard isBackgroundTestActive || isForegroundTestActive else { return }
        if wentToBackgroundAt == nil {
            wentToBackgroundAt = (Date(), ProcessInfo.processInfo.systemUptime)
        }
        log("Nuvio is \(state)" + progressText)
    }

    /// Back from the Home screen or from sleep: how long Nuvio was away, and how much of that the
    /// Apple TV slept (its uptime doesn't count while it sleeps), and where the downloads are.
    private func cameBack() {
        guard isBackgroundTestActive || isForegroundTestActive, let away = wentToBackgroundAt else { return }
        wentToBackgroundAt = nil
        var text = "Nuvio is back"
        do {
            let wall = Date().timeIntervalSince(away.wall)
            let awake = ProcessInfo.processInfo.systemUptime - away.uptime
            text += " after \(Self.duration(wall)); the Apple TV slept about \(Self.duration(max(0, wall - awake))) of it"
        }
        log(text + progressText)
        reportSystemDownloads()
        watchSystemDownloads()
    }

    // MARK: - Test servers

    private enum FileSize: String {
        case tenGB = "10 GB", oneGB = "1 GB", hundredMB = "100 MB"
    }

    private struct TestServer {
        let name: String
        let base: String
        let files: [FileSize: String]
        /// 1 MB for the check: a path asked for in full, or nil for the first megabyte of the
        /// biggest file (a range).
        let checkPath: String?

        func url(_ size: FileSize) -> URL? {
            files[size].flatMap { URL(string: base + $0) }
        }

        var biggest: FileSize { files[.tenGB] != nil ? .tenGB : files[.oneGB] != nil ? .oneGB : .hundredMB }
    }

    /// In order of preference when two are as fast.
    private static let servers: [TestServer] = [
        TestServer(
            name: "Hetzner Nuremberg", base: "https://nbg1-speed.hetzner.com/",
            files: [.tenGB: "10GB.bin", .oneGB: "1GB.bin", .hundredMB: "100MB.bin"], checkPath: nil
        ),
        TestServer(
            name: "Tele2", base: "http://speedtest.tele2.net/",
            files: [.tenGB: "10GB.zip", .oneGB: "1GB.zip", .hundredMB: "100MB.zip"], checkPath: nil
        ),
        TestServer(
            name: "thinkbroadband", base: "http://ipv4.download.thinkbroadband.com/",
            files: [.oneGB: "1GB.zip", .hundredMB: "100MB.zip"], checkPath: nil
        ),
        TestServer(
            name: "Cloudflare", base: "https://speed.cloudflare.com/__down?bytes=",
            files: [.oneGB: "1000000000", .hundredMB: "100000000"], checkPath: "1048576"
        ),
        TestServer(
            name: "Hetzner Falkenstein", base: "https://fsn1-speed.hetzner.com/",
            files: [.tenGB: "10GB.bin", .oneGB: "1GB.bin", .hundredMB: "100MB.bin"], checkPath: nil
        )
    ]

    private static let checkBytes = 1_048_576

    /// 1 MB from every test server at once, each logged; the fastest that answered, kept for the
    /// background task too.
    private func chooseServer() async -> TestServer? {
        let results = await withTaskGroup(of: (Int, TimeInterval?).self) { group in
            for index in Self.servers.indices {
                group.addTask { [self] in (index, await check(Self.servers[index])) }
            }
            var all: [(Int, TimeInterval?)] = []
            for await result in group { all.append(result) }
            return all
        }
        let working = results.compactMap { index, seconds in seconds.map { (index, $0) } }
        guard let best = working.min(by: { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }) else {
            log("no test server answered: test stopped")
            return nil
        }
        let server = Self.servers[best.0]
        UserDefaults.standard.set(server.name, forKey: Self.hostKey)
        log("test files from \(server.name)")
        return server
    }

    /// Seconds for the first megabyte, or nil (logged either way).
    private func check(_ server: TestServer) async -> TimeInterval? {
        let start = Date()
        let url = server.checkPath.flatMap { URL(string: server.base + $0) } ?? server.url(server.biggest)
        guard let url else { return nil }
        var request = URLRequest(url: url)
        if server.checkPath == nil {
            request.setValue("bytes=0-\(Self.checkBytes - 1)", forHTTPHeaderField: "Range")
        }
        do {
            let (bytes, response) = try await checkSession.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var count = 0
            for try await _ in bytes {
                count += 1
                if count >= Self.checkBytes { break }
            }
            bytes.task.cancel()
            let seconds = Date().timeIntervalSince(start)
            let rate = Double(count) * 8 / max(seconds, 0.001) / 1_000_000
            log(
                "server check \(server.name): HTTP \(status), \(TestDiagnosticLog.size(Int64(count))) in "
                    + "\(Int(seconds * 1_000)) ms (\(Int(rate)) Mbit/s)"
            )
            guard (200..<300).contains(status), count >= Self.checkBytes else { return nil }
            return seconds
        } catch {
            log("server check \(server.name) failed after \(Int(Date().timeIntervalSince(start) * 1_000)) ms: \(Self.errorText(error))")
            return nil
        }
    }

    private static var savedServer: TestServer {
        let name = UserDefaults.standard.string(forKey: hostKey)
        return servers.first { $0.name == name } ?? servers[0]
    }

    // MARK: - Background test

    /// The system downloads and the background task, at once.
    func startBackgroundTest() {
        UserDefaults.standard.set(true, forKey: Self.activeKey)
        let free = Self.freeSpace
        log("background test starts; tvOS \(UIDevice.current.systemVersion), free space \(TestDiagnosticLog.size(free))")
        status = "Background test starting — checking test servers, then press Home, let the Apple TV sleep, come back and send the log"
        Task { [weak self] in
            guard let self, let server = await self.chooseServer() else {
                UserDefaults.standard.set(false, forKey: Self.activeKey)
                return
            }
            guard self.isBackgroundTestActive else { return }
            // 10 GB when there is room for it, so it lasts past the moment the Apple TV falls asleep.
            let big: FileSize = free > 25 * 1024 * 1024 * 1024 ? server.biggest : .oneGB
            self.startSystemDownloads([big, .hundredMB], from: server)
            await MainActor.run {
                self.scheduleProcessing()
                self.status = "Background test running — press Home, let the Apple TV sleep, come back and send the log"
            }
        }
    }

    /// Earlier system downloads cancelled first, so only these run. No size given to the system:
    /// a big one may have it hold the download back.
    private func startSystemDownloads(_ sizes: [FileSize], from server: TestServer) {
        withBackgroundSession { [weak self] session in
            session.getAllTasks { old in
                guard let self else { return }
                if !old.isEmpty {
                    old.forEach { $0.cancel() }
                    self.log("cancelled \(old.count) earlier system download(s)")
                }
                for size in sizes {
                    guard let url = server.url(size) else { continue }
                    let key = "system download \(size.rawValue)"
                    let task = session.downloadTask(with: url)
                    task.taskDescription = key
                    self.begin(key)
                    task.resume()
                    self.log("\(Self.name(task)) started: \(url.absoluteString)")
                }
                self.watchSystemDownloads()
            }
        }
    }

    private func cancelSystemDownloads() {
        withBackgroundSession { session in
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
    }

    func stopTests() {
        UserDefaults.standard.set(false, forKey: Self.activeKey)
        UserDefaults.standard.set(false, forKey: Self.foregroundKey)
        UserDefaults.standard.set(false, forKey: Self.launchGuardKey)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskID)
        cancelSystemDownloads()
        inAppSession.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
            self.statusTimer?.invalidate()
            self.statusTimer = nil
        }
        log("tests stopped" + progressText)
        status = "Stopped"
    }

    private func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        var failure: Error?
        if let exception = NuvioTestCatchException({
            do { try BGTaskScheduler.shared.submit(request) } catch { failure = error }
        }) {
            log("background task request raised: \(exception.name.rawValue) \(exception.reason ?? "")")
        } else if let failure {
            log("background task not accepted: \(failure.localizedDescription)")
        } else {
            log("background task asked for (the system runs it when it chooses)")
        }
    }

    // MARK: - Background task

    private func handleProcessing(_ task: BGTask) {
        let state = Thread.isMainThread
            ? UIApplication.shared.applicationState
            : DispatchQueue.main.sync { UIApplication.shared.applicationState }
        log("background task runs (app \(Self.describe(state)))" + uptimeText)
        guard isBackgroundTestActive else {
            task.setTaskCompleted(success: true)
            return
        }
        lock.withLock { processingTask = task }
        scheduleProcessing() // the next run
        guard let url = Self.savedServer.url(.oneGB) else {
            takeProcessingTask()?.setTaskCompleted(success: false)
            return
        }
        begin("background task")
        let download = inAppSession.dataTask(with: url)
        download.taskDescription = "background task"
        task.expirationHandler = { [weak self, weak download] in
            guard let self else { return }
            download?.cancel()
            self.log("background task stopped by the system after \(self.elapsedText("background task")); \(self.bytesText("background task"))")
            self.takeProcessingTask()?.setTaskCompleted(success: false)
        }
        download.resume()
    }

    // MARK: - Foreground test

    /// Downloads with Nuvio open, the screen saver and sleep held off (as during playback).
    func startForegroundTest() {
        UserDefaults.standard.set(true, forKey: Self.foregroundKey)
        UIApplication.shared.isIdleTimerDisabled = true
        foregroundRestarts = 0
        status = "Foreground test starting — checking test servers, then turn off only the TV, come back later and send the log"
        log("foreground test starts; tvOS \(UIDevice.current.systemVersion)")
        Task { [weak self] in
            guard let self, let server = await self.chooseServer() else {
                UserDefaults.standard.set(false, forKey: Self.foregroundKey)
                await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
                return
            }
            await MainActor.run {
                guard self.isForegroundTestActive else { return }
                self.begin("foreground test")
                self.runForegroundDownload(from: server)
                self.status = "Foreground test running — turn off only the TV, come back later and send the log"
            }
        }
    }

    /// Main thread.
    private func runForegroundDownload(from server: TestServer) {
        guard let url = server.url(server.biggest) else { return }
        let download = inAppSession.dataTask(with: url)
        download.taskDescription = "foreground test"
        download.resume()
        log("foreground test downloads \(url.absoluteString) with Nuvio open, screen saver and sleep held off")
    }

    /// After a network error: up to three more tries, five seconds apart (bytes keep adding up).
    private func restartForegroundDownload() {
        DispatchQueue.main.async { [self] in
            guard isForegroundTestActive, foregroundRestarts < 3 else {
                UserDefaults.standard.set(false, forKey: Self.foregroundKey)
                UIApplication.shared.isIdleTimerDisabled = false
                return
            }
            foregroundRestarts += 1
            log("foreground test starts again in 5 s (try \(foregroundRestarts + 1) of 4)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                guard isForegroundTestActive else { return }
                runForegroundDownload(from: Self.savedServer)
            }
        }
    }

    // MARK: - Reports

    private var progressText: String {
        let parts = ["foreground test", "background task"].compactMap { key -> String? in
            guard lock.withLock({ startedAt[key] }) != nil else { return nil }
            return "\(key): \(bytesText(key))"
        }
        return parts.isEmpty ? "" : "; " + parts.joined(separator: ", ")
    }

    private func bytesText(_ key: String) -> String {
        TestDiagnosticLog.size(lock.withLock { received[key] ?? 0 })
    }

    private func elapsedText(_ key: String) -> String {
        guard let start = lock.withLock({ startedAt[key] }) else { return "?" }
        return Self.duration(Date().timeIntervalSince(start))
    }

    /// While Nuvio is open: the system downloads every 15 s for two minutes, then every minute.
    private func watchSystemDownloads() {
        DispatchQueue.main.async { [self] in
            guard isBackgroundTestActive else { return }
            watchingSince = Date()
            statusTimer?.invalidate()
            statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.isBackgroundTestActive else {
                    self.statusTimer?.invalidate()
                    self.statusTimer = nil
                    return
                }
                guard UIApplication.shared.applicationState == .active else { return }
                let early = Date().timeIntervalSince(self.watchingSince) < 120
                guard self.progressDue("system download status", every: early ? 14 : 59) else { return }
                self.reportSystemDownloads()
            }
        }
    }

    private func reportSystemDownloads() {
        guard isBackgroundTestActive else { return }
        withBackgroundSession { [weak self] session in
            session.getAllTasks { tasks in
                guard let self else { return }
                if tasks.isEmpty {
                    self.log("system downloads: none running (finished or stopped)")
                    DispatchQueue.main.async {
                        self.statusTimer?.invalidate()
                        self.statusTimer = nil
                    }
                }
                for task in tasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
                    self.log(Self.describe(task))
                }
            }
        }
    }

    private func log(_ text: String) {
        TestDiagnosticLog.ui("download test: \(text)")
    }

    // MARK: - Helpers

    private static var freeSpace: Int64 {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3_600) h \((total % 3_600) / 60) min"
    }

    /// "system download 100 MB #4".
    private static func name(_ task: URLSessionTask) -> String {
        "\(task.taskDescription ?? "download") #\(task.taskIdentifier)"
    }

    private static func describe(_ task: URLSessionTask) -> String {
        var text = "\(name(task)): \(TestDiagnosticLog.size(task.countOfBytesReceived)) of "
            + "\(TestDiagnosticLog.size(max(task.countOfBytesExpectedToReceive, 0))), \(describe(task.state))"
        if let response = task.response as? HTTPURLResponse {
            text += ", HTTP \(response.statusCode)"
        } else {
            text += ", no answer from the server yet"
        }
        if let error = task.error { text += ", " + errorText(error) }
        return text
    }

    /// The message with its domain and code, and the error under it.
    static func errorText(_ error: Error) -> String {
        let error = error as NSError
        var text = "\(error.localizedDescription) (\(error.domain) \(error.code))"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.domain) \(underlying.code)"
        }
        return text
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "open"
        case .inactive: return "inactive"
        case .background: return "in the background"
        @unknown default: return "?"
        }
    }

    private static func describe(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running: return "running"
        case .suspended: return "suspended"
        case .canceling: return "canceling"
        case .completed: return "completed"
        @unknown default: return "?"
        }
    }

    /// From the app delegate: the system woke Nuvio for a system download.
    func handleBackgroundEvents(_ completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        log("the system woke Nuvio for a system download" + uptimeText)
        withBackgroundSession { _ in }
    }
}

// MARK: - URLSession

extension TVBackgroundDownloadProbe: URLSessionDownloadDelegate, URLSessionDataDelegate {
    private static func isSystemDownload(_ session: URLSession) -> Bool {
        session.configuration.identifier == sessionID
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let size = Self.fileSize(location)
        try? FileManager.default.removeItem(at: location)
        let key = downloadTask.taskDescription ?? "system download"
        log("\(Self.name(downloadTask)) finished: \(TestDiagnosticLog.size(size)) in \(elapsedText(key)), file deleted" + uptimeText)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Only while Nuvio runs: the first data at once, then once a minute.
        let key = downloadTask.taskDescription ?? "system download"
        guard progressDue(key, every: 60) else { return }
        var text = "\(Self.name(downloadTask)): \(TestDiagnosticLog.size(totalBytesWritten)) of "
            + "\(TestDiagnosticLog.size(max(totalBytesExpectedToWrite, 0))) after \(elapsedText(key))"
        if let response = downloadTask.response as? HTTPURLResponse { text += ", HTTP \(response.statusCode)" }
        if let start = lock.withLock({ startedAt[key] }) {
            let seconds = max(1, Date().timeIntervalSince(start))
            text += ", \(Int(Double(totalBytesWritten) * 8 / seconds / 1_000_000)) Mbit/s"
        }
        log(text)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let key = dataTask.taskDescription else { return }
        let (total, start) = lock.withLock { () -> (Int64, Date?) in
            received[key, default: 0] += Int64(data.count)
            return (received[key] ?? 0, startedAt[key])
        }
        // The background task every 30 s, the foreground test every minute.
        guard progressDue(key, every: key == "background task" ? 30 : 60) else { return }
        let now = Date()
        let seconds = max(1, now.timeIntervalSince(start ?? now))
        let rate = Double(total) * 8 / seconds / 1_000_000
        log("\(key): \(bytesText(key)) in \(elapsedText(key)), \(Int(rate)) Mbit/s")
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        log("\(Self.name(task)): the system says it waits for a network connection")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let interval = metrics.taskInterval
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let tries = metrics.transactionMetrics
        var text = "\(Self.name(task)) ran from \(formatter.string(from: interval.start)) to "
            + "\(formatter.string(from: interval.end)) (\(Self.duration(interval.duration))); "
            + "\(tries.count) request(s) sent"
        if let last = tries.last {
            text += "; the last: \(last.networkProtocolName ?? "no protocol")"
            if let response = last.response as? HTTPURLResponse {
                text += ", HTTP \(response.statusCode)"
            } else {
                text += ", no answer"
            }
            if let address = last.remoteAddress { text += ", server \(address)" }
        }
        log(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskDescription ?? "download"
        let system = Self.isSystemDownload(session)
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            if system {
                log("\(Self.name(task)) ended: \(Self.errorText(error)); \(TestDiagnosticLog.size(task.countOfBytesReceived)) received")
            } else if !cancelled {
                log("\(key) ended: \(Self.errorText(error)); \(bytesText(key)) in \(elapsedText(key))")
            }
            if key == "foreground test", !cancelled {
                restartForegroundDownload()
            }
        } else if !system {
            log("\(key) finished: \(bytesText(key)) in \(elapsedText(key))")
        }
        if key == "background task" {
            takeProcessingTask()?.setTaskCompleted(success: error == nil)
        }
        if key == "foreground test", error == nil || (error as NSError?)?.code == NSURLErrorCancelled {
            UserDefaults.standard.set(false, forKey: Self.foregroundKey)
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}

/// TEST: the app delegate, for the system waking Nuvio when a system download needs it.
final class TVBackgroundProbeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == TVBackgroundDownloadProbe.sessionID else {
            completionHandler()
            return
        }
        TVBackgroundDownloadProbe.shared.handleBackgroundEvents(completionHandler)
    }
}
