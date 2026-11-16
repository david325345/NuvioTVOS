import BackgroundAssets
import BackgroundTasks
import Foundation
import QuartzCore
import UIKit

/// TEST: whether the Apple TV downloads while Nuvio is in the background, or while the Apple TV
/// sleeps, for a planned "download / preload" feature. Settings → Crash Reports & Test Log.
///
/// The background test tries three ways at once, all logged:
/// - a system download (a background `URLSession`), which the system goes on with while Nuvio is
///   suspended;
/// - a Background Assets download (tvOS 18.4), which the system runs when it chooses;
/// - a background task (`BGProcessingTask`) that, when the system runs it, downloads for as long
///   as it is let.
/// The foreground test downloads with Nuvio open and the screen saver and sleep held off, for an
/// Apple TV left on with only the TV turned off.
///
/// Test files are Hetzner's speed test files, not kept: the system download's file is deleted as
/// soon as it arrives, the others are read and thrown away.
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

    /// Shown in Settings: the last thing the probe noted.
    private(set) var status = "Not started"

    private var isRegistered = false
    private var backgroundCompletionHandler: (() -> Void)?
    private var wentToBackgroundAt: (wall: Date, uptime: TimeInterval)?

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

    private lazy var backgroundSession: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private lazy var inAppSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    var isBackgroundTestActive: Bool { UserDefaults.standard.bool(forKey: Self.activeKey) }
    var isForegroundTestActive: Bool { UserDefaults.standard.bool(forKey: Self.foregroundKey) }

    // MARK: - Launch

    /// From the app's init: the background task's handler (BGTaskScheduler only accepts it before
    /// launch finishes), the system download's session again (so a download the system finished
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
            _ = backgroundSession
            if #available(tvOS 18.4, *) {
                if let exception = NuvioTestCatchException({ BADownloadManager.shared.delegate = self }) {
                    log("Background Assets raised: \(exception.name.rawValue) \(exception.reason ?? "")")
                }
            }
            status = "Background test running — open this screen after the Apple TV slept, then send the log"
            // Launch finished and two seconds on (also when the system launches Nuvio in the
            // background, which may suspend it soon after): the launch went through.
            NotificationCenter.default.addObserver(
                forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    UserDefaults.standard.set(false, forKey: Self.launchGuardKey)
                }
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
        reportBackgroundAssets()
    }

    // MARK: - Background test

    /// The system download, the Background Assets download and the background task, at once.
    func startBackgroundTest() {
        UserDefaults.standard.set(true, forKey: Self.activeKey)
        let free = Self.freeSpace
        log("background test starts; free space \(TestDiagnosticLog.size(free))")

        // 10 GB when there is room for it, so it lasts past the moment the Apple TV falls asleep.
        let big = free > 25 * 1024 * 1024 * 1024
        let systemURL = Self.testFile(big ? "10GB" : "1GB")
        let task = backgroundSession.downloadTask(with: systemURL)
        task.taskDescription = "system download"
        task.countOfBytesClientExpectsToReceive = big ? 10_000_000_000 : 1_000_000_000
        task.resume()
        lock.withLock { startedAt["system download"] = Date() }
        log("system download of \(systemURL.lastPathComponent) started")

        scheduleBackgroundAssets()
        scheduleProcessing()
        status = "Background test running — press Home, let the Apple TV sleep, come back and send the log"
    }

    func stopTests() {
        UserDefaults.standard.set(false, forKey: Self.activeKey)
        UserDefaults.standard.set(false, forKey: Self.foregroundKey)
        UserDefaults.standard.set(false, forKey: Self.launchGuardKey)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskID)
        backgroundSession.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        inAppSession.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        if #available(tvOS 18.4, *) {
            if let exception = NuvioTestCatchException({
                let manager = BADownloadManager.shared
                if let downloads = try? manager.fetchCurrentDownloads() {
                    for download in downloads { try? manager.cancel(download) }
                }
            }) {
                log("Background Assets raised: \(exception.name.rawValue) \(exception.reason ?? "")")
            }
        }
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
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

    private func scheduleBackgroundAssets() {
        guard #available(tvOS 18.4, *) else {
            log("Background Assets needs tvOS 18.4")
            return
        }
        var failure: Error?
        if let exception = NuvioTestCatchException({
            let manager = BADownloadManager.shared
            manager.delegate = self
            let download = BAURLDownload(
                identifier: "download-probe-\(Int(Date().timeIntervalSince1970))",
                request: URLRequest(url: Self.testFile("1GB")),
                essential: false,
                // 0: no size check (a non-essential download fails when the size given is off).
                fileSize: 0,
                applicationGroupIdentifier: topShelfAppGroupID,
                priority: .default
            )
            do { try manager.scheduleDownload(download) } catch { failure = error }
        }) {
            log("Background Assets raised: \(exception.name.rawValue) \(exception.reason ?? "")")
        } else if let failure {
            log("Background Assets download not accepted: \(failure.localizedDescription)")
        } else {
            lock.withLock { startedAt["Background Assets"] = Date() }
            log("Background Assets download of 1GB.bin scheduled (App Group \(topShelfAppGroupID))")
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
        begin("background task")
        let download = inAppSession.dataTask(with: Self.testFile("1GB"))
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
        begin("foreground test")
        let download = inAppSession.dataTask(with: Self.testFile("10GB"))
        download.taskDescription = "foreground test"
        download.resume()
        log("foreground test starts: 10GB.bin with Nuvio open, screen saver and sleep held off")
        status = "Foreground test running — turn off only the TV, come back later and send the log"
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

    private func reportSystemDownloads() {
        guard isBackgroundTestActive else { return }
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            if tasks.isEmpty {
                self.log("system download: none running (finished or stopped)")
            }
            for task in tasks {
                self.log(
                    "system download: \(TestDiagnosticLog.size(task.countOfBytesReceived)) of "
                        + "\(TestDiagnosticLog.size(max(task.countOfBytesExpectedToReceive, 0))), \(Self.describe(task.state))"
                )
            }
        }
    }

    private func reportBackgroundAssets() {
        guard isBackgroundTestActive, #available(tvOS 18.4, *) else { return }
        var downloads: [BADownload] = []
        var failure: Error?
        if let exception = NuvioTestCatchException({
            do { downloads = try BADownloadManager.shared.fetchCurrentDownloads() } catch { failure = error }
        }) {
            log("Background Assets raised: \(exception.name.rawValue) \(exception.reason ?? "")")
            return
        }
        if let failure {
            log("Background Assets: can't read the queue: \(failure.localizedDescription)")
            return
        }
        if downloads.isEmpty {
            log("Background Assets: no download queued (finished, failed or never started)")
        }
        for download in downloads {
            log("Background Assets: \(download.identifier) \(Self.describe(download.state))")
        }
    }

    private func log(_ text: String) {
        TestDiagnosticLog.ui("download test: \(text)")
    }

    // MARK: - Helpers

    private static func testFile(_ name: String) -> URL {
        URL(string: "https://fsn1-speed.hetzner.com/\(name).bin")!
    }

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

    @available(tvOS 18.4, *)
    private static func describe(_ state: BADownload.State) -> String {
        switch state {
        case .created: return "created"
        case .waiting: return "waiting"
        case .downloading: return "downloading"
        case .finished: return "finished"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }

    /// From the app delegate: the system woke Nuvio for the system download.
    func handleBackgroundEvents(_ completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        log("the system woke Nuvio for the system download" + uptimeText)
        _ = backgroundSession
    }
}

// MARK: - URLSession

extension TVBackgroundDownloadProbe: URLSessionDownloadDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let size = Self.fileSize(location)
        try? FileManager.default.removeItem(at: location)
        log("system download finished: \(TestDiagnosticLog.size(size)), file deleted" + uptimeText)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Only while Nuvio runs; once a minute.
        guard progressDue("system download", every: 60) else { return }
        log("system download: \(TestDiagnosticLog.size(totalBytesWritten)) of \(TestDiagnosticLog.size(max(totalBytesExpectedToWrite, 0)))")
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard session === backgroundSession else { return }
        let interval = metrics.taskInterval
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log(
            "system download ran from \(formatter.string(from: interval.start)) to "
                + "\(formatter.string(from: interval.end)) (\(Self.duration(interval.duration)))"
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskDescription ?? "download"
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            if !cancelled || key == "system download" {
                log("\(key) ended: \(error.localizedDescription)" + (key == "system download" ? "" : "; \(bytesText(key))"))
            }
        } else if key != "system download" {
            log("\(key) finished: \(bytesText(key)) in \(elapsedText(key))")
        }
        if key == "background task" {
            takeProcessingTask()?.setTaskCompleted(success: error == nil)
        }
        if key == "foreground test" {
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

// MARK: - Background Assets

@available(tvOS 18.4, *)
extension TVBackgroundDownloadProbe: BADownloadManagerDelegate {
    func downloadDidBegin(_ download: BADownload) {
        log("Background Assets download began" + uptimeText)
    }

    func downloadDidPause(_ download: BADownload) {
        log("Background Assets download paused")
    }

    func download(_ download: BADownload, didWriteBytes bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard progressDue("Background Assets", every: 60) else { return }
        log("Background Assets: \(TestDiagnosticLog.size(totalBytesWritten)) written")
    }

    func download(_ download: BADownload, finishedWithFileURL fileURL: URL) {
        let size = Self.fileSize(fileURL)
        try? FileManager.default.removeItem(at: fileURL)
        log("Background Assets download finished after \(elapsedText("Background Assets")): \(TestDiagnosticLog.size(size)), file deleted" + uptimeText)
    }

    func download(_ download: BADownload, failedWithError error: Error) {
        log("Background Assets download failed: \(error.localizedDescription)")
    }
}

/// TEST: the app delegate, for the system waking Nuvio when the system download needs it.
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
