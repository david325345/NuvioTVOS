import Foundation
import Network
import Darwin
import Security

/// Settings → Plugins → "Set Up from a Computer": a small web server on the
/// Apple TV's local network address, so plugin repositories, providers and
/// their settings (API keys) can be managed from a browser on a computer or
/// phone instead of the Siri Remote keyboard.
///
/// It runs only while that screen is open and stops after 15 minutes without
/// a request. Every address carries a random token, it answers on the local
/// network interface only, and saved passwords are never sent back in full.
@MainActor
final class PluginWebServer: ObservableObject {
    enum Phase: Equatable {
        case stopped
        case starting
        case ready(URL)
        case failed(String)
    }

    static let shared = PluginWebServer()
    static let idleTimeout: TimeInterval = 15 * 60

    @Published private(set) var phase: Phase = .stopped
    /// When the last request arrived (the screen shows "connected").
    @Published private(set) var lastActivity: Date?

    private var core: PluginHTTPServerCore?

    private init() {}

    func start() {
        guard core == nil else { return }
        phase = .starting
        lastActivity = nil
        let core = PluginHTTPServerCore(
            token: Self.makeToken(),
            idleTimeout: Self.idleTimeout,
            handler: { request in await PluginWebAPI.handle(request) }
        )
        self.core = core
        core.start(
            onState: { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.core === core else { return }
                    switch state {
                    case .ready(let url): self.phase = .ready(url)
                    case .failed(let message):
                        self.phase = .failed(message)
                        self.core = nil
                    case .stopped:
                        self.phase = .stopped
                        self.core = nil
                    }
                }
            },
            onActivity: { [weak self] in
                Task { @MainActor [weak self] in self?.lastActivity = Date() }
            }
        )
    }

    func stop() {
        core?.stop()
        core = nil
        phase = .stopped
    }

    private static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 10)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = bytes.map { _ in UInt8.random(in: 0...255) }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

/// The HTTP side: an `NWListener` on the local IPv4 address with tiny,
/// request-per-connection HTTP/1.1 handling. Requests outside `/<token>/` get
/// a 404 without reaching the handler.
final class PluginHTTPServerCore: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        var headers: [String: String] = [:]

        static func json(_ object: [String: Any], status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json; charset=utf-8", body: data)
        }

        static func error(_ message: String, status: Int = 400) -> Response {
            json(["ok": false, "error": message], status: status)
        }
    }

    enum State: Sendable {
        case ready(URL)
        case failed(String)
        case stopped
    }

    static let maxRequestBytes = 1 << 20

    private let token: String
    private let idleTimeout: TimeInterval
    private let handler: @Sendable (Request) async -> Response
    private let queue = DispatchQueue(label: "nuvio.plugins.web", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var idleTimer: DispatchWorkItem?
    private var onState: (@Sendable (State) -> Void)?
    private var onActivity: (@Sendable () -> Void)?
    private var stopped = false

    init(token: String, idleTimeout: TimeInterval, handler: @escaping @Sendable (Request) async -> Response) {
        self.token = token
        self.idleTimeout = idleTimeout
        self.handler = handler
    }

    func start(onState: @escaping @Sendable (State) -> Void, onActivity: @escaping @Sendable () -> Void) {
        queue.async {
            self.onState = onState
            self.onActivity = onActivity
            guard let host = Self.localIPv4Address() else {
                onState(.failed("The Apple TV has no local network address. Is it connected to Wi-Fi or Ethernet?"))
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
                let listener = try NWListener(using: parameters)
                listener.newConnectionLimit = 32
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port,
                              let url = URL(string: "http://\(host):\(port.rawValue)/\(self.token)/") else {
                            self.finish(.failed("The server could not start."))
                            return
                        }
                        self.resetIdleTimer()
                        onState(.ready(url))
                    case .failed(let error):
                        self.finish(.failed(error.localizedDescription))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, !self.stopped, self.connections.count < 16 else {
                        connection.cancel()
                        return
                    }
                    let id = UUID()
                    self.connections[id] = connection
                    connection.start(queue: self.queue)
                    self.receive(connection, id: id, buffered: Data())
                    self.queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.close(id) }
                }
                listener.start(queue: self.queue)
            } catch {
                self.finish(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { self.finish(.stopped) }
    }

    private func finish(_ state: State) {
        guard !stopped else { return }
        stopped = true
        idleTimer?.cancel()
        idleTimer = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        onState?(state)
        onState = nil
        onActivity = nil
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.finish(.stopped) }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: timer)
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var request = buffered
            if let data { request.append(data) }
            guard error == nil, request.count <= Self.maxRequestBytes else {
                self.close(id)
                return
            }
            switch Self.parse(request) {
            case .incomplete:
                if complete { self.close(id) } else { self.receive(connection, id: id, buffered: request) }
            case .invalid:
                self.send(Response.error("Bad request"), on: connection, id: id)
            case .complete(let parsed):
                self.route(parsed, connection: connection, id: id)
            }
        }
    }

    private func route(_ request: Request, connection: NWConnection, id: UUID) {
        let prefix = "/\(token)"
        guard request.path == prefix || request.path.hasPrefix(prefix + "/") else {
            send(Response(status: 404, contentType: "text/plain; charset=utf-8", body: Data("Not found".utf8)), on: connection, id: id)
            return
        }
        resetIdleTimer()
        onActivity?()
        if request.path == prefix {
            var redirect = Response(status: 301, contentType: "text/plain; charset=utf-8", body: Data())
            redirect.headers["Location"] = prefix + "/"
            send(redirect, on: connection, id: id)
            return
        }
        let inner = Request(
            method: request.method,
            path: String(request.path.dropFirst(prefix.count)),
            query: request.query,
            body: request.body
        )
        let handler = self.handler
        Task {
            let response = await handler(inner)
            self.queue.async { self.send(response, on: connection, id: id) }
        }
    }

    private func send(_ response: Response, on connection: NWConnection, id: UUID) {
        guard connections[id] != nil else { return }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.close(id) }
        })
    }

    // MARK: - Parsing

    enum ParseResult {
        case incomplete
        case invalid
        case complete(Request)
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16_384 ? .invalid : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let length = Int(value), length >= 0, length <= maxRequestBytes else { return .invalid }
                contentLength = length
            } else if name == "transfer-encoding" {
                return .invalid
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(Request(
            method: String(parts[0]).uppercased(),
            path: components?.percentEncodedPath ?? target,
            query: query,
            body: body
        ))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 301: return "Moved Permanently"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }

    static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var next = interfaces
        while let item = next {
            defer { next = item.pointee.ifa_next }
            let info = item.pointee
            guard let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  info.ifa_flags & UInt32(IFF_UP) != 0,
                  info.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  String(cString: info.ifa_name).hasPrefix("en") else { continue }
            let result: String? = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ip = pointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let result { return result }
        }
        return nil
    }
}
