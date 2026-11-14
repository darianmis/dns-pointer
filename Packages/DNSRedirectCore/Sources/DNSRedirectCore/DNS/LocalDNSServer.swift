import Foundation
import Network

/// Abstraction over the upstream network so the server can be tested offline.
public protocol UpstreamDNS: Sendable {
    func addresses(for name: String, type: DNSRecordType) async throws -> [IPAddress]
    func forward(_ packet: [UInt8]) async throws -> [UInt8]
}

public struct NetworkUpstreamDNS: UpstreamDNS {
    public init() {}

    public func addresses(for name: String, type: DNSRecordType) async throws -> [IPAddress] {
        let reply = try await DNSClient().query(name, type: type)
        return reply.answers.compactMap(\.ipAddress)
    }

    public func forward(_ packet: [UInt8]) async throws -> [UInt8] {
        try await DNSClient().exchange(packet)
    }
}

/// A tiny loopback DNS server that answers live alias rules with CNAME + address records
/// and forwards every other query (e.g. subdomains) to the Mac's normal DNS servers.
///
/// macOS sends queries here only for domains that have an `/etc/resolver/<domain>` file
/// pointing at `127.0.0.1` and this port.
public final class LocalDNSServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    public static let answerTTL: UInt32 = 30

    private let queue = DispatchQueue(label: "dnsredirect.local-resolver")
    private let lock = NSLock()
    private var listener: NWListener?
    private var aliases: [String: String] = [:]
    private var _state: State = .stopped
    private let upstream: UpstreamDNS
    private var stats = Statistics()

    public struct Statistics: Equatable, Sendable {
        public var answered = 0
        public var forwarded = 0
        public var failed = 0
        public init() {}
    }

    /// Called on an arbitrary queue whenever state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(upstream: UpstreamDNS = NetworkUpstreamDNS()) {
        self.upstream = upstream
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Counters for queries this server has handled since start (it only sees queries for aliased domains).
    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public func setAliases(_ newAliases: [String: String]) {
        lock.lock(); aliases = newAliases; lock.unlock()
    }

    public func currentAliases() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return aliases
    }

    private func setState(_ s: State) {
        lock.lock(); _state = s; lock.unlock()
        onStateChange?(s)
    }

    /// Starts listening on 127.0.0.1:`port` (UDP). Pass 0 to pick a free port (tests).
    public func start(port: UInt16) async throws -> UInt16 {
        stop()
        setState(.starting)
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let once = ResumeOnce()
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let p = listener.port?.rawValue ?? port
                    self?.setState(.running(port: p))
                    if once.claim() { continuation.resume(returning: p) }
                case .failed(let error):
                    self?.setState(.failed(Self.describe(error, port: port)))
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener; stats = Statistics() }
        return boundPort
    }

    public func stop() {
        lock.lock()
        let l = listener
        listener = nil
        lock.unlock()
        if let l {
            l.stateUpdateHandler = nil
            l.cancel()
            setState(.stopped)
        }
    }

    static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use by another process."
        }
        return error.localizedDescription
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
        // UDP "connections" are per remote endpoint; drop idle ones.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            let packet = Array(data)
            Task {
                if let reply = await self.respond(to: packet) {
                    connection.send(content: Data(reply), completion: .contentProcessed { _ in })
                }
            }
            self.receive(on: connection)
        }
    }

    private func count(_ keyPath: WritableKeyPath<Statistics, Int>) {
        lock.lock(); stats[keyPath: keyPath] += 1; lock.unlock()
    }

    /// Produces the reply for a raw query packet. Internal for testing.
    func respond(to packet: [UInt8]) async -> [UInt8]? {
        guard let query = try? DNSMessage(bytes: packet), !query.isResponse, let question = query.questions.first else {
            return nil
        }
        let name = question.name.lowercased()
        let table = currentAliases()

        guard table[name] != nil else {
            // Not an alias (e.g. a subdomain): behave like normal DNS.
            do {
                let reply = try await upstream.forward(packet)
                count(\.forwarded)
                return reply
            } catch {
                count(\.failed)
                return try? DNSMessage.response(to: query, answers: [], rcode: 2, authoritative: false).encode()
            }
        }

        // Build the CNAME chain inside our own alias table.
        var answers: [DNSRecord] = []
        var current = name
        var visited: Set<String> = [name]
        while let target = table[current] {
            answers.append(.cname(current, target: target, ttl: Self.answerTTL))
            guard visited.insert(target).inserted else { break }
            current = target
        }

        let wanted: DNSRecordType?
        switch question.type {
        case DNSRecordType.a.rawValue: wanted = .a
        case DNSRecordType.aaaa.rawValue: wanted = .aaaa
        default: wanted = nil
        }
        if let wanted, question.qclass == 1 {
            if let addrs = try? await upstream.addresses(for: current, type: wanted) {
                let family: IPAddress.Family = wanted == .a ? .v4 : .v6
                answers += addrs.filter { $0.family == family }.map { .address(current, $0, ttl: Self.answerTTL) }
            }
        }
        count(\.answered)
        return try? DNSMessage.response(to: query, answers: answers).encode()
    }
}
