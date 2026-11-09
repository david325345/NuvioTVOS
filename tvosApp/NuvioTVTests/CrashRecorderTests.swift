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

    func testHitchesAreFramesMoreThanTwoFramesLate() {
        XCTAssertFalse(HitchMeter.isHitch(gap: 1.0 / 60.0, frameDuration: 1.0 / 60.0))
        XCTAssertFalse(HitchMeter.isHitch(gap: 0.033, frameDuration: 1.0 / 60.0))
        XCTAssertTrue(HitchMeter.isHitch(gap: 0.050, frameDuration: 1.0 / 60.0))
        // At 30 Hz a frame every 33 ms is on time.
        XCTAssertFalse(HitchMeter.isHitch(gap: 0.045, frameDuration: 1.0 / 30.0))
        XCTAssertTrue(HitchMeter.isHitch(gap: 0.070, frameDuration: 1.0 / 30.0))
    }

    func testHitchSummaryLine() {
        let summary = HitchMeter.Summary(seconds: 5, hitches: 3, lostMilliseconds: 180, longestMilliseconds: 120,
                                         focusMoves: 1, screen: "main · home", glassCards: true)
        XCTAssertEqual(summary.text, "ui: 3 hitches in 5 s, longest 120 ms, 180 ms lost, 1 focus move, main · home, glass on")
    }

    func testSampledSymbolsAreCutToTheirFunction() {
        XCTAssertEqual(
            MainThreadSampler.shortSymbol(
                "closure #1 () -> SwiftUI.ModifiedContent<SwiftUI.ZStack<A>, B> in NuvioTV.TVHomeView.homeBodyFirstHalf.getter : some SwiftUI.View"
            ),
            "TVHomeView.homeBodyFirstHalf.getter"
        )
        XCTAssertEqual(
            MainThreadSampler.shortSymbol(
                "function signature specialization <Arg[2] = Dead> of NuvioTV.(crashSignalHandler in _80B95622ED5E5A8C6AA05B68B25997FB)"
                    + "(Swift.Int32, Swift.Optional<Swift.UnsafeMutablePointer<__C.__siginfo>>, Swift.Optional<Swift.UnsafeMutableRawPointer>) -> ()"
            ),
            "crashSignalHandler"
        )
        XCTAssertEqual(MainThreadSampler.shortSymbol("NuvioTV.PosterCard.body.getter : some SwiftUI.View"), "PosterCard.body.getter")
        XCTAssertEqual(
            MainThreadSampler.shortSymbol("partial apply for closure #2 @Sendable (Swift.Int) -> () in NuvioTV.PlayerViewModel.load(url: Foundation.URL) -> ()"),
            "PlayerViewModel.load"
        )
        XCTAssertEqual(
            MainThreadSampler.shortSymbol("(extension in NuvioTV):SwiftUI.View.liquidGlassCard(cornerRadius: CoreGraphics.CGFloat) -> some SwiftUI.View"),
            "SwiftUI.View.liquidGlassCard"
        )
        XCTAssertEqual(MainThreadSampler.shortSymbol("_dispatch_main_queue_callback_4CF"), "dispatch_main_queue_callback_4CF")
        XCTAssertEqual(
            MainThreadSampler.shortSymbol(
                "protocol witness for SwiftUI.View.body.getter : A.Body in conformance NuvioTV.PosterCard : SwiftUI.View in NuvioTV"
            ),
            "PosterCard.body.getter"
        )
    }

    func testHelperFramesDontCountAsTheAppsCode() {
        XCTAssertTrue(MainThreadSampler.isUninformative("main"))
        XCTAssertTrue(MainThreadSampler.isUninformative("__swift_instantiateConcreteTypeFromMangledNameV2"))
        XCTAssertTrue(MainThreadSampler.isUninformative("destroy value witness for NuvioTV.CachedPosterArtwork"))
        XCTAssertFalse(MainThreadSampler.isUninformative("TVHomeView.focusRows.getter"))
    }

    func testShortBusySummaryLine() {
        let line = MainThreadSampler.shortSummary(
            rounds: 12, milliseconds: 610, seconds: 5, samples: 30,
            app: ["TVHomeView.focusRows.getter": 6], libraries: ["AttributeGraph": 9]
        )
        XCTAssertEqual(
            line,
            "ui: 12 short busy rounds (34–80 ms), 610 ms in all, in 5 s on {screen}"
                + " — app: TVHomeView.focusRows.getter ×6 · in: AttributeGraph ×9 (30 samples)"
        )
    }

    func testBusySummaryLine() {
        let line = MainThreadSampler.summary(
            milliseconds: 180,
            samples: 13,
            app: ["TVHomeView.body.getter": 9, "PosterCard.body.getter": 4],
            libraries: ["SwiftUICore": 7, "AttributeGraph": 5, "CoreText": 1, "UIKitCore": 1]
        )
        XCTAssertEqual(
            line,
            "ui: busy 180 ms on {screen} — app: TVHomeView.body.getter ×9, PosterCard.body.getter ×4"
                + " · in: SwiftUICore ×7, AttributeGraph ×5, CoreText ×1 (13 samples)"
        )
    }
}
