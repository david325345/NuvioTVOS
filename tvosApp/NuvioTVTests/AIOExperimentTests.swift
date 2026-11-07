//
//  AIOExperimentTests.swift
//  NuvioTVTests
//
//  Fork branch aio-node only: starts the original AIOStreams in Node.js inside
//  the app on the tvOS simulator, saves a configuration like its page does and
//  asks the resulting addon for streams. Prints the timings and the log.
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

        try await waitUntil(seconds: 300) {
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

        try await waitUntil(seconds: 10) { aio.manifestURL != nil }
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
            print("AIO-TEST stream request \(attempt): \(streams.count) streams in \(Int(Date().timeIntervalSince(begin) * 1000)) ms; first: \(String(describing: streams.first?["name"] ?? "-"))")
        }
        print("AIO-TEST ready in \(aio.startupSeconds ?? -1) s · Node \(aio.nodeMemoryMB ?? -1) MB · app \(aio.appMemoryMB ?? -1) MB · \(aio.packageVersion)")
        print("AIO-TEST log:\n" + aio.logLines.suffix(60).joined(separator: "\n"))
    }

    // MARK: - Helpers

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
        print("AIO-TEST \(step): \(String(format: "%.1f", Date().timeIntervalSince(start))) s, phase \(AIOExperiment.shared.phase)")
        print("AIO-TEST log so far:\n" + AIOExperiment.shared.logLines.suffix(40).joined(separator: "\n"))
    }

    /// The starter template from the unpacked package.
    private func configuration() throws -> Data {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let packages = caches.appendingPathComponent("AIOStreams-package", isDirectory: true)
        let installed = try FileManager.default.contentsOfDirectory(atPath: packages.path).first { !$0.hasSuffix(".partial") }
        let template = packages
            .appendingPathComponent(try XCTUnwrap(installed))
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
