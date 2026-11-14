import XCTest
@testable import DNSRedirectCore

final class ValidationTests: XCTestCase {
    func testIPv4Parsing() {
        XCTAssertEqual(IPAddress("192.168.1.100")?.description, "192.168.1.100")
        XCTAssertEqual(IPAddress(" 127.0.0.1 ")?.family, .v4)
        XCTAssertNil(IPAddress("256.1.1.1"))
        XCTAssertNil(IPAddress("1.2.3"))
        XCTAssertNil(IPAddress("example.com"))
        XCTAssertTrue(IPAddress("127.0.0.1")!.isLoopback)
    }

    func testIPv6ParsingAndCanonicalForm() {
        XCTAssertEqual(IPAddress("::1")?.family, .v6)
        XCTAssertEqual(IPAddress("2001:0db8:0000:0000:0000:0000:0000:0001")?.description, "2001:db8::1")
        XCTAssertNil(IPAddress("fe80::1%en0"), "scoped addresses are rejected")
        XCTAssertNil(IPAddress("2001:db8:::1"))
        XCTAssertTrue(IPAddress("::1")!.isLoopback)
    }

    func testIPCodableRoundTrip() throws {
        let ip = IPAddress("2001:db8::5")!
        let data = try JSONEncoder().encode([ip])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"2001:db8::5\"]")
        XCTAssertEqual(try JSONDecoder().decode([IPAddress].self, from: data), [ip])
    }

    func testDomainNormalization() {
        XCTAssertEqual(DomainName.normalize("  Example.COM. "), "example.com")
        XCTAssertEqual(DomainName.normalize("https://www.example.com:8443/path?q=1"), "www.example.com")
        XCTAssertEqual(DomainName.normalize("user@host.example.org"), "host.example.org")
    }

    func testDomainValidation() throws {
        XCTAssertEqual(try DomainName.validate("Test.Local"), "test.local")
        XCTAssertEqual(try DomainName.validate("devbox"), "devbox")
        XCTAssertEqual(try DomainName.validate("xn--bcher-kva.example"), "xn--bcher-kva.example")
        XCTAssertThrowsError(try DomainName.validate("")) { XCTAssertEqual($0 as? DomainValidationError, .empty) }
        XCTAssertThrowsError(try DomainName.validate("*.example.com")) { XCTAssertEqual($0 as? DomainValidationError, .wildcard) }
        XCTAssertThrowsError(try DomainName.validate("a..b")) { XCTAssertEqual($0 as? DomainValidationError, .emptyLabel) }
        XCTAssertThrowsError(try DomainName.validate("-bad.com"))
        XCTAssertThrowsError(try DomainName.validate("bad_name.com"))
        XCTAssertThrowsError(try DomainName.validate("bücher.de")) { XCTAssertEqual($0 as? DomainValidationError, .nonASCII) }
        XCTAssertThrowsError(try DomainName.validate("10.0.0.1")) { XCTAssertEqual($0 as? DomainValidationError, .isIPAddress) }
        XCTAssertThrowsError(try DomainName.validate("localhost")) { XCTAssertEqual($0 as? DomainValidationError, .reserved("localhost")) }
        XCTAssertThrowsError(try DomainName.validate(String(repeating: "a", count: 64) + ".com"))
        XCTAssertNoThrow(try DomainName.validate("localhost", allowReserved: true))
    }

    func testDestinationParsing() throws {
        XCTAssertEqual(try RuleDestination.parse("192.168.1.100"), .addresses([IPAddress("192.168.1.100")!]))
        XCTAssertEqual(try RuleDestination.parse("10.0.0.1, ::1 10.0.0.1"), .addresses([IPAddress("10.0.0.1")!, IPAddress("::1")!]))
        XCTAssertEqual(try RuleDestination.parse("New.Example.com"), .domain("new.example.com"))
        XCTAssertEqual(try RuleDestination.parse("localhost"), .domain("localhost"), "reserved names are fine as destinations")
        XCTAssertThrowsError(try RuleDestination.parse("10.0.0.1, example.com")) { XCTAssertEqual($0 as? RuleValidationError, .mixedDestination) }
        XCTAssertThrowsError(try RuleDestination.parse("a.com b.com"))
        XCTAssertThrowsError(try RuleDestination.parse(""))
    }

    func testRuleValidation() {
        XCTAssertNoThrow(try RedirectRule(source: "example.com", destination: "1.2.3.4").validated())
        XCTAssertThrowsError(try RedirectRule(source: "a.com", destination: "A.com").validated()) {
            XCTAssertEqual($0 as? RuleValidationError, .selfReference)
        }
        XCTAssertThrowsError(try RedirectRule(source: "intranet", destination: "a.com", aliasMode: .liveResolver).validated()) {
            XCTAssertEqual($0 as? RuleValidationError, .resolverNeedsMultiLabel)
        }
        XCTAssertEqual(RedirectRule(source: "a.com", destination: "1.1.1.1").kind, .ip)
        XCTAssertEqual(RedirectRule(source: "a.com", destination: "b.com").kind, .domain)
        XCTAssertEqual(RedirectRule(source: "a.com", destination: "1.1.1.1", aliasMode: .liveResolver).effectiveMode, .hostsSnapshot)
    }

    func testSplitList() {
        XCTAssertEqual(DomainName.splitList("a.com, b.com\nc.com;d.com  e.com"), ["a.com", "b.com", "c.com", "d.com", "e.com"])
    }
}
