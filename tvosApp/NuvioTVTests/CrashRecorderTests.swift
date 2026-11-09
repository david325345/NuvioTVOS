import XCTest
@testable import NuvioTV

/// Test build diagnostics: reports made from what a crashing session left behind.
final class CrashRecorderTests: XCTestCase {
    func testASignalReadsAsWhatHappened() {
        let text = CrashRecorder.signalDescription("signal 5 address 0x1a2b thread main")
        XCTAssertTrue(text.hasPrefix("SIGTRAP"), text)
        XCTAssertTrue(text.contains("0x1a2b"), text)
        XCTAssertTrue(text.hasSuffix("on the main thread"), text)
        XCTAssertTrue(CrashRecorder.signalDescription("signal 11 address 0x0 thread other").hasPrefix("SIGSEGV"))
    }

    func testStackLinesGetReadableSwiftNames() {
        XCTAssertEqual(CrashRecorder.demangle("$s4main3fooyyF"), "main.foo() -> ()")
        let line = CrashRecorder.demangledLine("3   NuvioTV   0x0000000104a1c3f4 $s4main3fooyyF + 120")
        XCTAssertTrue(line.contains("main.foo() -> ()"), line)
        XCTAssertTrue(line.hasPrefix("3   NuvioTV"), line)
        XCTAssertEqual(CrashRecorder.demangledLine("0   libsystem_kernel.dylib 0x1 __pthread_kill + 8"),
                       "0   libsystem_kernel.dylib 0x1 __pthread_kill + 8")
    }

    func testACrashAndASilentEndBecomeReports() {
        let crash = CrashRecorder.crashReport(from: "signal 11 address 0x0 thread other\n0 NuvioTV 0x1 $s4main3fooyyF + 4", session: nil)
        XCTAssertEqual(crash.kind, .crash)
        XCTAssertTrue(crash.summary.hasPrefix("Crash: SIGSEGV"), crash.summary)
        XCTAssertTrue(crash.details.contains("main.foo() -> ()"))

        let exception = CrashRecorder.crashReport(from: "exception NSRangeException: index 4 beyond bounds", session: nil)
        XCTAssertEqual(exception.summary, "Crash: NSRangeException: index 4 beyond bounds")

        let now = Date()
        let session = CrashRecorder.Session(version: "1 (2)", launchedAt: now.addingTimeInterval(-90), updatedAt: now,
                                            inForeground: true, memoryMB: 900, peakMemoryMB: 1_200, screen: "details(tt1, series)")
        let closed = CrashRecorder.closedReport(session: session)
        XCTAssertEqual(closed.kind, .closedBySystem)
        XCTAssertTrue(closed.details.contains("Memory: 900 MB (peak 1200 MB)"), closed.details)
        XCTAssertTrue(closed.details.contains("90 s after launch"), closed.details)
        XCTAssertTrue(closed.details.contains("Screen: details(tt1, series)"))
    }
}
