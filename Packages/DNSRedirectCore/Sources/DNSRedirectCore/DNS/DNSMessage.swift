import Foundation

public enum DNSRecordType: UInt16, Sendable {
    case a = 1
    case cname = 5
    case aaaa = 28
}

public enum DNSError: Error, LocalizedError, Equatable, Sendable {
    case truncated
    case badPointer
    case labelTooLong
    case nameTooLong
    case timeout
    case noUpstreamServers
    case serverFailure(UInt8)

    public var errorDescription: String? {
        switch self {
        case .truncated: return "The DNS message was truncated."
        case .badPointer: return "The DNS message has an invalid compression pointer."
        case .labelTooLong: return "A DNS label is longer than 63 bytes."
        case .nameTooLong: return "A DNS name is longer than 255 bytes."
        case .timeout: return "The DNS server did not respond in time."
        case .noUpstreamServers: return "No upstream DNS servers are configured on this Mac."
        case .serverFailure(let code):
            switch code {
            case 3: return "The domain does not exist (NXDOMAIN)."
            case 2: return "The DNS server failed (SERVFAIL)."
            case 5: return "The DNS server refused the query."
            default: return "The DNS server returned error code \(code)."
            }
        }
    }
}

public struct DNSQuestion: Hashable, Sendable {
    public var name: String
    public var type: UInt16
    public var qclass: UInt16

    public init(name: String, type: UInt16, qclass: UInt16 = 1) {
        self.name = name
        self.type = type
        self.qclass = qclass
    }
}

public struct DNSRecord: Hashable, Sendable {
    public var name: String
    public var type: UInt16
    public var rclass: UInt16
    public var ttl: UInt32
    /// Raw RDATA as it appears on the wire for A/AAAA; for CNAME, use `cnameTarget`.
    public var rdata: [UInt8]
    public var cnameTarget: String?

    public init(name: String, type: UInt16, rclass: UInt16 = 1, ttl: UInt32, rdata: [UInt8] = [], cnameTarget: String? = nil) {
        self.name = name
        self.type = type
        self.rclass = rclass
        self.ttl = ttl
        self.rdata = rdata
        self.cnameTarget = cnameTarget
    }

    public static func address(_ name: String, _ ip: IPAddress, ttl: UInt32) -> DNSRecord {
        DNSRecord(name: name, type: ip.family == .v4 ? DNSRecordType.a.rawValue : DNSRecordType.aaaa.rawValue, ttl: ttl, rdata: ip.bytes)
    }

    public static func cname(_ name: String, target: String, ttl: UInt32) -> DNSRecord {
        DNSRecord(name: name, type: DNSRecordType.cname.rawValue, ttl: ttl, cnameTarget: target)
    }

    public var ipAddress: IPAddress? {
        guard type == DNSRecordType.a.rawValue || type == DNSRecordType.aaaa.rawValue else { return nil }
        return IPAddress(bytes: rdata)
    }
}

/// Minimal RFC 1035 message codec covering what the resolver and lookup tools need.
public struct DNSMessage: Hashable, Sendable {
    public var id: UInt16
    public var flags: UInt16
    public var questions: [DNSQuestion]
    public var answers: [DNSRecord]
    public var authority: [DNSRecord] = []
    public var additional: [DNSRecord] = []

    public init(id: UInt16, flags: UInt16, questions: [DNSQuestion], answers: [DNSRecord] = []) {
        self.id = id
        self.flags = flags
        self.questions = questions
        self.answers = answers
    }

    public var isResponse: Bool { flags & 0x8000 != 0 }
    public var rcode: UInt8 { UInt8(flags & 0x000F) }
    public var recursionDesired: Bool { flags & 0x0100 != 0 }

    public static func query(id: UInt16 = .random(in: 0...UInt16.max), name: String, type: DNSRecordType) -> DNSMessage {
        DNSMessage(id: id, flags: 0x0100, questions: [DNSQuestion(name: name, type: type.rawValue)])
    }

    /// Builds a response to `query` with the given answers and rcode.
    public static func response(to query: DNSMessage, answers: [DNSRecord], rcode: UInt8 = 0, authoritative: Bool = true) -> DNSMessage {
        var flags: UInt16 = 0x8000 | 0x0080 // QR + RA
        if authoritative { flags |= 0x0400 }
        flags |= query.flags & 0x0100 // copy RD
        flags |= UInt16(rcode & 0x0F)
        return DNSMessage(id: query.id, flags: flags, questions: query.questions, answers: answers)
    }

    // MARK: Encoding

    public func encode() throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(512)
        func u16(_ v: UInt16) { out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF)) }
        func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xFFFF)) }
        u16(id); u16(flags)
        u16(UInt16(questions.count)); u16(UInt16(answers.count))
        u16(UInt16(authority.count)); u16(UInt16(additional.count))
        for q in questions {
            out += try Self.encodeName(q.name)
            u16(q.type); u16(q.qclass)
        }
        for r in answers + authority + additional {
            out += try Self.encodeName(r.name)
            u16(r.type); u16(r.rclass); u32(r.ttl)
            let data = try r.cnameTarget.map(Self.encodeName) ?? r.rdata
            u16(UInt16(data.count))
            out += data
        }
        return out
    }

    public static func encodeName(_ name: String) throws -> [UInt8] {
        var out: [UInt8] = []
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        if !trimmed.isEmpty {
            for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
                let bytes = Array(label.utf8)
                guard !bytes.isEmpty, bytes.count <= 63 else { throw DNSError.labelTooLong }
                out.append(UInt8(bytes.count))
                out += bytes
            }
        }
        out.append(0)
        guard out.count <= 255 else { throw DNSError.nameTooLong }
        return out
    }

    // MARK: Decoding

    public init(bytes: [UInt8]) throws {
        var reader = Reader(bytes: bytes)
        id = try reader.u16()
        flags = try reader.u16()
        let qd = try reader.u16(), an = try reader.u16(), ns = try reader.u16(), ar = try reader.u16()
        questions = []
        for _ in 0..<qd {
            let name = try reader.name()
            questions.append(DNSQuestion(name: name, type: try reader.u16(), qclass: try reader.u16()))
        }
        func records(_ n: UInt16) throws -> [DNSRecord] {
            var result: [DNSRecord] = []
            for _ in 0..<n {
                let name = try reader.name()
                let type = try reader.u16(), rclass = try reader.u16(), ttl = try reader.u32()
                let length = Int(try reader.u16())
                let start = reader.offset
                guard start + length <= bytes.count else { throw DNSError.truncated }
                var record = DNSRecord(name: name, type: type, rclass: rclass, ttl: ttl, rdata: Array(bytes[start..<start + length]))
                if type == DNSRecordType.cname.rawValue {
                    var sub = reader
                    record.cnameTarget = try sub.name()
                }
                reader.offset = start + length
                result.append(record)
            }
            return result
        }
        answers = try records(an)
        authority = try records(ns)
        // Additional records (e.g. EDNS OPT) are parsed when possible but not required.
        additional = (try? records(ar)) ?? []
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw DNSError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
        mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }

        mutating func name() throws -> String {
            var labels: [String] = []
            var position = offset
            var jumped = false
            var jumps = 0
            var total = 0
            while true {
                guard position < bytes.count else { throw DNSError.truncated }
                let length = Int(bytes[position])
                if length & 0xC0 == 0xC0 {
                    guard position + 1 < bytes.count else { throw DNSError.truncated }
                    let pointer = (length & 0x3F) << 8 | Int(bytes[position + 1])
                    jumps += 1
                    guard jumps < 32, pointer < bytes.count else { throw DNSError.badPointer }
                    if !jumped { offset = position + 2 }
                    jumped = true
                    position = pointer
                    continue
                }
                guard length & 0xC0 == 0 else { throw DNSError.badPointer }
                position += 1
                if length == 0 { break }
                guard position + length <= bytes.count else { throw DNSError.truncated }
                total += length + 1
                guard total <= 255 else { throw DNSError.nameTooLong }
                labels.append(String(decoding: bytes[position..<position + length], as: UTF8.self))
                position += length
            }
            if !jumped { offset = position }
            return labels.joined(separator: ".").lowercased()
        }
    }
}
