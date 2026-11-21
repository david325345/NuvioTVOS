import Foundation

/// Decoded articles of the playing Usenet stream on disk, one file per article in Caches, so the
/// read-ahead can reach minutes past what fits in memory and a seek into what was already
/// downloaded doesn't download it again. Only one stream plays at a time: a new one clears
/// what an earlier one left (also after the app was closed mid-stream), and stopping the
/// stream deletes its folder.
actor UsenetDiskStore {
    static let folderName = "UsenetReadAhead"

    nonisolated let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// A fresh folder for a stream under `root` (Caches/UsenetReadAhead by default).
    static func make(root: URL? = nil) -> UsenetDiskStore? {
        let manager = FileManager.default
        guard let base = root ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true) else { return nil }
        try? manager.removeItem(at: base)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return UsenetDiskStore(directory: directory)
    }

    /// False when the article couldn't be written (no room left, folder gone).
    func write(_ index: Int, _ data: Data) -> Bool {
        (try? data.write(to: url(of: index))) != nil
    }

    /// Nil when the file is gone (the system may clear Caches while the app isn't running).
    func read(_ index: Int) -> Data? {
        try? Data(contentsOf: url(of: index))
    }

    func remove(_ indices: [Int]) {
        for index in indices { try? FileManager.default.removeItem(at: url(of: index)) }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(of index: Int) -> URL {
        directory.appendingPathComponent("\(index).art")
    }
}

/// The disk read-ahead of a stream (Settings → Usenet → Read Ahead on Disk): where its
/// articles go and how much of the disk they may use, most of it for reading ahead and the
/// rest for what was played.
struct UsenetDiskReadAhead: Sendable {
    let store: UsenetDiskStore
    let budgetBytes: Int64

    /// The largest size the setting offers.
    static let maxBytes: Int64 = 8 << 30
    /// Below this much room it isn't worth it: memory only.
    static let minBytes: Int64 = 256 << 20
    /// The share of the budget for reading ahead; the rest keeps what was played for seeking back.
    static let aheadShare = 0.8

    /// For the chosen size (nil: off); nil when it is off or the disk lacks room (keeps the
    /// free space the playback disk cache keeps).
    static func make(sizeBytes: Int64?, root: URL? = nil, freeSpace: Int64? = nil) -> UsenetDiskReadAhead? {
        guard let sizeBytes, sizeBytes > 0, let store = UsenetDiskStore.make(root: root) else { return nil }
        let free = freeSpace ?? PlaybackStreamDiskCache.volumeFreeSpace(at: store.directory)
        let budget = budgetBytes(size: sizeBytes, freeSpace: free)
        guard budget >= minBytes else {
            try? FileManager.default.removeItem(at: store.directory)
            return nil
        }
        return UsenetDiskReadAhead(store: store, budgetBytes: budget)
    }

    /// What a stream may use of `size` with `freeSpace` left on the disk (-1: unknown).
    static func budgetBytes(size: Int64, freeSpace: Int64) -> Int64 {
        let size = min(size, maxBytes)
        guard freeSpace >= 0 else { return size }
        return min(size, freeSpace - PlaybackStreamDiskCache.defaultFreeSpaceReserveBytes)
    }
}
