import XCTest
@testable import DNSRedirectCore

final class DNSMessageTests: XCTestCase {
    func testQueryRoundTrip() throws {
        let q = DNSMessage.query(id: 0xBEEF, name: "Old.Example.com", type: .aaaa)
        let bytes = try q.encode()
        XCTAssertEqual(Array(bytes.prefix(4)), [0xBE, 0xEF, 0x01, 0x00])
        let parsed = try DNSMessage(bytes: bytes)
        XCTAssertEqual(parsed.questions, [DNSQuestion(name: "old.example.com", type: 28)])
        XCTAssertFalse(parsed.isResponse)
    }

    func testResponseWithCNAMEAndAddresses() throws {
        let q = DNSMessage.query(id: 7, name: "a.test", type: .a)
        let r = DNSMessage.response(to: q, answers: [
            .cname("a.test", target: "b.test", ttl: 30),
            .address("b.test", IPAddress("10.0.0.1")!, ttl: 30),
        ])
        let parsed = try DNSMessage(bytes: try r.encode())
        XCTAssertTrue(parsed.isResponse)
        XCTAssertEqual(parsed.id, 7)
        XCTAssertEqual(parsed.rcode, 0)
        XCTAssertTrue(parsed.recursionDesired)
        XCTAssertEqual(parsed.answers.first?.cnameTarget, "b.test")
        XCTAssertEqual(parsed.answers.last?.ipAddress, IPAddress("10.0.0.1"))
    }

    func testDecodesCompressedNames() throws {
        // Hand-built reply: question example.com A; answer uses pointer 0xC00C and a CNAME with a
        // compressed suffix pointing back into the question.
        var b: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0]
        b += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        b += [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6, 3] + Array("www".utf8) + [0xC0, 0x0C]
        b += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        let m = try DNSMessage(bytes: b)
        XCTAssertEqual(m.answers.count, 2)
        XCTAssertEqual(m.answers[0].name, "example.com")
        XCTAssertEqual(m.answers[0].cnameTarget, "www.example.com")
        XCTAssertEqual(m.answers[1].ipAddress, IPAddress("93.184.216.34"))
    }

    func testRejectsMalformedMessages() {
        XCTAssertThrowsError(try DNSMessage(bytes: [0, 1, 2]))
        // Pointer loop.
        let loop: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1]
        XCTAssertThrowsError(try DNSMessage(bytes: loop))
        XCTAssertThrowsError(try DNSMessage.encodeName(String(repeating: "a", count: 64) + ".com"))
    }
}

struct MockUpstream: UpstreamDNS {
    var records: [String: [String]]
    var forwardedReply: [UInt8]?

    func addresses(for name: String, type: DNSRecordType) async throws -> [IPAddress] {
        (records[name] ?? []).compactMap(IPAddress.init)
    }

    func forward(_ packet: [UInt8]) async throws -> [UInt8] {
        guard let forwardedReply else { throw DNSError.noUpstreamServers }
        let q = try DNSMessage(bytes: packet)
        var reply = try DNSMessage(bytes: forwardedReply)
        reply.id = q.id
        return try reply.encode()
    }
}

final class LocalDNSServerTests: XCTestCase {
    func makeServer(forward: [UInt8]? = nil) -> LocalDNSServer {
        let server = LocalDNSServer(upstream: MockUpstream(records: ["new.example.com": ["203.0.113.7", "2001:db8::7"]], forwardedReply: forward))
        server.setAliases(["old.example.com": "new.example.com", "older.example.com": "old.example.com"])
        return server
    }

    func testAnswersAliasWithCNAMEChainAndAddresses() async throws {
        let server = makeServer()
        let reply = await server.respond(to: try DNSMessage.query(id: 9, name: "older.example.com", type: .a).encode())
        let m = try DNSMessage(bytes: try XCTUnwrap(reply))
        XCTAssertEqual(m.id, 9)
        XCTAssertEqual(m.answers.compactMap(\.cnameTarget), ["old.example.com", "new.example.com"])
        XCTAssertEqual(m.answers.compactMap(\.ipAddress), [IPAddress("203.0.113.7")!], "A query returns only IPv4")

        let v6Reply = await server.respond(to: try DNSMessage.query(name: "old.example.com", type: .aaaa).encode())
        let v6 = try DNSMessage(bytes: try XCTUnwrap(v6Reply))
        XCTAssertEqual(v6.answers.compactMap(\.ipAddress), [IPAddress("2001:db8::7")!])
    }

    func testNonAliasQueriesAreForwardedOrFailCleanly() async throws {
        let upstreamReply = try DNSMessage.response(to: DNSMessage.query(id: 1, name: "www.old.example.com", type: .a),
                                                     answers: [.address("www.old.example.com", IPAddress("1.2.3.4")!, ttl: 60)],
                                                     authoritative: false).encode()
        let forwarded = await makeServer(forward: upstreamReply)
            .respond(to: try DNSMessage.query(id: 55, name: "www.old.example.com", type: .a).encode())
        var m = try DNSMessage(bytes: try XCTUnwrap(forwarded))
        XCTAssertEqual(m.id, 55)
        XCTAssertEqual(m.answers.first?.ipAddress, IPAddress("1.2.3.4"))

        let failed = await makeServer().respond(to: try DNSMessage.query(id: 56, name: "x.old.example.com", type: .a).encode())
        m = try DNSMessage(bytes: try XCTUnwrap(failed))
        XCTAssertEqual(m.rcode, 2, "SERVFAIL when no upstream is available")
    }

    /// End-to-end over a real loopback UDP socket.
    func testServesOverUDP() async throws {
        let server = makeServer()
        let port = try await server.start(port: 0)
        defer { server.stop() }
        XCTAssertEqual(server.state, .running(port: port))

        let client = DNSClient(servers: ["127.0.0.1"], port: port, timeout: 3)
        let reply = try await client.query("old.example.com", type: .a)
        XCTAssertEqual(reply.answers.first?.cnameTarget, "new.example.com")
        XCTAssertEqual(reply.answers.compactMap(\.ipAddress), [IPAddress("203.0.113.7")!])
        XCTAssertEqual(server.statistics.answered, 1)
    }

    func testPortInUseReportsFailure() async throws {
        let first = makeServer()
        let port = try await first.start(port: 0)
        defer { first.stop() }
        let second = makeServer()
        do {
            _ = try await second.start(port: port)
            // Some kernels allow reuse with SO_REUSEADDR on UDP; either way the server must be in a sane state.
            second.stop()
        } catch {
            if case .failed(let m) = second.state { XCTAssertFalse(m.isEmpty) } else { XCTFail("state: \(second.state)") }
        }
    }
}

final class StorageTests: XCTestCase {
    func testConfigurationRoundTripAndCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dnsredirect-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigurationStore(directory: dir)
        XCTAssertNil(store.load().warning)

        var config = AppConfiguration(profiles: [Profile(name: "Home", rules: [RedirectRule(source: "a.test", destination: "1.1.1.1", createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_100))])])
        config.settings.resolverPort = 54000
        try store.save(config)
        XCTAssertEqual(store.load().0, config)

        try Data("{ not json".utf8).write(to: store.configurationURL)
        let (fresh, warning) = store.load()
        XCTAssertNotNil(warning)
        XCTAssertEqual(fresh.profiles.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("configuration.corrupt-") })
    }

    func testDecodesOlderConfigWithMissingKeys() throws {
        let json = #"{"profiles":[{"name":"P","rules":[{"source":"A.test","destination":"1.1.1.1"}]}]}"#
        let config = try ConfigurationStore.decoder.decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.profiles[0].rules[0].source, "a.test")
        XCTAssertTrue(config.profiles[0].rules[0].isEnabled)
        XCTAssertTrue(config.settings.autoApply)
    }

    func testExportImportMerge() throws {
        let rules = [RedirectRule(source: "a.test", destination: "1.1.1.1"), RedirectRule(source: "b.test", destination: "c.test")]
        let data = try RulesDocument(profiles: [Profile(name: "Default", rules: rules), Profile(name: "Lab", rules: rules)]).encoded()

        var config = AppConfiguration(profiles: [Profile(name: "default", rules: [rules[0]])])
        let summary = config.merge(try RulesDocument.decode(data))
        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(summary.duplicatesSkipped, 1)
        XCTAssertEqual(summary.profilesCreated, 1)
        XCTAssertEqual(config.profiles.map(\.name), ["default", "Lab"])
        XCTAssertNotEqual(config.profiles[1].rules[0].id, rules[0].id, "imported rules get fresh ids")
    }

    func testImportsBareRuleArrayAndReportsInvalid() throws {
        let json = #"[{"source":"good.test","destination":"10.0.0.1"},{"source":"bad host","destination":"10.0.0.1"}]"#
        var config = AppConfiguration()
        let summary = config.merge(try RulesDocument.decode(Data(json.utf8)))
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.invalid.count, 1)
        XCTAssertThrowsError(try RulesDocument.decode(Data(#"{"hello":1}"#.utf8)))
    }
}
