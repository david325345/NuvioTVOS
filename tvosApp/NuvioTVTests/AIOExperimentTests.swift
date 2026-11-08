//
//  AIOExperimentTests.swift
//  NuvioTVTests
//
//  Fork branch aio-node only: installs the original AIOStreams from its official
//  image and starts it in Node.js inside the app on the tvOS simulator, as on
//  Apple TV; checks the version and for updates, saves a configuration like its page does and
//  asks the resulting addon for streams; then checks the backup, the warm-up
//  and that a configuration AIOStreams lost comes back from the backup.
//  Prints the timings and the log.
//

import XCTest
@testable import NuvioTV

@MainActor
final class AIOExperimentTests: XCTestCase {

    func testOriginalAIOStreamsRunsInsideNuvio() async throws {
        try XCTSkipUnless(AIOExperiment.isBundled, "This build has no AIOStreams package")
        let aio = AIOExperiment.shared
        let started = Date()
        aio.start()
        aio.setLogVisible(true)

        try await waitUntil(seconds: 600) {
            switch aio.phase {
            case .starting, .stopped: return false
            default: return true
            }
        }
        report("start", since: started)
        guard aio.phase == .running else {
            XCTFail("AIOStreams did not start: \(aio.phase)")
            return
        }

        // Installed from the official image; Nuvio's version port answers.
        await aio.refreshVersions()
        XCTAssertFalse(aio.packageVersion.isEmpty, "installed version")
        await aio.checkForUpdates()
        note("AIO-TEST installed \(aio.packageVersion) · newest \(aio.latestVersion ?? "?") · \(aio.updateStatus ?? "")")
        XCTAssertNotNil(aio.latestVersion, "check for updates")

        let local = "http://127.0.0.1:\(AIOExperiment.aioPort)"
        let page = "http://127.0.0.1:\(AIOExperiment.lanPort)"
        let health = try await status("\(local)/api/v1/health")
        XCTAssertEqual(health, 200)
        let configurationPage = try await status("\(page)/stremio/configure")
        XCTAssertEqual(configurationPage, 200, "configuration page through Nuvio's proxy")

        // Save a configuration through the proxy, as the page would: AIOStreams'
        // starter template with Torrentio only and no TMDB features.
        let body = try configuration()
        var request = URLRequest(url: URL(string: "\(page)/api/v1/user")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120
        let (created, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201, String(decoding: created.prefix(400), as: UTF8.self))

        try await waitUntil(seconds: 15) { aio.manifestURL != nil }
        let manifest = try XCTUnwrap(aio.manifestURL, "Nuvio did not get the addon address")
        XCTAssertEqual(AIOExperiment.addonManifestURLs.map(\.absoluteString), [manifest], "the addon is offered to Nuvio")
        let manifestStatus = try await status(manifest)
        XCTAssertEqual(manifestStatus, 200)

        let streamURL = manifest.replacingOccurrences(of: "/manifest.json", with: "/stream/movie/tt0133093.json")
        for attempt in 1...2 {
            let begin = Date()
            let (data, answer) = try await URLSession.shared.data(from: URL(string: streamURL)!)
            XCTAssertEqual((answer as? HTTPURLResponse)?.statusCode, 200)
            let streams = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
            note("AIO-TEST stream request \(attempt): \(streams.count) streams in \(Int(Date().timeIntervalSince(begin) * 1000)) ms; first: \(String(describing: streams.first?["name"] ?? "-"))")
        }
        note("AIO-TEST ready in \(aio.startupSeconds ?? -1) s · Node \(aio.nodeMemoryMB ?? -1) MB · app \(aio.appMemoryMB ?? -1) MB · \(aio.packageVersion)")
        try await waitUntil(seconds: 10) { aio.startupProfile?.contains("first streams") == true }
        note("AIO-TEST times of the start: \(aio.startupProfile ?? "none")")
        XCTAssertNotNil(aio.startupProfile, "the times of the start")

        // The configuration page's save left a backup, and the warm-up ran.
        try await waitUntil(seconds: 15) { aio.hasBackup }
        XCTAssertTrue(aio.hasBackup, "the configuration is backed up")
        try await waitUntil(seconds: 120) { aio.lastWarmUp != nil }
        note("AIO-TEST warm-up: \(aio.lastWarmUp ?? "did not run")")
        XCTAssertNotNil(aio.lastWarmUp)

        // AIOStreams loses the configuration (as when tvOS clears Caches):
        // Nuvio restores it from the backup, with a new addon address.
        let uuid = try XCTUnwrap(AIOExperiment.uuid(fromManifest: manifest))
        var delete = URLRequest(url: URL(string: "\(local)/api/v1/user")!)
        delete.httpMethod = "DELETE"
        delete.setValue("Basic " + Data("\(uuid):nuvio-simulator-test".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (deleted, deleteResponse) = try await URLSession.shared.data(for: delete)
        XCTAssertEqual((deleteResponse as? HTTPURLResponse)?.statusCode, 200, String(decoding: deleted.prefix(300), as: UTF8.self))
        await aio.checkConfiguration()
        let restored = try XCTUnwrap(aio.manifestURL, "restored from the backup")
        XCTAssertNotEqual(restored, manifest)
        XCTAssertEqual(AIOExperiment.addonManifestURLs.map(\.absoluteString), [restored])
        let restoredStreams = try await status(restored.replacingOccurrences(of: "/manifest.json", with: "/stream/movie/tt0133093.json"))
        XCTAssertEqual(restoredStreams, 200)
        note("AIO-TEST restore: \(AIOExperiment.uuid(fromManifest: restored) ?? "?") replaces \(uuid), streams HTTP \(restoredStreams)")
        note("AIO-TEST log:\n" + aio.logLines.suffix(60).joined(separator: "\n"))
    }

    // MARK: - Helpers

    /// Printed, and written to the file in AIO_REPORT (set by the workflow as
    /// TEST_RUNNER_AIO_REPORT), because xcodebuild -quiet hides test output.
    private func note(_ text: String) {
        print(text)
        guard let path = ProcessInfo.processInfo.environment["AIO_REPORT"], !path.isEmpty else { return }
        let line = Data((text + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func status(_ url: String) async throws -> Int {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 60
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func report(_ step: String, since start: Date) {
        note("AIO-TEST \(step): \(String(format: "%.1f", Date().timeIntervalSince(start))) s, phase \(AIOExperiment.shared.phase)")
        note("AIO-TEST log so far:\n" + AIOExperiment.shared.logLines.suffix(40).joined(separator: "\n"))
    }

    /// The starter template from the installed version.
    private func configuration() throws -> Data {
        let home = try XCTUnwrap(AIOExperiment.versionsHome)
        let versions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("versions.json"))) as? [String: Any])
        let current = try XCTUnwrap(versions["current"] as? String)
        let template = home
            .appendingPathComponent(current)
            .appendingPathComponent("resources/templates/debrid-starter.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: template)) as? [String: Any])
        var config = try XCTUnwrap(object["config"] as? [String: Any])
        let presets = (config["presets"] as? [[String: Any]]) ?? []
        config["presets"] = presets.filter { $0["type"] as? String == "torrentio" }
        config["tmdbApiKey"] = nil
        config["tmdbAccessToken"] = nil
        for key in ["titleMatching", "yearMatching", "digitalReleaseFilter"] {
            if var feature = config[key] as? [String: Any] {
                feature["enabled"] = false
                config[key] = feature
            }
        }
        return try JSONSerialization.data(withJSONObject: ["config": config, "password": "nuvio-simulator-test"])
    }
}
