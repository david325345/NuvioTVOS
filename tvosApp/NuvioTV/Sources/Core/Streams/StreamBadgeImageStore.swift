import CryptoKit
import Foundation
import UIKit
import QuartzCore

/// The images of imported stream badges, kept on this Apple TV.
///
/// A badge pack stores only links to its images. Each badge used to load its image with
/// `AsyncImage` every time a stream card came on screen, showing a spinner meanwhile, and only
/// the system's HTTP cache (when the server allowed it) spared the download. Now the images are
/// downloaded when a pack is saved (and again after launch for any that are missing), kept in
/// the Caches folder and in memory, and a badge shows its image at once.
final class StreamBadgeImageStore: @unchecked Sendable {
    static let shared = StreamBadgeImageStore()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL?

    init(directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("StreamBadgeImages", isDirectory: true)) {
        self.directory = directory
    }

    /// The image when it is already in memory. Never reads the disk or downloads.
    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    /// From memory, else from the Caches folder, else downloaded (and kept).
    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let pending = inFlight[key] { return pending }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> UIImage? in
                guard let self else { return nil }
                let image = await self.load(url)
                self.finish(key: key, image: image)
                return image
            }
            inFlight[key] = task
            return task
        }
        return await task.value
    }

    /// Downloads, in the background, the images of every badge in `rules` not yet on disk.
    func prefetch(_ rules: StreamBadgeRules) {
        let urls = Self.imageURLs(in: rules)
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let missing = urls.filter { !self.isOnDisk($0) }
            TestDiagnosticLog.badges("prefetch: \(missing.count) of \(urls.count) images to download, the rest kept on this Apple TV")
            guard !missing.isEmpty else { return }
            let started = CACurrentMediaTime()
            var failed: [String] = []
            for url in missing {
                if await self.image(for: url) == nil { failed.append(url.lastPathComponent) }
            }
            TestDiagnosticLog.badges(
                "prefetch done in \(Int((CACurrentMediaTime() - started) * 1_000)) ms: \(missing.count - failed.count) downloaded"
                    + (failed.isEmpty ? "" : ", \(failed.count) failed (\(failed.prefix(3).joined(separator: ", ")))")
            )
        }
    }

    // MARK: Test log

    private enum LoadSource { case disk, network, failed }
    private struct LoadTally {
        var disk = 0, network = 0, failed = 0
        var longestDisk: CFTimeInterval = 0, longestNetwork: CFTimeInterval = 0
        var failedNames: [String] = []
    }
    private var tally = LoadTally()
    private var tallyGeneration = 0

    /// Loads are summed and written as one line two seconds after the last (a stream list
    /// loads many badges at once).
    private func noteLoad(_ source: LoadSource, seconds: CFTimeInterval, url: URL) {
        let generation: Int = lock.withLock {
            switch source {
            case .disk:
                tally.disk += 1
                tally.longestDisk = max(tally.longestDisk, seconds)
            case .network:
                tally.network += 1
                tally.longestNetwork = max(tally.longestNetwork, seconds)
            case .failed:
                tally.failed += 1
                if tally.failedNames.count < 3 { tally.failedNames.append(url.lastPathComponent) }
            }
            tallyGeneration += 1
            return tallyGeneration
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let finished: LoadTally? = self.lock.withLock {
                guard self.tallyGeneration == generation else { return nil }
                defer { self.tally = LoadTally() }
                return self.tally
            }
            guard let finished else { return }
            var parts: [String] = []
            if finished.disk > 0 { parts.append("\(finished.disk) from the Apple TV (longest \(Int(finished.longestDisk * 1_000)) ms)") }
            if finished.network > 0 { parts.append("\(finished.network) downloaded (longest \(Int(finished.longestNetwork * 1_000)) ms)") }
            if finished.failed > 0 { parts.append("\(finished.failed) failed (\(finished.failedNames.joined(separator: ", ")))") }
            TestDiagnosticLog.badges("images loaded: " + parts.joined(separator: ", "))
        }
    }

    /// The badge image links in `rules`, each once.
    static func imageURLs(in rules: StreamBadgeRules) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for item in rules.imports {
            for filter in item.filters {
                let text = filter.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let url = URL(string: text), seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    /// The file a badge image is kept in: a hash of its link, so any link makes a safe name.
    static func fileName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func fileURL(for url: URL) -> URL? {
        // `data:` images carry their bytes in the link; there is nothing to keep.
        guard url.scheme?.lowercased() != "data" else { return nil }
        return directory?.appendingPathComponent(Self.fileName(for: url), isDirectory: false)
    }

    private func isOnDisk(_ url: URL) -> Bool {
        guard let file = fileURL(for: url) else { return true }
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func load(_ url: URL) async -> UIImage? {
        let started = CACurrentMediaTime()
        let file = fileURL(for: url)
        if let file, let data = try? Data(contentsOf: file), let image = Self.decode(data) {
            noteLoad(.disk, seconds: CACurrentMediaTime() - started, url: url)
            return image
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            noteLoad(.failed, seconds: 0, url: url)
            return nil
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
            noteLoad(.failed, seconds: 0, url: url)
            return nil
        }
        guard let image = Self.decode(data) else {
            noteLoad(.failed, seconds: 0, url: url)
            return nil
        }
        noteLoad(.network, seconds: CACurrentMediaTime() - started, url: url)
        if let file, let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return image
    }

    /// Decoded here, off the main thread, so drawing the badge doesn't decode it.
    private static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    private func finish(key: String, image: UIImage?) {
        if let image { memory.setObject(image, forKey: key as NSString) }
        lock.withLock { inFlight[key] = nil }
    }
}
