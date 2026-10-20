import Foundation
import Combine

/// Starts and stops the one active Usenet stream, the way
/// `TorrentEngineManager` does for torrents.
@MainActor
final class UsenetEngineManager: ObservableObject {
    static let shared = UsenetEngineManager()

    @Published private(set) var isStreaming = false
    @Published private(set) var lastError: String?

    private var session: UsenetStreamSession?
    private var server: UsenetStreamServer?
    private(set) var activeStreamURL: URL?
    private var generation = 0

    private init() {}

    /// Downloads and parses the NZB, connects to the servers, decodes the first
    /// article and returns the local playback URL.
    func startStream(_ spec: UsenetStreamSpec) async throws -> URL {
        generation &+= 1
        let current = generation
        await stopCurrent()
        lastError = nil

        let servers = UsenetSettings.servers(for: spec)
        guard !servers.isEmpty else {
            lastError = UsenetError.noServers.localizedDescription
            throw UsenetError.noServers
        }

        do {
            let nzb = try await Self.downloadNZB(spec.nzbURL)
            let file = try nzb.playableFile(mustInclude: spec.fileMustInclude, fileIdx: spec.fileIdx)
            usenetLog.notice("usenet: \(file.name, privacy: .public) — \(file.segments.count) articles, \(servers.count) server(s)")
            let pool = UsenetConnectionPool(servers: servers)
            let session = UsenetStreamSession(file: file, pool: pool, profile: UsenetSettings.profile())
            do {
                try await session.prepare()
            } catch {
                await session.stop()
                throw error
            }
            guard current == generation, !Task.isCancelled else {
                await session.stop()
                throw CancellationError()
            }
            let server = UsenetStreamServer(session: session, fileName: file.name, fileLength: await session.totalSize)
            let url = try await server.start()
            self.session = session
            self.server = server
            self.activeStreamURL = url
            isStreaming = true
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            usenetLog.error("usenet: start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// A delayed player exit only stops its own stream, never a newer one.
    func stopActiveStream(for sourceURL: URL) async {
        guard activeStreamURL == sourceURL else { return }
        generation &+= 1
        await stopCurrent()
    }

    func stopAll() async {
        generation &+= 1
        await stopCurrent()
    }

    private func stopCurrent() async {
        let session = self.session
        let server = self.server
        self.session = nil
        self.server = nil
        activeStreamURL = nil
        isStreaming = false
        await server?.stop()
        await session?.stop()
    }

    nonisolated static func downloadNZB(_ url: URL) async throws -> UsenetNZB {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/x-nzb, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UsenetError.nzbDownloadFailed(status) }
        return try UsenetNZB.parse(data)
    }
}
