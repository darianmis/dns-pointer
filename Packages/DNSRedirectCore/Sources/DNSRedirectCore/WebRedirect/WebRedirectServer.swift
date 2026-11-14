import Foundation
import Network
import Security

/// Where a web-redirect rule sends the browser.
public enum WebRedirectTarget {
    /// Builds the Location header for a request path. A bare domain keeps the request path
    /// (`youtube.com/watch?v=1` → `https://dest/watch?v=1`); a URL with its own path is used as-is.
    public static func location(for target: String, requestPath: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        let path = requestPath.hasPrefix("/") ? requestPath : "/" + requestPath
        if trimmed.contains("://") {
            guard var components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false else { return nil }
            if components.path.isEmpty || components.path == "/" {
                components.path = ""
                return (components.string ?? trimmed) + path
            }
            return components.string
        }
        guard let host = try? DomainName.validate(trimmed, allowReserved: true) else { return nil }
        return "https://\(host)\(path)"
    }

    /// Validates a destination for a web-redirect rule: a domain, or an http(s) URL.
    public static func validate(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuleValidationError.invalidDestination("Enter a domain or URL to redirect to.") }
        if trimmed.contains("://") {
            guard let c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty else {
                throw RuleValidationError.invalidDestination("Use an http:// or https:// URL, for example https://example.org/page.")
            }
            if IPAddress(host) == nil {
                do { try DomainName.validate(host, allowReserved: true) } catch {
                    throw RuleValidationError.invalidDestination(error.localizedDescription)
                }
            }
            return trimmed
        }
        if IPAddress(trimmed) != nil {
            throw RuleValidationError.invalidDestination("A web redirect needs a domain or URL. To point at an IP address, use an IP rule.")
        }
        do { return try DomainName.validate(trimmed, allowReserved: true) } catch {
            throw RuleValidationError.invalidDestination(error.localizedDescription)
        }
    }
}

/// Pure HTTP/1.x request handling (no networking) for unit tests and the server.
public enum WebRedirectHTTP {
    public struct Request: Equatable {
        public var method: String
        public var path: String
        public var host: String?
    }

    /// Parses a request head. Returns nil until the full header block has arrived.
    public static func parse(_ data: [UInt8]) -> Request? {
        guard let end = data.firstRange(of: [13, 10, 13, 10]) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return Request(method: "", path: "/", host: nil) }
        var host: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
                if value.hasPrefix("[") { value = String(value.drop { $0 != "]" }) } // IPv6 literal: leave as-is
                else if let c = value.lastIndex(of: ":") { value = String(value[..<c]) }
                while value.hasSuffix(".") { value.removeLast() }
                host = value
            }
        }
        var path = String(parts[1])
        if path.contains("://"), let c = URLComponents(string: path) {
            path = (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        return Request(method: String(parts[0]), path: path, host: host)
    }

    public static func response(for request: Request, redirects: [String: String]) -> (status: Int, location: String?, bytes: [UInt8]) {
        guard let host = request.host, let target = redirects[host],
              let location = WebRedirectTarget.location(for: target, requestPath: request.path) else {
            let body = "<html><body style=\"font-family:-apple-system;background:#0a0c10;color:#9aa3b2\"><h3>DNS Redirect</h3><p>No web redirect is configured for \(escape(request.host ?? "this host")).</p></body></html>"
            return (404, nil, build(status: "404 Not Found", headers: ["Content-Type": "text/html; charset=utf-8"], body: body))
        }
        let body = "<html><body>Redirecting to <a href=\"\(escape(location))\">\(escape(location))</a></body></html>"
        // 302 + no-store so browsers don't cache the redirect after the rule is removed.
        return (302, location, build(status: "302 Found", headers: [
            "Location": location,
            "Cache-Control": "no-store, max-age=0",
            "Content-Type": "text/html; charset=utf-8",
        ], body: body))
    }

    static func build(status: String, headers: [String: String], body: String) -> [UInt8] {
        var text = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { text += "\(k): \(v)\r\n" }
        text += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\nServer: DNS-Redirect\r\n\r\n\(body)"
        return Array(text.utf8)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Answers browsers for web-redirect hosts (mapped to 127.0.0.1 / ::1) with an HTTP redirect.
///
/// macOS only lets unprivileged processes use ports below 1024 on the wildcard address, so the
/// listeners bind to it, are pinned to the loopback interface, and additionally refuse every
/// connection that does not come from a loopback address.
public final class WebRedirectServer: @unchecked Sendable {
    public struct State: Equatable, Sendable {
        public var httpRunning = false
        public var httpsRunning = false
        public var error: String?
        public init() {}
    }

    public struct Statistics: Equatable, Sendable {
        public var redirected = 0
        public var notFound = 0
        public var rejected = 0
        public init() {}
    }

    private let queue = DispatchQueue(label: "dnsredirect.web-redirect")
    private let lock = NSLock()
    private var http: NWListener?
    private var https: NWListener?
    private var redirects: [String: String] = [:]
    private var _state = State()
    private var stats = Statistics()
    public var onStateChange: (@Sendable (State) -> Void)?

    public init() {}

    public var state: State { lock.withLock { _state } }
    public var statistics: Statistics { lock.withLock { stats } }
    public var isRunning: Bool { lock.withLock { http != nil || https != nil } }

    public func setRedirects(_ map: [String: String]) {
        lock.withLock { redirects = map }
    }

    private func update(_ change: (inout State) -> Void) {
        let s: State = lock.withLock { change(&_state); return _state }
        onStateChange?(s)
    }

    /// Starts (or restarts) the listeners. Pass `identity: nil` to serve plain HTTP only.
    /// Returns the bound ports (useful when passing 0 in tests).
    @discardableResult
    public func start(httpPort: UInt16 = 80, httpsPort: UInt16 = 443, identity: SecIdentity?) async -> (http: UInt16?, https: UInt16?) {
        stop()
        var errors: [String] = []
        let h = await listen(port: httpPort, tls: nil)
        if case .failure(let e) = h { errors.append("HTTP port \(httpPort): \(e)") }
        var s: Result<(NWListener, UInt16), WebServerError>?
        if let identity {
            let tls = NWProtocolTLS.Options()
            if let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            }
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            s = await listen(port: httpsPort, tls: tls)
            if case .failure(let e)? = s { errors.append("HTTPS port \(httpsPort): \(e)") }
        }
        let httpListener = try? h.get()
        let httpsListener = try? s?.get()
        lock.withLock {
            http = httpListener?.0
            https = httpsListener?.0
            stats = Statistics()
        }
        update {
            $0.httpRunning = httpListener != nil
            $0.httpsRunning = httpsListener != nil
            $0.error = errors.isEmpty ? nil : errors.joined(separator: " ")
        }
        return (httpListener?.1, httpsListener?.1)
    }

    public func stop() {
        let (a, b) = lock.withLock { () -> (NWListener?, NWListener?) in
            defer { http = nil; https = nil }
            return (http, https)
        }
        a?.cancel()
        b?.cancel()
        if a != nil || b != nil { update { $0 = State() } }
    }

    public struct WebServerError: Error, CustomStringConvertible {
        public let description: String
    }

    private func listen(port: UInt16, tls: NWProtocolTLS.Options?) async -> Result<(NWListener, UInt16), WebServerError> {
        let params = tls.map { NWParameters(tls: $0, tcp: NWProtocolTCP.Options()) } ?? NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failure(WebServerError(description: "invalid port")) }
        let listener: NWListener
        do { listener = try NWListener(using: params, on: nwPort) } catch {
            return .failure(WebServerError(description: Self.describe(error)))
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: .success((listener, listener.port?.rawValue ?? port))) }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    if once.claim() { continuation.resume(returning: .failure(WebServerError(description: Self.describe(error)))) }
                case .cancelled:
                    if once.claim() { continuation.resume(returning: .failure(WebServerError(description: "cancelled"))) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    static func describe(_ error: Error) -> String {
        if let nw = error as? NWError, case .posix(let code) = nw {
            if code == .EADDRINUSE { return "already in use by another app (for example a local web server)" }
            if code == .EACCES { return "permission denied" }
        }
        return error.localizedDescription
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    private func handle(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            lock.withLock { stats.rejected += 1 }
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        receive(connection, buffer: [])
    }

    private func receive(_ connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf += data }
            if let request = WebRedirectHTTP.parse(buf) {
                let map = self.lock.withLock { self.redirects }
                let reply = WebRedirectHTTP.response(for: request, redirects: map)
                self.lock.withLock { if reply.status == 302 { self.stats.redirected += 1 } else { self.stats.notFound += 1 } }
                connection.send(content: Data(reply.bytes), completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || isComplete || buf.count > 32_768 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buf)
            }
        }
    }
}

/// Fetches the redirect a host currently gets from the local web-redirect server (for rule tests).
public enum WebRedirectProbe {
    public struct Result: Equatable, Sendable {
        public var status: Int
        public var location: String?
    }

    /// Connects to `127.0.0.1:port` and asks for `host`. With `tls`, the handshake uses normal
    /// system trust and SNI, so success also proves the local CA is trusted for that host.
    public static func probe(host: String, port: UInt16, tls: Bool, timeout: TimeInterval = 4) async throws -> Result {
        let params: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            params = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params)
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            let finish: @Sendable (Swift.Result<Result, Error>) -> Void = { r in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(with: r)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET / HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: DNS-Redirect-Test\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                        guard let data else { return finish(.failure(error ?? DNSError.truncated)) }
                        let text = String(decoding: data, as: UTF8.self)
                        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
                        let location = text.components(separatedBy: "\r\n")
                            .first { $0.lowercased().hasPrefix("location:") }
                            .map { String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
                        finish(.success(Result(status: status, location: location)))
                    }
                case .failed(let e), .waiting(let e):
                    finish(.failure(e))
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(DNSError.timeout)) }
        }
    }
}
