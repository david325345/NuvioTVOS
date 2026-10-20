import Foundation
import XCTest
@testable import NuvioTV

// MARK: - Helpers

private enum UsenetFixture {
    /// Minimal yEnc encoder, enough to round-trip through `UsenetYEnc.decode`.
    static func yEncLines(_ payload: Data, name: String, part: Int? = nil, total: Int? = nil,
                          begin: Int? = nil, fileSize: Int? = nil, lineLength: Int = 128) -> [Data] {
        var lines: [Data] = []
        var head = "=ybegin"
        if let part { head += " part=\(part)" }
        if let total { head += " total=\(total)" }
        head += " line=\(lineLength) size=\(fileSize ?? payload.count) name=\(name)"
        lines.append(Data(head.utf8))
        if let begin {
            lines.append(Data("=ypart begin=\(begin) end=\(begin + payload.count - 1)".utf8))
        }
        var line = [UInt8]()
        for byte in payload {
            let encoded = byte &+ 42
            if [0x00, 0x0A, 0x0D, 0x3D].contains(encoded) {
                line.append(0x3D)
                line.append(encoded &+ 64)
            } else {
                line.append(encoded)
            }
            if line.count >= lineLength {
                lines.append(Data(line))
                line.removeAll()
            }
        }
        if !line.isEmpty { lines.append(Data(line)) }
        let crc = String(format: "%08x", UsenetCRC32.checksum(of: payload))
        let tail = part != nil ? "=yend size=\(payload.count) part=\(part!) pcrc32=\(crc)" : "=yend size=\(payload.count) crc32=\(crc)"
        lines.append(Data(tail.utf8))
        return lines
    }

    static func nzb(_ files: [(subject: String, segments: [(id: String, bytes: Int, number: Int)])]) -> Data {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?><nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">"#
        xml += #"<head><meta type="title">Test Release</meta><meta type="password">secret</meta></head>"#
        for file in files {
            let subject = file.subject
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            xml += #"<file poster="a@b" date="0" subject="\#(subject)"><groups><group>alt.binaries.test</group></groups><segments>"#
            for segment in file.segments {
                xml += #"<segment bytes="\#(segment.bytes)" number="\#(segment.number)">\#(segment.id)</segment>"#
            }
            xml += "</segments></file>"
        }
        xml += "</nzb>"
        return Data(xml.utf8)
    }

    static func segments(_ sizes: [Int]) -> [UsenetSegment] {
        sizes.enumerated().map { UsenetSegment(messageID: "p\($0.offset)@test", bytes: $0.element, number: $0.offset + 1) }
    }
}

// MARK: - yEnc / CRC / NNTP framing

final class UsenetCoreTests: XCTestCase {
    func testCRC32KnownValue() {
        XCTAssertEqual(UsenetCRC32.checksum(of: Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testYEncRoundTripSinglePart() throws {
        let payload = Data((0..<1000).map { UInt8($0 % 256) })
        let segment = try UsenetYEnc.decode(bodyLines: UsenetFixture.yEncLines(payload, name: "movie.mkv"))
        XCTAssertEqual(segment.data, payload)
        XCTAssertEqual(segment.header.name, "movie.mkv")
        XCTAssertEqual(segment.header.size, 1000)
        XCTAssertEqual(segment.crcMatches, true)
        XCTAssertEqual(segment.fileOffset, 0)
    }

    func testYEncMultipartOffsetAndPartCRC() throws {
        let payload = Data((0..<500).map { UInt8(($0 * 7) % 256) })
        let lines = UsenetFixture.yEncLines(payload, name: "movie name.mkv", part: 3, total: 10, begin: 1001, fileSize: 5000)
        let segment = try UsenetYEnc.decode(bodyLines: lines)
        XCTAssertEqual(segment.data, payload)
        XCTAssertEqual(segment.fileOffset, 1000)
        XCTAssertEqual(segment.header.part, 3)
        XCTAssertEqual(segment.header.size, 5000)
        XCTAssertEqual(segment.header.name, "movie name.mkv")
        XCTAssertEqual(segment.crcMatches, true)
    }

    func testYEncDetectsCorruption() throws {
        var lines = UsenetFixture.yEncLines(Data(repeating: 0x41, count: 300), name: "a.mkv", part: 1, total: 1, begin: 1)
        var corrupted = [UInt8](lines[2])
        corrupted[0] = corrupted[0] &+ 1
        lines[2] = Data(corrupted)
        XCTAssertEqual(try UsenetYEnc.decode(bodyLines: lines).crcMatches, false)
    }

    func testYEncRequiresBegin() {
        XCTAssertThrowsError(try UsenetYEnc.decode(bodyLines: [Data("garbage".utf8)])) { error in
            XCTAssertEqual(error as? UsenetYEncError, .missingBeginHeader)
        }
    }

    func testStatusParsing() {
        let status = UsenetNNTPStatus(string: "281 Authentication accepted")
        XCTAssertEqual(status?.code, 281)
        XCTAssertEqual(status?.text, "Authentication accepted")
        XCTAssertTrue(status?.isSuccess == true)
        XCTAssertTrue(UsenetNNTPStatus(string: "381 more")?.isContinue == true)
        XCTAssertTrue(UsenetNNTPStatus(string: "430 No such article")?.isError == true)
        XCTAssertNil(UsenetNNTPStatus(string: "ok"))
    }

    func testDotUnstuffingAndTerminator() {
        XCTAssertEqual(UsenetNNTP.processBodyLine(Data(".".utf8)), .terminator)
        XCTAssertEqual(UsenetNNTP.processBodyLine(Data("..abc".utf8)), .content(Data(".abc".utf8)))
        XCTAssertEqual(UsenetNNTP.processBodyLine(Data("abc".utf8)), .content(Data("abc".utf8)))
        XCTAssertEqual(UsenetNNTP.command("BODY <a@b>"), Data("BODY <a@b>\r\n".utf8))
    }

    func testLineFramerKeepsPartialLines() {
        var framer = UsenetLineFramer()
        XCTAssertEqual(framer.append(Data("222 0 <a@b>\r\nfir".utf8)), [Data("222 0 <a@b>".utf8)])
        XCTAssertEqual(framer.pendingCount, 3)
        XCTAssertEqual(framer.append(Data("st\r\n.\r\n".utf8)), [Data("first".utf8), Data(".".utf8)])
        XCTAssertEqual(framer.pendingCount, 0)
    }

    func testTransientErrors() {
        XCTAssertTrue(UsenetNNTPError.timeout.isTransient)
        XCTAssertTrue(UsenetNNTPError.connectionClosed.isTransient)
        XCTAssertFalse(UsenetNNTPError.articleUnavailable(code: 430).isTransient)
        XCTAssertFalse(UsenetNNTPError.authenticationFailed(481).isTransient)
    }
}

// MARK: - NZB parsing and file choice

final class UsenetNZBTests: XCTestCase {
    private func sampleNZB() throws -> UsenetNZB {
        try UsenetNZB.parse(UsenetFixture.nzb([
            (#"[1/4] - "Show.S01E01.1080p.mkv" yEnc (1/3)"#, [("<a3@x>", 300, 3), ("a1@x", 300, 1), ("a2@x", 300, 2), ("dup@x", 300, 2)]),
            (#"[2/4] - "Show.S01E01.1080p.par2" yEnc (1/1)"#, [("p@x", 10, 1)]),
            (#"[3/4] - "Show.S01E01.sample.mkv" yEnc (1/1)"#, [("s@x", 50, 1)]),
            (#"[4/4] - "Show.S01E01.nfo" yEnc (1/1)"#, [("n@x", 5, 1)]),
        ]))
    }

    func testParseOrdersAndDedupesSegments() throws {
        let nzb = try sampleNZB()
        XCTAssertEqual(nzb.title, "Test Release")
        XCTAssertEqual(nzb.password, "secret")
        XCTAssertEqual(nzb.files.count, 4)
        let main = nzb.files[0]
        XCTAssertEqual(main.name, "Show.S01E01.1080p.mkv")
        XCTAssertEqual(main.segments.map(\.number), [1, 2, 3])
        XCTAssertEqual(main.segments.map(\.messageID), ["a1@x", "a2@x", "a3@x"])
        XCTAssertEqual(main.encodedBytes, 900)
    }

    func testPicksLargestVideoByDefault() throws {
        XCTAssertEqual(try sampleNZB().playableFile(mustInclude: nil, fileIdx: nil).name, "Show.S01E01.1080p.mkv")
    }

    func testFileMustIncludeRegexWins() throws {
        let file = try sampleNZB().playableFile(mustInclude: "(?:sample)|(?:trailer)", fileIdx: nil)
        XCTAssertEqual(file.name, "Show.S01E01.sample.mkv")
    }

    func testFileIdxAmongVideos() throws {
        XCTAssertEqual(try sampleNZB().playableFile(mustInclude: nil, fileIdx: 1).name, "Show.S01E01.sample.mkv")
        XCTAssertEqual(try sampleNZB().playableFile(mustInclude: nil, fileIdx: 9).name, "Show.S01E01.1080p.mkv")
    }

    func testArchiveReleaseIsReported() throws {
        let nzb = try UsenetNZB.parse(UsenetFixture.nzb([
            (#""Movie.part01.rar" yEnc (1/2)"#, [("r1@x", 500, 1), ("r2@x", 500, 2)]),
            (#""Movie.r00" yEnc (1/1)"#, [("r3@x", 400, 1)]),
            (#""Movie.par2" yEnc (1/1)"#, [("p@x", 10, 1)]),
        ]))
        XCTAssertTrue(nzb.files[1].isArchive)
        XCTAssertThrowsError(try nzb.playableFile(mustInclude: nil, fileIdx: nil)) { error in
            XCTAssertEqual(error as? UsenetError, .archiveNotSupported("Movie.part01.rar"))
        }
    }

    func testGzipNZB() throws {
        let gz = Data(base64Encoded: "H4sIAAAAAAAC/z1OSw7CIBS8CmFhdMMD3SmlLuoNvIA0T0ULaKHF9vQ+o3E1n8xkRtcv37ER++RiqLgSktdGh9ky8kOq+DXnxxaglCICltm6INrooTk2sJZyAxTlRp9dhywN9oZtrvjiOcS883F0KPx9/Eo2HULLlgrUigoJLx5DTn/G7JSR9pSUnIXBW+xJcHPaWw2/jPkz6sFnk4AOmDc90bFHxgAAAA==")!
        XCTAssertTrue(UsenetGzip.isGzip(gz))
        let nzb = try UsenetNZB.parse(gz)
        XCTAssertEqual(nzb.files.first?.name, "movie.mkv")
        XCTAssertEqual(nzb.files.first?.segments.first?.messageID, "a@b")
    }

    func testGarbageIsUnreadable() {
        XCTAssertThrowsError(try UsenetNZB.parse(Data("<html><body>login</body".utf8)))
    }
}

// MARK: - Byte layout

final class UsenetLayoutTests: XCTestCase {
    func testRegularLayoutIsArithmetic() {
        let layout = UsenetFileLayout(totalSize: 1000, firstPart: 0..<400, segments: UsenetFixture.segments([410, 410, 210]))
        XCTAssertTrue(layout.isRegular)
        XCTAssertEqual(layout.range(of: 1), 400..<800)
        XCTAssertEqual(layout.range(of: 2), 800..<1000)
        XCTAssertNil(layout.range(of: 3))
        XCTAssertEqual(layout.index(for: 0).index, 0)
        XCTAssertEqual(layout.index(for: 799).index, 1)
        XCTAssertEqual(layout.index(for: 999).index, 2)
        XCTAssertTrue(layout.index(for: 999).certain)
    }

    func testIrregularLayoutEstimatesThenLearns() {
        var layout = UsenetFileLayout(totalSize: 1000, firstPart: 0..<300, segments: UsenetFixture.segments([310, 310, 420]))
        XCTAssertFalse(layout.isRegular)
        XCTAssertEqual(layout.index(for: 50).index, 0)
        XCTAssertTrue(layout.index(for: 50).certain)
        XCTAssertNil(layout.range(of: 1))

        let guess = layout.index(for: 700)
        XCTAssertFalse(guess.certain)
        XCTAssertEqual(guess.index, 2)

        layout.learn(1, range: 300..<600)
        layout.learn(2, range: 600..<1000)
        XCTAssertEqual(layout.index(for: 650).index, 2)
        XCTAssertTrue(layout.index(for: 650).certain)
        XCTAssertEqual(layout.index(for: 450).index, 1)
    }

    func testIrregularGuessRespectsKnownNeighbours() {
        var layout = UsenetFileLayout(totalSize: 1000, firstPart: 0..<100, segments: UsenetFixture.segments([100, 100, 100, 100, 100]))
        layout.learn(3, range: 500..<700)
        // Offset 450 must lie before article 3, whatever the encoded sizes suggest.
        XCTAssertLessThanOrEqual(layout.index(for: 450).index, 2)
        // Offset 800 must lie after it.
        XCTAssertGreaterThanOrEqual(layout.index(for: 800).index, 4)
    }

    func testMemoryProfiles() {
        XCTAssertEqual(UsenetMemoryProfile.lowMemory.cacheBytes, 32 * 1024 * 1024)
        XCTAssertEqual(UsenetMemoryProfile.balanced.cacheBytes, 64 * 1024 * 1024)
        XCTAssertEqual(UsenetMemoryProfile.highThroughput.cacheBytes, 128 * 1024 * 1024)
        for profile in UsenetMemoryProfile.allCases {
            XCTAssertLessThan(profile.readAheadBytes, profile.cacheBytes)
        }
    }
}

// MARK: - Server URLs, stream specs, HTTP ranges

final class UsenetServerTests: XCTestCase {
    func testServerURLParsing() throws {
        let server = try XCTUnwrap(UsenetServerConfig(url: "nntps://user%40mail:p%40ss@news.example.com:443/8"))
        XCTAssertEqual(server.host, "news.example.com")
        XCTAssertEqual(server.port, 443)
        XCTAssertTrue(server.useSSL)
        XCTAssertEqual(server.username, "user@mail")
        XCTAssertEqual(server.password, "p@ss")
        XCTAssertEqual(server.maxConnections, 8)
    }

    func testServerURLDefaults() throws {
        let plain = try XCTUnwrap(UsenetServerConfig(url: "nntp://news.example.com"))
        XCTAssertEqual(plain.port, 119)
        XCTAssertFalse(plain.useSSL)
        XCTAssertEqual(plain.maxConnections, UsenetServerConfig.defaultConnections)
        XCTAssertEqual(UsenetServerConfig(url: "snews://news.example.com")?.port, 563)
        XCTAssertNil(UsenetServerConfig(url: "https://news.example.com"))
        XCTAssertEqual(UsenetServerConfig(url: "nntps://h.example/500")?.maxConnections, 50)
    }

    func testServerURLRoundTrip() throws {
        let server = UsenetServerConfig(host: "news.example.com", port: 563, useSSL: true,
                                        username: "a:b@c", password: "p/ss w?rd", maxConnections: 12)
        XCTAssertEqual(UsenetServerConfig(url: server.urlString), server)
    }

    func testStreamSpecRoundTrip() throws {
        let spec = UsenetStreamSpec(
            nzbURL: URL(string: "https://indexer.example/api?t=get&id=abc&apikey=x%2By")!,
            servers: [UsenetServerConfig(host: "a.example", port: 563, useSSL: true, username: "u", password: "p", maxConnections: 4)],
            fileMustInclude: "(?:S01E02)|(?:1x02)",
            fileIdx: 2
        )
        XCTAssertTrue(UsenetStreamSpec.isUsenetURL(spec.url.absoluteString))
        XCTAssertEqual(UsenetStreamSpec(url: spec.url), spec)
        XCTAssertNil(UsenetStreamSpec(url: URL(string: "https://example.com/video.mkv")!))
        XCTAssertFalse(UsenetStreamSpec.isUsenetURL("https://example.com"))
    }

    func testRangeParsing() {
        func parse(_ header: String?) -> ClosedRange<Int64>?? {
            UsenetStreamServer.parseRange(header, fileLength: 1000)
        }
        func range(_ header: String) -> ClosedRange<Int64>? {
            parse(header) ?? nil
        }
        // No header: a valid whole-file request.
        let whole = parse(nil)
        XCTAssertNotNil(whole)
        XCTAssertNil(whole ?? nil)
        XCTAssertEqual(range("bytes=0-"), 0...999)
        XCTAssertEqual(range("bytes=100-199"), 100...199)
        XCTAssertEqual(range(" bytes=900-5000"), 900...999)
        XCTAssertEqual(range("bytes=-100"), 900...999)
        // Unsatisfiable or malformed: the outer optional is nil (→ 416).
        XCTAssertNil(parse("bytes=1000-"))
        XCTAssertNil(parse("bytes=abc"))
    }

    func testSafeNameAndMime() {
        XCTAssertEqual(UsenetStreamServer.safeName("Show S01E01 [1080p].MKV"), "video.mkv")
        XCTAssertEqual(UsenetStreamServer.safeName("noext"), "video.bin")
    }

    func testAddonServersComeFirstThenOwn() {
        let store = UserDefaults(suiteName: "usenet-tests-\(UUID().uuidString)")!
        let own = UsenetSavedServer(name: "Mine", host: "mine.example", port: 563, useSSL: true, username: "me", connections: 6)
        store.set(try? JSONEncoder().encode([own]), forKey: UsenetSettings.serversKey)
        let addon = UsenetServerConfig(host: "addon.example", port: 563, useSSL: true, username: "x", password: "y", maxConnections: 3)
        let spec = UsenetStreamSpec(nzbURL: URL(string: "https://i.example/a.nzb")!, servers: [addon])

        XCTAssertEqual(UsenetSettings.servers(for: spec, store: store).map(\.host), ["addon.example", "mine.example"])
        store.set(true, forKey: UsenetSettings.preferOwnServersKey)
        XCTAssertEqual(UsenetSettings.servers(for: spec, store: store).map(\.host), ["mine.example"])
    }
}
