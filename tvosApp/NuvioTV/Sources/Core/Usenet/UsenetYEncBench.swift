import Foundation
import os

// Test build only (fork), never part of a PR: measures Nuvio's yEnc decoding and CRC32 against
// node-yencode (NEON decoder, ARMv8 CRC/PMULL) and the system zlib's CRC32, on every article a
// stream decodes, and writes what it found to the Usenet log (Settings → Usenet → Test Log).
// Playback keeps using what Nuvio's own decoder made; node-yencode's result is only compared.

/// What `UsenetYEnc.decode(body:)` cost against node-yencode, in windows of articles.
enum UsenetYEncBench {
    /// A summary every this many articles, or after `windowSeconds` with at least
    /// `minimumArticles` of them.
    static let windowArticles = 400
    static let windowSeconds: UInt64 = 60
    static let minimumArticles = 20

    private struct Totals {
        var articles = 0
        var bytes = 0
        var swiftDecode: UInt64 = 0
        var swiftCRC: UInt64 = 0
        var simdDecode: UInt64 = 0
        var simdCRC: UInt64 = 0
        var zlibCRC: UInt64 = 0
        var mismatches = 0

        mutating func add(_ other: Totals) {
            articles += other.articles
            bytes += other.bytes
            swiftDecode += other.swiftDecode
            swiftCRC += other.swiftCRC
            simdDecode += other.simdDecode
            simdCRC += other.simdCRC
            zlibCRC += other.zlibCRC
            mismatches += other.mismatches
        }
    }

    private struct State {
        var window = Totals()
        var windowStart: UInt64 = 0
        var lastArticle: UInt64 = 0
        var total = Totals()
        var firstMismatchLogged = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// node-yencode picks its decoder and CRC for this CPU once, and says which.
    private static let ready: Bool = {
        nuvio_yenc_test_init()
        let decoder = nuvio_yenc_test_decoder_isa() & 0x1000 != 0 ? "NEON" : "generic (no NEON)"
        let crcISA = nuvio_yenc_test_crc_isa()
        let crc: String
        switch (crcISA & 0x8 != 0, crcISA & 0x40 != 0) {
        case (true, true): crc = "ARMv8 CRC + PMULL"
        case (true, false): crc = "ARMv8 CRC"
        default: crc = "generic table (no CRC instructions)"
        }
        usenetLog.notice("yenc-test: node-yencode ready, decoder \(decoder), CRC \(crc)")
        return true
    }()

    /// One article: `decoded` and `crc` are what Nuvio's decoder made in `swiftDecodeNs` and
    /// `swiftCRCNs`; node-yencode decodes and checksums the same body here.
    static func measure(body: Data, decoded: Data, crc: UInt32, swiftDecodeNs: UInt64, swiftCRCNs: UInt64) {
        _ = ready
        let count = body.count
        guard count > 0 else { return }
        var out = [UInt8](repeating: 0, count: count + 64)

        var length = 0
        var simdDecode: UInt64 = 0
        var simdCRC: UInt64 = 0
        var zlibCRC: UInt64 = 0
        var simdValue: UInt32 = 0
        var zlibValue: UInt32 = 0
        body.withUnsafeBytes { raw in
            guard let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            out.withUnsafeMutableBufferPointer { buffer in
                guard let target = buffer.baseAddress else { return }
                let start = now()
                length = nuvio_yenc_test_decode(source, count, target)
                let decodedAt = now()
                simdValue = nuvio_yenc_test_crc32(target, length)
                let checkedAt = now()
                zlibValue = nuvio_yenc_test_zlib_crc32(target, length)
                let zlibAt = now()
                simdDecode = decodedAt &- start
                simdCRC = checkedAt &- decodedAt
                zlibCRC = zlibAt &- checkedAt
            }
        }

        let sameBytes = length == decoded.count && decoded.withUnsafeBytes { raw in
            out.withUnsafeBufferPointer { buffer in
                guard let mine = raw.baseAddress, let theirs = buffer.baseAddress else { return length == 0 }
                return memcmp(mine, theirs, length) == 0
            }
        }
        let same = sameBytes && simdValue == crc && zlibValue == crc

        let article = Totals(
            articles: 1,
            bytes: decoded.count,
            swiftDecode: swiftDecodeNs,
            swiftCRC: swiftCRCNs,
            simdDecode: simdDecode,
            simdCRC: simdCRC,
            zlibCRC: zlibCRC,
            mismatches: same ? 0 : 1
        )
        let at = now()
        let (summary, logMismatch) = state.withLock { state -> (String?, Bool) in
            if state.window.articles == 0 { state.windowStart = at }
            state.window.add(article)
            state.lastArticle = at
            var logMismatch = false
            if !same, !state.firstMismatchLogged {
                state.firstMismatchLogged = true
                logMismatch = true
            }
            let elapsed = at &- state.windowStart
            let due = state.window.articles >= windowArticles
                || (elapsed >= windowSeconds * 1_000_000_000 && state.window.articles >= minimumArticles)
            guard due else { return (nil, logMismatch) }
            return (closeWindow(&state, endedAt: at), logMismatch)
        }
        if logMismatch {
            usenetLog.error("yenc-test: node-yencode decoded an article differently: \(length) bytes against \(decoded.count), CRC \(hex(simdValue)) and zlib \(hex(zlibValue)) against \(hex(crc)) (only the first difference is logged)")
        }
        if let summary { usenetLog.notice("\(summary)") }
    }

    /// When a stream stops: what is left of the window, and everything since Nuvio started.
    static func flush() {
        let lines: [String] = state.withLock { state in
            var lines: [String] = []
            if state.window.articles > 0, let window = closeWindow(&state, endedAt: state.lastArticle) {
                lines.append(window)
            }
            let total = state.total
            if total.articles > 0 {
                let swift = total.swiftDecode + total.swiftCRC
                let simd = total.simdDecode + total.simdCRC
                var line = "yenc-test: since Nuvio started \(total.articles) articles, \(megabytes(total.bytes)): "
                line += "Nuvio \(seconds(swift)) (decode \(rate(total.bytes, total.swiftDecode)), "
                line += "CRC \(rate(total.bytes, total.swiftCRC))), "
                line += "node-yencode \(seconds(simd)) (decode \(rate(total.bytes, total.simdDecode)), "
                line += "CRC \(rate(total.bytes, total.simdCRC))), \(times(swift, simd)) faster, "
                line += "zlib CRC \(rate(total.bytes, total.zlibCRC)), "
                line += "\(total.articles - total.mismatches)/\(total.articles) the same"
                lines.append(line)
            }
            return lines
        }
        for line in lines { usenetLog.notice("\(line)") }
    }

    /// The window's summary line; adds it to the totals and starts a new window.
    private static func closeWindow(_ state: inout State, endedAt: UInt64) -> String? {
        let window = state.window
        state.total.add(window)
        state.window = Totals()
        guard window.articles > 0 else { return nil }
        // From the window's first article to its last: the share of one core is the time spent
        // decoding over that (above 100 % when several articles were decoded at once).
        let wall = max(endedAt &- state.windowStart, 1)
        let swift = window.swiftDecode + window.swiftCRC
        let simd = window.simdDecode + window.simdCRC
        var line = "yenc-test: \(window.articles) articles, \(megabytes(window.bytes)) in \(seconds(wall)) | "
        line += "Nuvio: decode \(rate(window.bytes, window.swiftDecode)), "
        line += "CRC \(rate(window.bytes, window.swiftCRC)), \(percent(swift, wall)) of a core | "
        line += "node-yencode: decode \(rate(window.bytes, window.simdDecode)), "
        line += "CRC \(rate(window.bytes, window.simdCRC)), \(percent(simd, wall)) of a core, "
        line += "\(times(swift, simd)) faster | zlib CRC \(rate(window.bytes, window.zlibCRC)) | "
        line += "\(window.articles - window.mismatches)/\(window.articles) the same"
        return line
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func rate(_ bytes: Int, _ nanoseconds: UInt64) -> String {
        guard nanoseconds > 0 else { return "–" }
        let megabytesPerSecond = Double(bytes) / Double(nanoseconds) * 1000
        return megabytesPerSecond >= 1000
            ? String(format: "%.1f GB/s", megabytesPerSecond / 1000)
            : String(format: "%.0f MB/s", megabytesPerSecond)
    }

    private static func megabytes(_ bytes: Int) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
            : String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }

    private static func seconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.2f s", Double(nanoseconds) / 1_000_000_000)
    }

    private static func percent(_ busy: UInt64, _ wall: UInt64) -> String {
        String(format: "%.1f %%", Double(busy) / Double(max(wall, 1)) * 100)
    }

    private static func times(_ swift: UInt64, _ simd: UInt64) -> String {
        guard simd > 0 else { return "–" }
        return String(format: "%.1f×", Double(swift) / Double(simd))
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "%08x", value)
    }
}
