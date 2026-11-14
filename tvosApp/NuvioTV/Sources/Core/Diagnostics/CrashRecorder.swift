import Darwin
import Foundation
import UIKit

// MARK: - Crash reports (fork test build)

/// Records why Nuvio closed when it wasn't asked to (Settings → Advanced → Crash Reports & Usenet
/// Log), for the fork's test build:
/// - a crash (a Swift runtime error, a bad memory access, an Objective-C exception): the signal or
///   exception and the stack of the thread that crashed, written while the app goes down and
///   turned into a report at the next launch;
/// - tvOS closing the app while it was on screen (out of memory, or not responding): there is
///   no signal for that, so a session marker that was never closed tells it, with the memory the
///   app used last.
/// Reports stay in Caches/Diagnostics on this Apple TV and are never sent anywhere.
enum CrashRecorder {
    struct Report: Codable, Identifiable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case crash, closedBySystem
        }

        let id: String
        let date: Date
        let kind: Kind
        let summary: String
        let details: String
    }

    /// The session marker, rewritten every few seconds while the app runs.
    struct Session: Codable {
        var version: String
        var launchedAt: Date
        var updatedAt: Date
        var inForeground: Bool
        var memoryMB: Int?
        var peakMemoryMB: Int?
        var screen: String?
    }

    static let maximumReports = 10
    static let newReportKey = "nuvio.tv.testDiagnostics.newCrashReport"

    private static let queue = DispatchQueue(label: "nuvio.crash-recorder", qos: .utility)
    nonisolated(unsafe) private static var session: Session?
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var installed = false

    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private static var pendingURL: URL { directory.appendingPathComponent("crash-pending.txt") }
    private static var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private static var reportsURL: URL { directory.appendingPathComponent("crash-reports.json") }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// First thing at launch: turns what the last session left into a report, then watches this one.
    static func install() {
        guard !installed else { return }
        installed = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        collectPreviousSession()

        let now = Date()
        session = Session(version: appVersion, launchedAt: now, updatedAt: now, inForeground: true,
                          memoryMB: footprintMB(), peakMemoryMB: footprintMB(), screen: nil)
        saveSession()
        installCrashHandlers(pendingPath: pendingURL.path)

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            update { $0.inForeground = false }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            update { $0.inForeground = true }
        }
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            update { $0.inForeground = false }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            guard var current = session else { return }
            let memory = footprintMB()
            current.memoryMB = memory
            if let memory { current.peakMemoryMB = max(current.peakMemoryMB ?? 0, memory) }
            current.updatedAt = Date()
            session = current
            saveSession()
        }
        timer.resume()
        self.timer = timer
    }

    /// Where the app is (a screen's name), for a report about this session.
    static func noteScreen(_ name: String) {
        if HitchMeter.screen != name { HitchMeter.previousScreen = HitchMeter.screen }
        HitchMeter.screen = name
        update { $0.screen = name }
    }

    static func reports() -> [Report] {
        guard let data = try? Data(contentsOf: reportsURL),
              let reports = try? JSONDecoder().decode([Report].self, from: data) else { return [] }
        return reports
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: reportsURL)
        UserDefaults.standard.removeObject(forKey: newReportKey)
    }

    static var hasNewReport: Bool {
        UserDefaults.standard.bool(forKey: newReportKey)
    }

    static func markSeen() {
        UserDefaults.standard.removeObject(forKey: newReportKey)
    }

    private static func update(_ change: @escaping (inout Session) -> Void) {
        queue.async {
            guard var current = session else { return }
            change(&current)
            current.updatedAt = Date()
            session = current
            saveSession()
        }
    }

    private static func saveSession() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: sessionURL, options: .atomic)
    }

    // MARK: The last session

    private static func collectPreviousSession() {
        let previous = (try? Data(contentsOf: sessionURL)).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        let pending = (try? String(contentsOf: pendingURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(at: pendingURL)

        var report: Report?
        if !pending.isEmpty {
            report = crashReport(from: pending, session: previous)
        } else if let previous, previous.inForeground {
            report = closedReport(session: previous)
        }
        guard let report else { return }
        var all = reports()
        all.insert(report, at: 0)
        if all.count > maximumReports { all.removeLast(all.count - maximumReports) }
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: reportsURL, options: .atomic)
        }
        UserDefaults.standard.set(true, forKey: newReportKey)
    }

    static func crashReport(from pending: String, session: Session?) -> Report {
        let lines = pending.components(separatedBy: "\n")
        let summary: String
        if let exception = lines.first(where: { $0.hasPrefix("exception ") }) {
            summary = "Crash: " + String(String(exception.dropFirst("exception ".count)).prefix(160))
        } else if let signalLine = lines.first(where: { $0.hasPrefix("signal ") }) {
            summary = "Crash: " + signalDescription(signalLine)
        } else {
            summary = "Crash"
        }
        let details = sessionLines(session) + "\n\n" + lines.map(demangledLine).joined(separator: "\n")
        return Report(id: UUID().uuidString, date: session?.updatedAt ?? Date(), kind: .crash, summary: summary, details: details)
    }

    static func closedReport(session: Session) -> Report {
        let summary = "Closed by tvOS while on screen (out of memory or not responding)"
        let details = sessionLines(session)
            + "\n\nNo crash was recorded: tvOS ends an app this way when it uses too much memory, or when it"
            + " stops responding during a launch or a return to the Home screen."
        return Report(id: UUID().uuidString, date: session.updatedAt, kind: .closedBySystem, summary: summary, details: details)
    }

    private static func sessionLines(_ session: Session?) -> String {
        guard let session else { return "Session: unknown" }
        let uptime = Int(session.updatedAt.timeIntervalSince(session.launchedAt))
        var lines = [
            "Version: \(session.version)",
            "Last sign of life: \(session.updatedAt.formatted(date: .abbreviated, time: .standard)), \(uptime) s after launch",
        ]
        if let memory = session.memoryMB { lines.append("Memory: \(memory) MB (peak \(session.peakMemoryMB ?? memory) MB)") }
        if let screen = session.screen { lines.append("Screen: \(screen)") }
        return lines.joined(separator: "\n")
    }

    /// "signal 11 address 0x0 thread main" → "SIGSEGV (bad memory access) at 0x0 on the main thread".
    static func signalDescription(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        let number = parts.count > 1 ? Int32(parts[1]) ?? 0 : 0
        let name: String
        switch number {
        case SIGSEGV: name = "SIGSEGV (bad memory access)"
        case SIGBUS: name = "SIGBUS (bad memory access)"
        case SIGILL: name = "SIGILL (illegal instruction)"
        case SIGTRAP: name = "SIGTRAP (Swift runtime error: force unwrap, index out of range, fatalError…)"
        case SIGABRT: name = "SIGABRT (abort)"
        case SIGFPE: name = "SIGFPE (arithmetic error)"
        default: name = "signal \(number)"
        }
        var text = name
        if let index = parts.firstIndex(of: "address"), index + 1 < parts.count { text += " at " + parts[index + 1] }
        if parts.contains("main") { text += " on the main thread" }
        return text
    }

    /// A stack line with its Swift symbol readable.
    static func demangledLine(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let token = String(word)
            guard token.hasPrefix("$s") || token.hasPrefix("_$s") || token.hasPrefix("$S") || token.hasPrefix("_T") else {
                return token
            }
            return demangle(token) ?? token
        }.joined(separator: " ")
    }

    static func demangle(_ symbol: String) -> String? {
        let mangled = symbol.hasPrefix("_$") ? String(symbol.dropFirst()) : symbol
        return mangled.withCString { pointer -> String? in
            guard let result = swiftDemangle(pointer, UInt(strlen(pointer)), nil, nil, 0) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
    }

    static func footprintMB() -> Int? {
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

@_silgen_name("swift_demangle")
private func swiftDemangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

// MARK: - While the app goes down

// Only what is safe while the process is crashing: a file opened at launch, buffers allocated at
// launch, write(2) and backtrace(3). Turned into a readable report at the next launch.
nonisolated(unsafe) private var crashFileDescriptor: Int32 = -1
nonisolated(unsafe) private var crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
nonisolated(unsafe) private var crashDigits = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
private let crashSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE]

private func installCrashHandlers(pendingPath: String) {
    crashFileDescriptor = open(pendingPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard crashFileDescriptor >= 0 else { return }
    // Allocate now, not while crashing.
    _ = crashFrames
    _ = crashDigits
    _ = backtrace(crashFrames, 1)

    for signalNumber in crashSignals {
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = crashSignalHandler
        // tvOS has no sigaltstack: a stack overflow can't be recorded, every other crash can.
        action.sa_flags = SA_SIGINFO
        sigemptyset(&action.sa_mask)
        sigaction(signalNumber, &action, nil)
    }

    NSSetUncaughtExceptionHandler { exception in
        guard crashFileDescriptor >= 0 else { return }
        var text = "exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
        text += exception.callStackSymbols.joined(separator: "\n") + "\n"
        text.withCString { _ = write(crashFileDescriptor, $0, strlen($0)) }
    }
}

private func crashSignalHandler(_ signalNumber: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    let fd = crashFileDescriptor
    if fd >= 0 {
        writeStatic(fd, "signal ")
        writeDecimal(fd, UInt(signalNumber))
        if let info {
            writeStatic(fd, " address 0x")
            writeHex(fd, UInt(bitPattern: info.pointee.si_addr))
        }
        writeStatic(fd, pthread_main_np() != 0 ? " thread main\n" : " thread other\n")
        let count = backtrace(crashFrames, 128)
        backtrace_symbols_fd(crashFrames, count, fd)
        fsync(fd)
    }
    // Let tvOS end the app as it would have.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

private func writeStatic(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

private func writeDecimal(_ fd: Int32, _ value: UInt) {
    var number = value
    var index = 31
    repeat {
        crashDigits[index] = UInt8(48 + number % 10)
        number /= 10
        index -= 1
    } while number > 0 && index >= 0
    _ = write(fd, crashDigits + index + 1, 31 - index)
}

private func writeHex(_ fd: Int32, _ value: UInt) {
    var number = value
    var index = 31
    repeat {
        let digit = UInt8(number & 0xF)
        crashDigits[index] = digit < 10 ? 48 + digit : 87 + digit
        number >>= 4
        index -= 1
    } while number > 0 && index >= 0
    _ = write(fd, crashDigits + index + 1, 31 - index)
}
