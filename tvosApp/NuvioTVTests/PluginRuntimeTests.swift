//
//  PluginRuntimeTests.swift
//  NuvioTVTests
//
//  Plugins (Nuvio JS scrapers) on Apple TV: manifest rules shared with
//  Android, the JavaScriptCore runtime and its browser globals, and how plugin
//  results become streams (including Usenet `nzbUrl`).
//

import XCTest
@testable import NuvioTV

final class PluginRuntimeTests: XCTestCase {

    override func tearDown() {
        PluginRuntime.session = PluginRuntime.makeSession(configuration: .ephemeral)
        PluginURLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: - Manifest

    func testManifestParsesLikeAndroid() throws {
        let json = """
        {
          "name": "Test Repo", "version": 2, "author": "me",
          "resources": ["stream"],
          "scrapers": [
            { "id": "a", "name": "A", "version": "1.0.0", "filename": "a.js", "supportedTypes": ["movie", "series"] },
            { "id": "b", "name": "B", "filename": "b.js", "supportedPlatforms": ["android"] },
            { "id": "c", "name": "C", "filename": "c.js", "disabledPlatforms": ["tvos"] },
            { "id": "d", "name": "D", "filename": "d.js", "supportedPlatforms": ["tvos"], "hasSettings": true, "enabled": false },
            { "name": "no id" },
            "garbage"
          ]
        }
        """
        let manifest = try PluginManifest.parse(Data(json.utf8))
        XCTAssertEqual(manifest.name, "Test Repo")
        XCTAssertEqual(manifest.version, "2")
        XCTAssertEqual(manifest.scrapers.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(manifest.scrapers[0].supportedTypes, ["movie", "tv"])
        XCTAssertEqual(manifest.scrapers[1].supportedTypes, ["movie", "tv"])
        XCTAssertEqual(manifest.scrapers.map(\.isSupportedOnAppleTV), [true, false, false, true])
        XCTAssertTrue(manifest.scrapers[3].hasSettings)
        XCTAssertFalse(manifest.scrapers[3].enabled)

        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"name":"x","version":"1","scrapers":[]}"#.utf8)))
        XCTAssertThrowsError(try PluginManifest.parse(Data("<html>".utf8)))
    }

    func testBareScraperArrayManifestsShortCodesAndSchemes() throws {
        let array = #"[{"id":"t","name":"Template","version":"1.0.0","filename":"providers/t.js","supportedTypes":["movie","series"]}]"#
        let manifest = try PluginManifest.parse(Data(array.utf8), fallbackName: "nuvio-providers")
        XCTAssertEqual(manifest.name, "nuvio-providers")
        XCTAssertEqual(manifest.scrapers.first?.supportedTypes, ["movie", "tv"])
        XCTAssertEqual(manifest.scrapers.first?.declaresSeries, true)

        XCTAssertTrue(PluginStore.isShortCode("cspr"))
        XCTAssertTrue(PluginStore.isShortCode("mega_repo-2"))
        XCTAssertFalse(PluginStore.isShortCode("example.com"))
        XCTAssertFalse(PluginStore.isShortCode("https://x"))
        XCTAssertEqual(
            PluginStore.normalizedManifestURL("stremio://example.com/repo")?.absoluteString,
            "https://example.com/repo/manifest.json"
        )
    }

    func testManifestURLsAndScraperFilesResolveLikeAndroid() {
        XCTAssertEqual(
            PluginStore.normalizedManifestURL("https://github.com/me/plugins/blob/main/manifest.json")?.absoluteString,
            "https://raw.githubusercontent.com/me/plugins/main/manifest.json"
        )
        XCTAssertEqual(
            PluginStore.normalizedManifestURL("raw.githubusercontent.com/me/plugins/main/")?.absoluteString,
            "https://raw.githubusercontent.com/me/plugins/main/manifest.json"
        )
        XCTAssertEqual(
            PluginStore.normalizedManifestURL("  https://example.com/repo/manifest.json  ")?.absoluteString,
            "https://example.com/repo/manifest.json"
        )
        XCTAssertNil(PluginStore.normalizedManifestURL("   "))

        XCTAssertEqual(
            PluginStore.codeURL(repositoryURL: "https://example.com/repo/manifest.json?v=2", filename: "providers/a.js")?.absoluteString,
            "https://example.com/repo/providers/a.js"
        )
        XCTAssertEqual(
            PluginStore.codeURL(repositoryURL: "https://example.com/repo/manifest.json", filename: "/a.js")?.absoluteString,
            "https://example.com/repo/a.js"
        )
        XCTAssertEqual(
            PluginStore.codeURL(repositoryURL: "https://example.com/repo/manifest.json", filename: "https://cdn.example.org/a.js")?.absoluteString,
            "https://cdn.example.org/a.js"
        )
        XCTAssertEqual(
            PluginScraperRecord.makeID(repositoryURL: "https://Example.com/R/manifest.json", scraperID: "a"),
            "https://example.com/r/manifest.json:a"
        )
    }

    func testSettingsLayoutParsing() {
        let layout: [Any] = [
            ["type": "text", "key": "apikey", "label": "API key", "isPassword": true, "placeholder": "abc"],
            ["type": "select", "key": "res", "label": "Resolution", "options": [["label": "4K", "value": "2160p"], "1080p"], "defaultValue": "1080p"],
            ["type": "toggle", "key": "cz", "label": "Prefer CZ", "defaultValue": true],
            ["type": "info", "label": "Note", "description": "Hello"],
            ["type": "text", "label": "no key"]
        ]
        let fields = PluginSettingField.parseLayout(layout)
        XCTAssertEqual(fields.map(\.key), ["apikey", "res", "cz", ""])
        XCTAssertEqual(fields[0].kind, .text(isPassword: true, placeholder: "abc"))
        XCTAssertEqual(fields[1].kind, .select(options: [.init(label: "4K", value: "2160p"), .init(label: "1080p", value: "1080p")]))
        XCTAssertEqual(fields[1].defaultText, "1080p")
        XCTAssertEqual(fields[2].kind, .toggle)
        XCTAssertEqual(fields[2].defaultBool, true)
        XCTAssertNil(fields[2].defaultText)
        XCTAssertEqual(fields[3].kind, .info)
    }

    // MARK: - Runtime

    func testRuntimeAwaitsAsyncExportsAndPassesSettings() async throws {
        let code = """
        async function getStreams(id, type, season, episode, context) {
          await new Promise(function (resolve) { setTimeout(resolve, 20); });
          return [{ id: id, type: type, season: season, episode: episode, imdb: context.imdbId,
                    key: SCRAPER_SETTINGS.apikey, platform: NUVIO_PLATFORM, scraper: SCRAPER_ID }];
        }
        module.exports = { getStreams };
        """
        let result = try await PluginRuntime.call(
            code: code,
            scraperId: "repo:test",
            settings: ["apikey": "k1"],
            function: "getStreams",
            arguments: ["tt0944947", "tv", 1, 2, ["imdbId": "tt0944947"]],
            timeout: 10
        )
        let first = try XCTUnwrap((result as? [[String: Any]])?.first)
        XCTAssertEqual(first["id"] as? String, "tt0944947")
        XCTAssertEqual(first["type"] as? String, "tv")
        XCTAssertEqual(first["season"] as? Int, 1)
        XCTAssertEqual(first["episode"] as? Int, 2)
        XCTAssertEqual(first["imdb"] as? String, "tt0944947")
        XCTAssertEqual(first["key"] as? String, "k1")
        XCTAssertEqual(first["platform"] as? String, "tvos")
        XCTAssertEqual(first["scraper"] as? String, "repo:test")
    }

    func testRuntimeProvidesBrowserGlobals() async throws {
        let code = """
        module.exports.check = async function () {
          var url = new URL('/api?t=caps', 'https://api.example.com/x/y');
          url.searchParams.set('apikey', 'a b');
          var digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc'));
          var hex = Array.from(new Uint8Array(digest)).map(function (b) { return (b < 16 ? '0' : '') + b.toString(16); }).join('');
          var key = await crypto.subtle.importKey('raw', new TextEncoder().encode('key'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
          var mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('The quick brown fox jumps over the lazy dog'));
          var macHex = Array.from(new Uint8Array(mac)).map(function (b) { return (b < 16 ? '0' : '') + b.toString(16); }).join('');
          return {
            href: url.href,
            text: new TextDecoder().decode(new TextEncoder().encode('Žluťoučký kůň 🐴')),
            b64: btoa('hello') + '|' + atob('aGVsbG8='),
            sha: hex,
            hmac: macHex,
            uuid: crypto.randomUUID().length,
            hasFetch: typeof fetch === 'function' && typeof AbortController === 'function'
          };
        };
        """
        let result = try await PluginRuntime.call(code: code, scraperId: "repo:globals", function: "check", timeout: 10)
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(object["href"] as? String, "https://api.example.com/api?t=caps&apikey=a+b")
        XCTAssertEqual(object["text"] as? String, "Žluťoučký kůň 🐴")
        XCTAssertEqual(object["b64"] as? String, "aGVsbG8=|hello")
        XCTAssertEqual(object["sha"] as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(object["hmac"] as? String, "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        XCTAssertEqual(object["uuid"] as? Int, 36)
        XCTAssertEqual(object["hasFetch"] as? Bool, true)
    }

    func testRuntimeReportsMissingFunctionErrorsAndTimeouts() async {
        do {
            _ = try await PluginRuntime.call(code: "module.exports = {};", scraperId: "x", function: "getStreams", timeout: 5)
            XCTFail("expected missing function")
        } catch {
            XCTAssertEqual(error as? PluginRuntimeError, .missingFunction("getStreams"))
        }

        do {
            _ = try await PluginRuntime.call(
                code: "module.exports.getStreams = async function () { throw new Error('kaput'); };",
                scraperId: "x", function: "getStreams", timeout: 5
            )
            XCTFail("expected script error")
        } catch PluginRuntimeError.script(let message) {
            XCTAssertTrue(message.contains("kaput"), message)
        } catch {
            XCTFail("unexpected \(error)")
        }

        do {
            _ = try await PluginRuntime.call(code: "this is not javascript", scraperId: "x", function: "getStreams", timeout: 5)
            XCTFail("expected syntax error")
        } catch {
            guard let runtimeError = error as? PluginRuntimeError, case .script = runtimeError else {
                return XCTFail("unexpected \(error)")
            }
        }

        let started = Date()
        do {
            _ = try await PluginRuntime.call(
                code: "module.exports.getStreams = function () { return new Promise(function () {}); };",
                scraperId: "x", function: "getStreams", timeout: 0.5
            )
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? PluginRuntimeError, .timedOut(0.5))
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
    }

    func testLocalStoragePersistsBetweenCalls() async throws {
        let scraperID = "test:storage:\(UUID().uuidString)"
        defer { PluginStorageFile.remove(scraperID: scraperID, scope: ProfileSettings.activeProfileScope) }
        let code = """
        module.exports.put = function () { localStorage.setItem('caps', '{"tv":["tvdbid"]}'); localStorage.setItem('n', 7); return localStorage.length; };
        module.exports.get = function () { return { caps: JSON.parse(localStorage.getItem('caps')), n: localStorage.getItem('n'), none: localStorage.getItem('x') }; };
        """
        let count = try await PluginRuntime.call(code: code, scraperId: scraperID, function: "put", timeout: 10)
        XCTAssertEqual(count as? Int, 2)
        // The file is written when the first call's context is torn down.
        try await Task.sleep(nanoseconds: 300_000_000)
        let result = try await PluginRuntime.call(code: code, scraperId: scraperID, function: "get", timeout: 10)
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual((object["caps"] as? [String: Any])?["tv"] as? [String], ["tvdbid"])
        XCTAssertEqual(object["n"] as? String, "7")
        XCTAssertTrue(object["none"] is NSNull)
    }

    func testCheerioWorksLikeOnAndroid() async throws {
        let code = #"""
        var cheerio = require('cheerio-without-node-native');
        module.exports.go = function () {
          var $ = cheerio.load('<ul id="l"><li class="a" data-n="1"><a href="/1">One</a></li>'
            + '<li class="b"><a href="/2"> Two  words </a></li><li class="a"><a>Three</a></li></ul><p>x</p>');
          var links = [];
          $('li.a').each(function (i, el) { links.push($(el).find('a').attr('href') || '-'); });
          return {
            count: $('li').length,
            links: links,
            text: $('li.b').text(),
            contains: $('li:contains("Two")').length,
            next: $('li.a').first().next().attr('class'),
            prev: $('li.b').prev().attr('class'),
            parent: $('a').first().parent().attr('class'),
            closest: $('a').last().closest('ul').attr('id'),
            children: $('#l').children('.a').length,
            filter: $('li').filter('.b').length,
            is: $('li').first().is('.a'),
            data: $('li').first().data('n'),
            html: $('li.b').html(),
            outer: $.html($('p')),
            map: $('a').map(function (i, el) { return $(el).text(); }).get(),
            missing: $('li.b').attr('title') === undefined,
            empty: $('nothing').text()
          };
        };
        """#
        let result = try await PluginRuntime.call(code: code, scraperId: "x", function: "go", timeout: 10)
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(object["count"] as? Int, 3)
        XCTAssertEqual(object["links"] as? [String], ["/1", "-"])
        XCTAssertEqual(object["text"] as? String, "Two words")
        XCTAssertEqual(object["contains"] as? Int, 1)
        XCTAssertEqual(object["next"] as? String, "b")
        XCTAssertEqual(object["prev"] as? String, "a")
        XCTAssertEqual(object["parent"] as? String, "a")
        XCTAssertEqual(object["closest"] as? String, "l")
        XCTAssertEqual(object["children"] as? Int, 2)
        XCTAssertEqual(object["filter"] as? Int, 1)
        XCTAssertEqual(object["is"] as? Bool, true)
        XCTAssertEqual(object["data"] as? Int, 1)
        let html = try XCTUnwrap(object["html"] as? String)
        XCTAssertTrue(html.hasPrefix("<a href=\"/2\">") && html.contains("Two"), html)
        XCTAssertEqual(object["outer"] as? String, "<p>x</p>")
        XCTAssertEqual(object["map"] as? [String], ["One", "Two words", "Three"])
        XCTAssertEqual(object["missing"] as? Bool, true)
        XCTAssertEqual(object["empty"] as? String, "")
    }

    func testCryptoJSAndWebCryptoAESMatchKnownValues() async throws {
        let code = #"""
        module.exports.go = async function () {
          function hex(buf) { return Array.from(new Uint8Array(buf)).map(function (b) { return (b < 16 ? '0' : '') + b.toString(16); }).join(''); }
          var C = require('crypto-js');
          var sealed = CryptoJS.AES.encrypt('Příliš žluťoučký kůň', 'pw').toString();
          var raw = new Uint8Array(32); for (var i = 0; i < 32; i++) raw[i] = i;
          var gcm = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
          var box = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: new Uint8Array(12) }, gcm, new TextEncoder().encode('hello'));
          var cbc = await crypto.subtle.importKey('raw', raw, 'AES-CBC', false, ['encrypt', 'decrypt']);
          var c = await crypto.subtle.encrypt({ name: 'AES-CBC', iv: new Uint8Array(16) }, cbc, new TextEncoder().encode('hello world'));
          var pw = await crypto.subtle.importKey('raw', new TextEncoder().encode('password'), 'PBKDF2', false, ['deriveBits']);
          var bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: new TextEncoder().encode('salt'), iterations: 1, hash: 'SHA-1' }, pw, 160);
          return {
            md5: C.MD5('abc').toString(),
            roundtrip: CryptoJS.AES.decrypt(sealed, 'pw').toString(CryptoJS.enc.Utf8),
            gcm: new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: new Uint8Array(12) }, gcm, box)),
            cbcBytes: c.byteLength,
            cbc: new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-CBC', iv: new Uint8Array(16) }, cbc, c)),
            pbkdf2: hex(bits),
            tmdbKeyType: typeof TMDB_API_KEY
          };
        };
        """#
        let result = try await PluginRuntime.call(code: code, scraperId: "x", function: "go", timeout: 20)
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(object["md5"] as? String, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(object["roundtrip"] as? String, "Příliš žluťoučký kůň")
        XCTAssertEqual(object["gcm"] as? String, "hello")
        XCTAssertEqual(object["cbcBytes"] as? Int, 16)
        XCTAssertEqual(object["cbc"] as? String, "hello world")
        XCTAssertEqual(object["pbkdf2"] as? String, "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        XCTAssertEqual(object["tmdbKeyType"] as? String, "string")
    }

    func testFetchUsesTheNetworkAndReturnsResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PluginURLProtocolStub.self]
        PluginRuntime.session = PluginRuntime.makeSession(configuration: configuration)
        PluginURLProtocolStub.handler = { request in
            if request.url?.path == "/json" {
                let body = #"{"ok":true,"ua":"\#(request.value(forHTTPHeaderField: "User-Agent") ?? "")","h":"\#(request.value(forHTTPHeaderField: "X-Test") ?? "")"}"#
                return (200, ["Content-Type": "application/json", "X-Reply": "yes"], Data(body.utf8))
            }
            return (404, [:], Data("missing".utf8))
        }
        let code = """
        module.exports.go = async function () {
          var r = await fetch('https://api.example.com/json', { headers: { 'X-Test': 'hi' } });
          var j = await r.json();
          var m = await fetch('https://api.example.com/other');
          return { ok: r.ok, status: r.status, reply: r.headers.get('x-reply'), json: j, missing: m.status, missingText: await m.text() };
        };
        """
        let result = try await PluginRuntime.call(code: code, scraperId: "x", function: "go", timeout: 10)
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["status"] as? Int, 200)
        XCTAssertEqual(object["reply"] as? String, "yes")
        let json = try XCTUnwrap(object["json"] as? [String: Any])
        XCTAssertEqual(json["h"] as? String, "hi")
        XCTAssertEqual(json["ua"] as? String, PluginRuntime.userAgent)
        XCTAssertEqual(object["missing"] as? Int, 404)
        XCTAssertEqual(object["missingText"] as? String, "missing")
    }

    // MARK: - Streams

    func testPluginResultsBecomeStreamsLikeOnAndroid() throws {
        let direct = try XCTUnwrap(PluginStreamDiscovery.stream(from: [
            "name": "Provider 1080p",
            "title": "Some.Movie.2024.1080p.WEB-DL",
            "url": "https://cdn.example.com/video.mp4",
            "quality": "1080p",
            "size": "2.1 GB",
            "headers": ["Referer": "https://example.com/", "Range": "bytes=0-"],
            "subtitles": [["url": "https://example.com/cz.srt", "lang": "cze"]]
        ], providerName: "Provider"))
        XCTAssertEqual(direct.url, "https://cdn.example.com/video.mp4")
        XCTAssertEqual(direct.name, "Provider 1080p")
        // Android TV layout: the title under the name, then size • language.
        XCTAssertEqual(direct.description, "Some.Movie.2024.1080p.WEB-DL\n2.1 GB")
        XCTAssertEqual(direct.httpHeaders?["Referer"], "https://example.com/")
        XCTAssertNil(direct.httpHeaders?["Range"])
        XCTAssertEqual(direct.subtitles.count, 1)

        let usenet = try XCTUnwrap(PluginStreamDiscovery.stream(from: [
            "name": "UD · NZBGeek\n1080p",
            "description": "🔎 NZBGeek\nWEB-DL",
            "nzbUrl": "https://api.nzbgeek.info/api?t=get&id=abc&apikey=KEY",
            "behaviorHints": ["bingeGroup": "ud|1080p", "videoSize": 2_000_000_000]
        ], providerName: "Usenet Direct"))
        let url = try XCTUnwrap(usenet.url.flatMap(URL.init(string:)))
        XCTAssertEqual(url.scheme, UsenetStreamSpec.scheme)
        XCTAssertEqual(UsenetStreamSpec(url: url)?.nzbURL.absoluteString, "https://api.nzbgeek.info/api?t=get&id=abc&apikey=KEY")
        XCTAssertEqual(usenet.description, "🔎 NZBGeek\nWEB-DL")
        XCTAssertEqual(usenet.bingeGroup, "ud|1080p")

        XCTAssertNil(PluginStreamDiscovery.stream(from: ["name": "no link"], providerName: "P"))
        XCTAssertNil(PluginStreamDiscovery.stream(from: ["url": "[object Object]"], providerName: "P"))

        let bare = try XCTUnwrap(PluginStreamDiscovery.stream(from: [
            "title": "Server 2", "url": "https://cdn.example.com/a.m3u8", "quality": "720p", "language": "EN"
        ], providerName: "Provider"))
        XCTAssertEqual(bare.name, "Server 2 - 720p")
        XCTAssertEqual(bare.description, "EN")
    }

    func testScrapersThatListSeriesGetSeriesForEpisodes() {
        let request = PluginStreamDiscovery.request(
            type: "series", videoID: "tt0944947:1:2", resolvedTMDBID: "1399", scraperDeclaresSeries: true
        )
        XCTAssertEqual(request.mediaType, "series")
        XCTAssertEqual(request.arguments[1] as? String, "series")
        let movie = PluginStreamDiscovery.request(
            type: "movie", videoID: "tt0816692", resolvedTMDBID: nil, scraperDeclaresSeries: true
        )
        XCTAssertEqual(movie.mediaType, "movie")
    }

    func testStreamRequestPassesTmdbFirstAndImdbInContext() {
        let episode = PluginStreamDiscovery.request(type: "series", videoID: "tt0944947:1:2", resolvedTMDBID: nil)
        XCTAssertEqual(episode.primaryID, "tt0944947")
        XCTAssertEqual(episode.mediaType, "tv")
        XCTAssertEqual(episode.season, 1)
        XCTAssertEqual(episode.episode, 2)
        XCTAssertEqual(episode.imdbID, "tt0944947")

        let resolved = PluginStreamDiscovery.request(type: "series", videoID: "tt0944947:1:2", resolvedTMDBID: "1399")
        XCTAssertEqual(resolved.primaryID, "1399")
        XCTAssertEqual(resolved.context["imdbId"] as? String, "tt0944947")
        XCTAssertEqual(resolved.context["tmdbId"] as? String, "1399")
        XCTAssertEqual(resolved.context["platform"] as? String, "tvos")

        let tmdb = PluginStreamDiscovery.request(type: "series", videoID: "tmdb:1399:3:4", resolvedTMDBID: nil)
        XCTAssertEqual(tmdb.primaryID, "1399")
        XCTAssertNil(tmdb.imdbID)
        XCTAssertEqual(tmdb.season, 3)

        let movie = PluginStreamDiscovery.request(type: "movie", videoID: "tt0816692", resolvedTMDBID: nil)
        XCTAssertEqual(movie.primaryID, "tt0816692")
        XCTAssertNil(movie.season)
        XCTAssertEqual(movie.mediaType, "movie")
        XCTAssertTrue(movie.arguments[2] is NSNull)
    }
}

/// Answers plugin `fetch` requests in tests.
final class PluginURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, [String: String], Data))?

    static var handler: ((URLRequest) -> (Int, [String: String], Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
