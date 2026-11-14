import Darwin
import Foundation

/// A validated IPv4 or IPv6 address stored in network byte order.
public struct IPAddress: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public enum Family: String, Codable, Sendable {
        case v4
        case v6
    }

    public let family: Family
    public let bytes: [UInt8]

    /// Parses a textual IPv4/IPv6 address. Scoped IPv6 addresses (`%en0`) are rejected
    /// because they are not portable in `/etc/hosts`.
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 45, !text.contains("%") else { return nil }

        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            family = .v4
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            family = .v6
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    public init?(bytes: [UInt8]) {
        switch bytes.count {
        case 4: family = .v4
        case 16: family = .v6
        default: return nil
        }
        self.bytes = bytes
    }

    /// Canonical textual form (e.g. compressed IPv6).
    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let af = family == .v4 ? AF_INET : AF_INET6
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            buffer.withUnsafeMutableBufferPointer { out in
                inet_ntop(af, raw.baseAddress, out.baseAddress, socklen_t(out.count)) != nil
            }
        }
        guard ok else { return "<invalid>" }
        return String(cString: buffer)
    }

    public var isLoopback: Bool {
        switch family {
        case .v4: return bytes[0] == 127
        case .v6: return bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }

    public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }

    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        if lhs.family != rhs.family { return lhs.family == .v4 }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = IPAddress(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP address: \(text)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
