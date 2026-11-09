import Foundation
import Darwin
import Synchronization

/// The fork's test build: what the main thread is doing when the interface stutters.
///
/// A run loop observer marks when the main thread starts and finishes a round of work. A
/// background thread looks every 10 ms; once a round has gone on for 50 ms it pauses the main
/// thread for a moment every 10 ms, copies its call stack and lets it go on. When a round of
/// 80 ms or more is over, the test log gets a line with the app's functions that came up most
/// (the innermost app function of each sample) and the system libraries the samples were in:
///
///     ui: busy 180 ms on main · home — app: TVHomeView.body.getter ×9, PosterCard.body.getter ×4
///         · in: SwiftUICore ×7, AttributeGraph ×5 (18 samples)
///
/// While the main thread is paused nothing is allocated and no lock is taken: only the thread
/// state and the frame records on its stack are read, into buffers made at start.
final class MainThreadSampler: @unchecked Sendable {
    static let shared = MainThreadSampler()

    static let sampleAfter: UInt64 = 50_000_000
    static let reportFrom: UInt64 = 80_000_000
    static let interval: useconds_t = 10_000
    static let maximumSamples = 64
    static let maximumFrames = 64

    /// When the main thread began its current round of work (uptime ns), 0 while it waits.
    private let busySince = Atomic<UInt64>(0)
    private var started = false

    #if arch(arm64)
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    #endif
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maximumSamples * maximumFrames)
    private let frameCounts = UnsafeMutablePointer<Int>.allocate(capacity: maximumSamples)
    private var sampleCount = 0
    private var periodStart: UInt64 = 0

    private init() {}

    /// Called once on the main thread at launch.
    func start() {
        #if arch(arm64)
        guard Thread.isMainThread, !started else { return }
        started = true
        let main = pthread_self()
        mainThread = pthread_mach_thread_np(main)
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(main))

        let runLoop = CFRunLoopGetMain()
        // First in a round: the round begins.
        let begin = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity([.entry, .afterWaiting, .beforeTimers]).rawValue,
            true, Int.min
        ) { [self] _, _ in
            busySince.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        }
        // Last before sleeping, after Core Animation has committed (layout and drawing): done.
        let end = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity([.beforeWaiting, .exit]).rawValue,
            true, Int.max
        ) { [self] _, _ in
            busySince.store(0, ordering: .relaxed)
        }
        CFRunLoopAddObserver(runLoop, begin, .commonModes)
        CFRunLoopAddObserver(runLoop, end, .commonModes)

        let thread = Thread { [self] in watch() }
        thread.name = "nuvio.main-thread-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
        #endif
    }

    private func watch() {
        while true {
            usleep(Self.interval)
            let since = busySince.load(ordering: .relaxed)
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if periodStart != 0, since != periodStart {
                finishPeriod(endedAt: now)
            }
            guard since != 0, now > since, now - since >= Self.sampleAfter else { continue }
            if periodStart == 0 {
                periodStart = since
                sampleCount = 0
            }
            if sampleCount < Self.maximumSamples {
                takeSample()
            }
        }
    }

    // MARK: - Sampling (the main thread is paused in here)

    private func takeSample() {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, thread_state_flavor_t(6) /* ARM_THREAD_STATE64 */, $0, &count)
            }
        }
        var written = 0
        if result == KERN_SUCCESS {
            let base = frames + sampleCount * Self.maximumFrames
            base[written] = Self.strip(UInt(state.__pc)); written += 1
            base[written] = Self.strip(UInt(state.__lr)); written += 1
            var fp = UInt(state.__fp)
            while written < Self.maximumFrames, fp >= stackLow, fp + 16 <= stackHigh, fp & 0x7 == 0 {
                let record = UnsafePointer<UInt>(bitPattern: fp)!
                let next = record[0]
                let returnAddress = Self.strip(record[1])
                if returnAddress == 0 { break }
                base[written] = returnAddress; written += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        if written > 0 {
            frameCounts[sampleCount] = written
            sampleCount += 1
        }
        #endif
    }

    /// Return addresses saved by system code may carry a pointer signature in the high bits.
    @inline(__always)
    private static func strip(_ address: UInt) -> UInt {
        address & 0x0000_000F_FFFF_FFFF
    }

    // MARK: - After a round (the main thread runs again)

    private func finishPeriod(endedAt now: UInt64) {
        let duration = now - periodStart
        let samples = sampleCount
        periodStart = 0
        sampleCount = 0
        guard duration >= Self.reportFrom, samples > 0 else { return }

        var appCounts: [String: Int] = [:]
        var libraryCounts: [String: Int] = [:]
        for sample in 0..<samples {
            let base = frames + sample * Self.maximumFrames
            var library: String?
            for index in 0..<frameCounts[sample] {
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: base[index]), &info) != 0 else { continue }
                let image = info.dli_fname.map { String(cString: $0) } ?? ""
                let isApp = image.contains(".app/")
                if library == nil, !isApp {
                    library = (image as NSString).lastPathComponent
                }
                if isApp {
                    let raw = info.dli_sname.map { String(cString: $0) } ?? "?"
                    appCounts[Self.shortSymbol(CrashRecorder.demangle(raw) ?? raw), default: 0] += 1
                    break
                }
            }
            if let library { libraryCounts[library, default: 0] += 1 }
        }
        let line = Self.summary(
            milliseconds: Int(duration / 1_000_000),
            samples: samples,
            app: appCounts,
            libraries: libraryCounts
        )
        // The screen's name is the main thread's to read.
        DispatchQueue.main.async {
            TestDiagnosticLog.ui(line.replacingOccurrences(of: "{screen}", with: HitchMeter.screen))
        }
    }

    /// "ui: busy 180 ms on {screen} — app: A ×9, B ×4 · in: SwiftUICore ×7 (18 samples)".
    static func summary(milliseconds: Int, samples: Int, app: [String: Int], libraries: [String: Int]) -> String {
        func top(_ counts: [String: Int]) -> String {
            counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(3)
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: ", ")
        }
        var line = "ui: busy \(milliseconds) ms on {screen}"
        if !app.isEmpty { line += " — app: " + top(app) }
        if !libraries.isEmpty { line += " · in: " + top(libraries) }
        return line + " (\(samples) sample\(samples == 1 ? "" : "s"))"
    }

    /// A demangled Swift symbol cut down to the function it is in:
    /// "closure #1 () -> some View in NuvioTV.TVHomeView.body.getter : some View"
    /// becomes "TVHomeView.body.getter".
    static func shortSymbol(_ symbol: String) -> String {
        var text = symbol
        text = removingNested(text, open: "<", close: ">")
        // A private name: "(crashSignalHandler in _80B95622…)" is "crashSignalHandler".
        text = text.replacingOccurrences(of: #"\(([^()]+) in _[0-9A-F]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(extension in [^)]*\):"#, with: "", options: .regularExpression)
        for prefix in ["function signature specialization  of ", "generic specialization  of ",
                       "specialized ", "merged ", "partial apply for ", "thunk for ",
                       "reabstraction thunk helper ", "@objc ", "static "] {
            while text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        }
        if let range = text.range(of: " in ", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        text = removingNested(text, open: "(", close: ")")
        for marker in [" -> ", " : "] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("NuvioTV.") { text.removeFirst("NuvioTV.".count) }
        if text.hasPrefix("_"), !text.hasPrefix("__") { text.removeFirst() }
        return text.isEmpty ? symbol : text
    }

    /// The text without what is inside `open`…`close` (nested). The ">" of an arrow "->" is
    /// not a closing bracket.
    private static func removingNested(_ text: String, open: Character, close: Character) -> String {
        let characters = Array(text)
        var result = ""
        var depth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "-", index + 1 < characters.count, characters[index + 1] == ">" {
                if depth == 0 { result += "->" }
                index += 2
                continue
            }
            if character == open {
                depth += 1
            } else if character == close, depth > 0 {
                depth -= 1
            } else if depth == 0 {
                result.append(character)
            }
            index += 1
        }
        return result
    }
}
