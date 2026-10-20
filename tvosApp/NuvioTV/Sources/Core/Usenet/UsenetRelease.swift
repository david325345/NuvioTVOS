import Foundation
import CryptoKit

/// One stretch of the played file: `length` bytes from `offset` inside volume `volume`.
struct UsenetExtent: Equatable, Sendable {
    var volume: Int
    var offset: Int64
    var length: Int64
}

/// What a stream session plays: the NZB files it reads articles from
/// (volumes) and where the played file's bytes sit in them. A plain video is
/// one volume and one extent; a stored RAR set is one extent per volume.
struct UsenetStreamSource: Sendable {
    enum Kind: String, Sendable {
        case plain
        case split
        case rar
    }

    var name: String
    var kind: Kind
    var volumes: [UsenetFile]
    var extents: [UsenetExtent]
    /// Decoded first article of each volume (it gives the volume's layout).
    var firstArticles: [UsenetYEncSegment]

    var totalSize: Int64 { extents.reduce(0) { $0 + $1.length } }

    /// Where each extent starts in the played file.
    var extentStarts: [Int64] {
        var starts: [Int64] = []
        var running: Int64 = 0
        for extent in extents {
            starts.append(running)
            running += extent.length
        }
        return starts
    }

    /// The extent holding `offset` and the matching offset inside its volume.
    static func locate(_ offset: Int64, extents: [UsenetExtent], starts: [Int64]) -> (extent: Int, volumeOffset: Int64)? {
        guard offset >= 0, !extents.isEmpty else { return nil }
        var low = 0
        var high = extents.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        guard offset < starts[low] + extents[low].length else { return nil }
        return (low, extents[low].offset + (offset - starts[low]))
    }
}

/// How an NZB file is treated, judged from its (possibly restored) name.
enum UsenetFileRole: Equatable, Sendable {
    case video
    case rar
    /// A raw split of a video (`movie.mkv.001`, `.002`, …).
    case split
    case par2
    /// An archive format that can't be streamed (7z, zip, iso).
    case unsupportedArchive
    case sidecar
    /// No telling from the name: obfuscated, or an extension nobody uses.
    case unknown
}

/// A file the user could mean to play.
struct UsenetPlayableEntry: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case plain(Int)
        case split([Int])
        case rar([Int])
    }

    var name: String
    var source: Source
    /// Encoded bytes on Usenet, for "largest wins".
    var size: Int
    /// Position of its first file in the NZB, for `fileIdx`.
    var order: Int
}

/// Turns an NZB into a stream source: works out which files are what (also
/// for obfuscated releases), picks the video and maps RAR volumes.
struct UsenetReleaseResolver {
    let nzb: UsenetNZB
    let pool: UsenetConnectionPool
    let mustInclude: String?
    let fileIdx: Int?

    /// More files than this to identify means a broken or abusive NZB.
    private static let maxIdentified = 400

    func resolve() async throws -> UsenetStreamSource {
        let files = nzb.files
        var names = files.map(\.name)
        var roles = names.map(Self.role(ofName:))
        var heads: [Int: UsenetYEncSegment] = [:]
        var obfuscatedRar = Set<Int>()

        // 1. Obfuscated files: their first article tells what they are. Only
        //    worth it when the named files aren't already the bulk of the release.
        let unknown = files.indices.filter { roles[$0] == .unknown && !files[$0].segments.isEmpty }
        let namedBytes = files.indices.filter { [UsenetFileRole.video, .rar, .split].contains(roles[$0]) }
            .reduce(0) { $0 + files[$1].encodedBytes }
        let unknownBytes = unknown.reduce(0) { $0 + files[$1].encodedBytes }
        if !unknown.isEmpty, namedBytes == 0 || unknownBytes > namedBytes {
            guard unknown.count <= Self.maxIdentified else { throw UsenetError.noPlayableFile }
            let fetched = try await fetchHeads(unknown)
            heads.merge(fetched) { current, _ in current }
            let restored = try await par2Names(roles: roles, heads: &heads)
            for index in unknown {
                guard let head = heads[index] else { continue }
                if head.fileOffset == 0, let name = restored[UsenetPar2.hash16k(head.data)] {
                    names[index] = name
                    roles[index] = Self.role(ofName: name)
                    usenetLog.notice("usenet: restored \(name, privacy: .public) from PAR2")
                    continue
                }
                if let name = head.header.name, Self.role(ofName: name) != .unknown {
                    names[index] = name
                    roles[index] = Self.role(ofName: name)
                    continue
                }
                switch UsenetSniff.kind(of: head.data) {
                case .video(let ext):
                    names[index] = "\(names[index]).\(ext)"
                    roles[index] = .video
                case .rar:
                    roles[index] = .rar
                    obfuscatedRar.insert(index)
                case .par2:
                    roles[index] = .par2
                case .sevenZip, .zip:
                    roles[index] = .unsupportedArchive
                case .unknown:
                    break
                }
            }
        }

        // 2. What could be played.
        var entries = Self.plainAndSplitEntries(files: files, names: names, roles: roles)
        for set in Self.rarSets(names: names, roles: roles, obfuscated: obfuscatedRar) {
            if let entry = try await rarEntry(set, files: files, heads: &heads) { entries.append(entry) }
        }
        entries.sort { $0.order < $1.order }

        guard let chosen = Self.choose(entries, mustInclude: mustInclude, fileIdx: fileIdx) else {
            if let archive = files.indices.first(where: { roles[$0] == .unsupportedArchive }) {
                throw UsenetError.archiveNotSupported(names[archive])
            }
            throw UsenetError.noPlayableFile
        }
        usenetLog.notice("usenet: playing \(chosen.name, privacy: .public)")

        // 3. Map its bytes.
        switch chosen.source {
        case .plain(let index):
            let head = try await requireHeads([index], heads: &heads)[0]
            return UsenetStreamSource(
                name: chosen.name, kind: .plain, volumes: [files[index]],
                extents: [UsenetExtent(volume: 0, offset: 0, length: Self.fileSize(head))],
                firstArticles: [head]
            )
        case .split(let indices):
            let volumeHeads = try await requireHeads(indices, heads: &heads)
            let extents = volumeHeads.enumerated().map {
                UsenetExtent(volume: $0.offset, offset: 0, length: Self.fileSize($0.element))
            }
            return UsenetStreamSource(
                name: chosen.name, kind: .split, volumes: indices.map { files[$0] },
                extents: extents, firstArticles: volumeHeads
            )
        case .rar(let indices):
            let volumeHeads = try await requireHeads(indices, heads: &heads)
            var parsed: [(index: Int, head: UsenetYEncSegment, volume: UsenetRarVolume)] = []
            for (index, head) in zip(indices, volumeHeads) {
                guard let volume = UsenetRar.parseVolume(head.data) else { throw UsenetError.releaseIncomplete }
                parsed.append((index, head, volume))
            }
            if indices.allSatisfy(obfuscatedRar.contains) {
                parsed = Self.orderObfuscated(parsed)
            }
            let extents = try Self.rarExtents(parsed.map { $0.volume }, innerName: chosen.name)
            let used = Set(extents.map(\.volume))
            let kept = parsed.indices.filter(used.contains)
            let remap = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
            return UsenetStreamSource(
                name: chosen.name, kind: .rar,
                volumes: kept.map { files[parsed[$0].index] },
                extents: extents.map { UsenetExtent(volume: remap[$0.volume]!, offset: $0.offset, length: $0.length) },
                firstArticles: kept.map { parsed[$0].head }
            )
        }
    }

    // MARK: - Names and roles

    static let sidecarExtensions: Set<String> = [
        "sfv", "nfo", "nzb", "srr", "srs", "jpg", "jpeg", "png", "txt", "url", "md5", "sha1", "db",
        "srt", "ass", "ssa", "sub", "idx", "sup", "vtt", "exe", "lnk", "html", "htm",
    ]

    static func role(ofName name: String) -> UsenetFileRole {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if UsenetFile.videoExtensions.contains(ext) { return .video }
        if ext == "par2" { return .par2 }
        if ext == "rar" { return .rar }
        if ext.count == 3, ext.hasPrefix("r"), Int(ext.dropFirst()) != nil { return .rar }
        if ext.count == 3, Int(ext) != nil {
            let inner = ((lower as NSString).deletingPathExtension as NSString).pathExtension
            if UsenetFile.videoExtensions.contains(inner) { return .split }
            if ["7z", "zip"].contains(inner) { return .unsupportedArchive }
            if inner == "rar" { return .rar }
            return .unknown
        }
        if ["7z", "zip", "iso", "img"].contains(ext) { return .unsupportedArchive }
        if sidecarExtensions.contains(ext) { return .sidecar }
        return .unknown
    }

    /// The set a RAR volume belongs to and its place in it: `x.part03.rar`
    /// → ("x", 3); `x.rar` → ("x", 0); `x.r00` → ("x", 1); `x.rar.001` → ("x", 1).
    static func rarVolumeKey(_ name: String) -> (set: String, number: Int)? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        let base = (lower as NSString).deletingPathExtension
        if ext == "rar" {
            let partExt = (base as NSString).pathExtension
            if partExt.hasPrefix("part"), let number = Int(partExt.dropFirst(4)) {
                return ((base as NSString).deletingPathExtension, number)
            }
            return (base, 0)
        }
        if ext.count == 3, ext.hasPrefix("r"), let number = Int(ext.dropFirst()) {
            return (base, number + 1)
        }
        if ext.count == 3, let number = Int(ext), (base as NSString).pathExtension == "rar" {
            return ((base as NSString).deletingPathExtension, number)
        }
        return nil
    }

    static func plainAndSplitEntries(files: [UsenetFile], names: [String], roles: [UsenetFileRole]) -> [UsenetPlayableEntry] {
        var entries: [UsenetPlayableEntry] = []
        var splits: [String: [(index: Int, number: Int)]] = [:]
        for index in files.indices {
            switch roles[index] {
            case .video:
                entries.append(UsenetPlayableEntry(name: names[index], source: .plain(index), size: files[index].encodedBytes, order: index))
            case .split:
                let base = (names[index] as NSString).deletingPathExtension
                let number = Int((names[index] as NSString).pathExtension) ?? 0
                splits[base, default: []].append((index, number))
            default:
                break
            }
        }
        for (base, parts) in splits {
            let ordered = parts.sorted { $0.number < $1.number }.map { $0.index }
            entries.append(UsenetPlayableEntry(
                name: base, source: .split(ordered),
                size: ordered.reduce(0) { $0 + files[$1].encodedBytes },
                order: ordered.min() ?? 0
            ))
        }
        return entries
    }

    /// RAR volumes grouped into sets, each in volume order. Obfuscated
    /// volumes (recognised only by their bytes) form one set in NZB order
    /// until their headers are read.
    static func rarSets(names: [String], roles: [UsenetFileRole], obfuscated: Set<Int>) -> [[Int]] {
        var sets: [String: [(index: Int, number: Int)]] = [:]
        var anonymous: [Int] = []
        for index in names.indices where roles[index] == .rar {
            if obfuscated.contains(index) {
                anonymous.append(index)
            } else if let key = rarVolumeKey(names[index]) {
                sets[key.set, default: []].append((index, key.number))
            } else {
                anonymous.append(index)
            }
        }
        var result = sets.values.map { $0.sorted { $0.number < $1.number }.map { $0.index } }
        if !anonymous.isEmpty { result.append(anonymous) }
        return result.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }

    /// Volume order for obfuscated RAR sets: RAR 5 numbers its volumes, RAR 4
    /// only flags the first one, so the rest keep their NZB order.
    static func orderObfuscated<T>(_ volumes: [(index: Int, head: T, volume: UsenetRarVolume)]) -> [(index: Int, head: T, volume: UsenetRarVolume)] {
        if volumes.allSatisfy({ $0.volume.volumeNumber != nil }) {
            return volumes.sorted { ($0.volume.volumeNumber ?? 0) < ($1.volume.volumeNumber ?? 0) }
        }
        guard let first = volumes.firstIndex(where: { $0.volume.isFirstVolume == true }), first > 0 else { return volumes }
        var ordered = volumes
        let head = ordered.remove(at: first)
        ordered.insert(head, at: 0)
        return ordered
    }

    /// Where a stored file's bytes sit across the volumes of its set.
    static func rarExtents(_ volumes: [UsenetRarVolume], innerName: String) throws -> [UsenetExtent] {
        guard let firstVolume = volumes.first else { throw UsenetError.noPlayableFile }
        if volumes.contains(where: \.headersEncrypted) { throw UsenetError.archiveEncrypted }
        guard let firstEntry = firstVolume.entries.first(where: { $0.name == innerName }) else {
            throw UsenetError.noPlayableFile
        }
        if firstEntry.isEncrypted { throw UsenetError.archiveEncrypted }
        guard firstEntry.isStored else { throw UsenetError.archiveCompressed(innerName) }

        var extents = [UsenetExtent(volume: 0, offset: firstEntry.dataOffset, length: firstEntry.packedSize)]
        var continues = firstEntry.continuesInNext
        var volume = 1
        while continues, volume < volumes.count {
            guard let part = volumes[volume].entries.first(where: { $0.name == innerName && $0.continuesFromPrevious }) else {
                throw UsenetError.releaseIncomplete
            }
            if part.isEncrypted { throw UsenetError.archiveEncrypted }
            extents.append(UsenetExtent(volume: volume, offset: part.dataOffset, length: part.packedSize))
            continues = part.continuesInNext
            volume += 1
        }
        let total = extents.reduce(0) { $0 + $1.length }
        if continues || (firstEntry.unpackedSize > 0 && total < firstEntry.unpackedSize) {
            // Volumes are missing from the NZB.
            throw UsenetError.releaseIncomplete
        }
        return extents.filter { $0.length > 0 }
    }

    /// `fileMustInclude` (a regex, case-insensitive) wins, then `fileIdx`
    /// among the entries in NZB order, then the largest entry.
    static func choose(_ entries: [UsenetPlayableEntry], mustInclude: String?, fileIdx: Int?) -> UsenetPlayableEntry? {
        let candidates = entries.filter { !isSample($0.name) || entries.count == 1 }
        if let mustInclude, !mustInclude.isEmpty {
            let regex = try? NSRegularExpression(pattern: mustInclude, options: [.caseInsensitive])
            let matches: (String) -> Bool = { name in
                if let regex {
                    return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                }
                return name.localizedCaseInsensitiveContains(mustInclude)
            }
            if let match = entries.first(where: { matches($0.name) }) { return match }
        }
        if let fileIdx, entries.indices.contains(fileIdx) { return entries[fileIdx] }
        return (candidates.isEmpty ? entries : candidates).max { $0.size < $1.size }
    }

    private static func isSample(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("sample") || lower.contains("trailer")
    }

    private static func fileSize(_ head: UsenetYEncSegment) -> Int64 {
        Int64(head.header.size ?? head.data.count)
    }

    // MARK: - Fetching first articles

    private func rarEntry(_ set: [Int], files: [UsenetFile], heads: inout [Int: UsenetYEncSegment]) async throws -> UsenetPlayableEntry? {
        guard let first = set.first else { return nil }
        // Obfuscated sets: find the first volume among them.
        var leader = first
        if heads[first] != nil, set.count > 1 {
            let volumes = set.compactMap { index in
                heads[index].map(\.data).flatMap(UsenetRar.parseVolume).map { (index, $0) }
            }
            if let firstVolume = volumes.first(where: { $0.1.isFirstVolume == true || $0.1.volumeNumber == 0 }) {
                leader = firstVolume.0
            }
        }
        guard let head = try await requireHeads([leader], heads: &heads).first,
              let volume = UsenetRar.parseVolume(head.data) else { return nil }
        let videos = volume.entries.filter {
            !$0.isDirectory && UsenetFile.videoExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }
        guard let inner = videos.max(by: { $0.unpackedSize < $1.unpackedSize }) else { return nil }
        return UsenetPlayableEntry(
            name: inner.name,
            source: .rar(set),
            size: set.reduce(0) { $0 + files[$1].encodedBytes },
            order: set.min() ?? first
        )
    }

    private func requireHeads(_ indices: [Int], heads: inout [Int: UsenetYEncSegment]) async throws -> [UsenetYEncSegment] {
        let missing = indices.filter { heads[$0] == nil }
        if !missing.isEmpty {
            let fetched = try await fetchHeads(missing)
            heads.merge(fetched) { current, _ in current }
        }
        return try indices.map { index in
            guard let head = heads[index] else {
                throw indices.count == 1 ? UsenetError.firstSegmentUnavailable : UsenetError.releaseIncomplete
            }
            return head
        }
    }

    /// Decoded first articles of the given files, fetched in parallel.
    private func fetchHeads(_ indices: [Int]) async throws -> [Int: UsenetYEncSegment] {
        let files = nzb.files
        let pool = self.pool
        let limit = max(2, pool.totalConnections)
        return try await withThrowingTaskGroup(of: (Int, UsenetYEncSegment?).self, returning: [Int: UsenetYEncSegment].self) { group in
            var result: [Int: UsenetYEncSegment] = [:]
            var pending = indices.makeIterator()
            for _ in 0..<limit {
                guard let index = pending.next() else { break }
                group.addTask { (index, try await Self.head(of: files[index], pool: pool)) }
            }
            while let finished = try await group.next() {
                if let head = finished.1 { result[finished.0] = head }
                if let index = pending.next() {
                    group.addTask { (index, try await Self.head(of: files[index], pool: pool)) }
                }
            }
            return result
        }
    }

    private static func head(of file: UsenetFile, pool: UsenetConnectionPool) async throws -> UsenetYEncSegment? {
        guard let first = file.segments.first,
              case .body(let body) = try await pool.fetch(messageID: first.messageID) else { return nil }
        return try? await Task.detached(priority: .userInitiated) {
            try UsenetYEnc.decode(body: body)
        }.value
    }

    /// Real names by 16 KiB hash, from the smallest PAR2 file in the release.
    private func par2Names(roles: [UsenetFileRole], heads: inout [Int: UsenetYEncSegment]) async throws -> [Data: String] {
        let files = nzb.files
        var candidates = files.indices.filter { roles[$0] == .par2 }
        candidates += heads.filter { UsenetPar2.isPar2($0.value.data) }.map(\.key)
        guard let index = Set(candidates).min(by: { files[$0].encodedBytes < files[$1].encodedBytes }),
              files[index].segments.count <= 8 else { return [:] }
        // The index PAR2 is small: read all of it.
        var data = Data()
        for segment in files[index].segments {
            if segment.number == files[index].segments.first?.number, let head = heads[index] {
                data.append(head.data)
                continue
            }
            guard case .body(let body) = try await pool.fetch(messageID: segment.messageID),
                  let decoded = try? UsenetYEnc.decode(body: body) else { break }
            data.append(decoded.data)
        }
        var names: [Data: String] = [:]
        for description in UsenetPar2.fileDescriptions(in: data) {
            names[description.hash16k] = description.name
        }
        return names
    }
}

// MARK: - Availability check

/// Asks the servers (STAT, no download) whether a sample of the release's
/// articles still exists, so an incomplete upload fails in a second instead
/// of half an hour into the film.
enum UsenetHealthCheck {
    static let sampleCount = 12

    struct Result: Equatable {
        var checked: Int
        var missing: Int
        var tailMissing: Bool
    }

    static func samples(for source: UsenetStreamSource) -> [String] {
        // Every article except each volume's first (already downloaded).
        let ids = source.volumes.flatMap { $0.segments.dropFirst().map(\.messageID) }
        guard !ids.isEmpty else { return [] }
        let count = min(sampleCount, ids.count)
        var picked: [String] = []
        for step in 0..<count {
            let position = count == 1 ? ids.count - 1 : step * (ids.count - 1) / (count - 1)
            picked.append(ids[position])
        }
        return picked
    }

    static func check(_ source: UsenetStreamSource, pool: UsenetConnectionPool) async throws -> Result {
        let ids = samples(for: source)
        guard let tail = ids.last else { return Result(checked: 0, missing: 0, tailMissing: false) }
        let found = try await withThrowingTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for id in ids {
                group.addTask { (id, try await pool.exists(messageID: id)) }
            }
            var results: [String: Bool] = [:]
            for try await answer in group { results[answer.0] = answer.1 }
            return results
        }
        let missing = found.values.filter { !$0 }.count
        return Result(checked: ids.count, missing: missing, tailMissing: found[tail] == false)
    }

    /// One missing sample is a glitch the player skips; more, or a missing
    /// end of file, means a broken release.
    static func isPlayable(_ result: Result) -> Bool {
        !result.tailMissing && result.missing < 2
    }
}

// MARK: - NZB cache

/// Downloaded NZBs on disk for 14 days (256 MB at most), so resuming or
/// replaying doesn't wait for the indexer.
enum UsenetNZBCache {
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    static let maxBytes = 256 << 20

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsenetNZB", isDirectory: true)
    }

    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func cached(_ url: URL) -> Data? {
        let file = directory.appendingPathComponent(key(for: url))
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge,
              let data = try? Data(contentsOf: file) else { return nil }
        return data
    }

    static func store(_ data: Data, for url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key(for: url)), options: .atomic)
        prune()
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key(for: url)))
    }

    static func prune() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        let now = Date()
        for entry in entries where now.timeIntervalSince(entry.date) >= maxAge {
            try? fileManager.removeItem(at: entry.url)
        }
        entries.removeAll { now.timeIntervalSince($0.date) >= maxAge }
        entries.sort { $0.date < $1.date }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > maxBytes {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
