import Darwin
import Foundation
import Network
import SystemConfiguration

// MARK: - System resolver (getaddrinfo)

/// Resolves names exactly the way ordinary apps do: through the macOS resolver,
/// which consults /etc/hosts, /etc/resolver and the configured DNS servers.
public struct SystemAddressResolver: AddressResolving {
    public init() {}

    public func resolve(_ host: String) async throws -> [IPAddress] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.getaddrinfoSync(host) })
            }
        }
    }

    public struct LookupError: Error, LocalizedError {
        public let code: Int32
        public var errorDescription: String? {
            String(cString: gai_strerror(code))
        }
    }

    static func getaddrinfoSync(_ host: String) throws -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0 else { throw LookupError(code: status) }
        defer { freeaddrinfo(result) }
        var addresses: [IPAddress] = []
        var cursor = result
        while let info = cursor?.pointee {
            if let sa = info.ai_addr {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if let ip = IPAddress(bytes: withUnsafeBytes(of: &a) { Array($0) }) { addresses.append(ip) }
                case AF_INET6:
                    var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if let ip = IPAddress(bytes: withUnsafeBytes(of: &a) { Array($0) }) { addresses.append(ip) }
                default: break
                }
            }
            cursor = info.ai_next
        }
        var seen = Set<IPAddress>()
        return addresses.filter { seen.insert($0).inserted }
    }
}

// MARK: - Upstream DNS client

/// Sends real DNS queries over UDP to the Mac's configured upstream servers.
/// Bypasses /etc/hosts so the result reflects what DNS itself says.
public struct DNSClient: Sendable {
    public var servers: [String]
    public var port: UInt16
    public var timeout: TimeInterval

    public init(servers: [String]? = nil, port: UInt16 = 53, timeout: TimeInterval = 2.5) {
        self.servers = servers ?? DNSClient.systemServers()
        self.port = port
        self.timeout = timeout
    }

    /// Global DNS servers from SystemConfiguration (State:/Network/Global/DNS).
    public static func systemServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "DNSRedirect" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let addresses = value["ServerAddresses"] as? [String] else { return [] }
        // Scoped link-local servers carry an interface suffix, which Network.framework accepts.
        return addresses
    }

    /// Sends `packet` and returns the raw reply from the first server that answers.
    public func exchange(_ packet: [UInt8]) async throws -> [UInt8] {
        guard !servers.isEmpty else { throw DNSError.noUpstreamServers }
        var lastError: Error = DNSError.timeout
        for server in servers {
            do {
                return try await Self.udpExchange(packet, host: server, port: port, timeout: timeout)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func query(_ name: String, type: DNSRecordType) async throws -> DNSMessage {
        let q = DNSMessage.query(name: name, type: type)
        let reply = try DNSMessage(bytes: try await exchange(try q.encode()))
        guard reply.id == q.id else { throw DNSError.badPointer }
        return reply
    }

    /// A + AAAA addresses for `name` (following the CNAME chain the server returns).
    public func addresses(for name: String) async throws -> [IPAddress] {
        async let v4 = query(name, type: .a)
        async let v6 = query(name, type: .aaaa)
        let replies = [try? await v4, try? await v6].compactMap { $0 }
        guard !replies.isEmpty else { throw DNSError.timeout }
        let addresses = replies.flatMap { $0.answers.compactMap(\.ipAddress) }
        if addresses.isEmpty, let failing = replies.first(where: { $0.rcode != 0 }) {
            throw DNSError.serverFailure(failing.rcode)
        }
        return addresses
    }

    static func udpExchange(_ packet: [UInt8], host: String, port: UInt16, timeout: TimeInterval) async throws -> [UInt8] {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw DNSError.noUpstreamServers }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let once = ResumeOnce()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                let finish: @Sendable (Result<[UInt8], Error>) -> Void = { result in
                    guard once.claim() else { return }
                    connection.cancel()
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: Data(packet), completion: .contentProcessed { error in
                            if let error { finish(.failure(error)) }
                        })
                        connection.receiveMessage { data, _, _, error in
                            if let data { finish(.success(Array(data))) } else { finish(.failure(error ?? DNSError.truncated)) }
                        }
                    case .failed(let error):
                        finish(.failure(error))
                    case .waiting(let error):
                        finish(.failure(error))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(DNSError.timeout))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Thread-safe "resume exactly once" guard.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Resolves via upstream DNS (ignoring /etc/hosts, so stale app entries cannot feed back),
/// falling back to the system resolver when no upstream answer is available.
public struct DestinationResolver: AddressResolving {
    public init() {}

    public func resolve(_ host: String) async throws -> [IPAddress] {
        let client = DNSClient()
        if !client.servers.isEmpty, let addresses = try? await client.addresses(for: host), !addresses.isEmpty {
            return addresses
        }
        return try await SystemAddressResolver().resolve(host)
    }
}
