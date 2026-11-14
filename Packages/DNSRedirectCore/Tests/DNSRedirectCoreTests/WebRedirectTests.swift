import Network
import XCTest
@testable import DNSRedirectCore

final class WebRedirectTests: XCTestCase {
    func testLocationKeepsPathForBareDomain() {
        XCTAssertEqual(WebRedirectTarget.location(for: "google.com", requestPath: "/watch?v=1"), "https://google.com/watch?v=1")
        XCTAssertEqual(WebRedirectTarget.location(for: "https://example.org", requestPath: "/a"), "https://example.org/a")
        XCTAssertEqual(WebRedirectTarget.location(for: "https://example.org/fixed", requestPath: "/a"), "https://example.org/fixed")
        XCTAssertNil(WebRedirectTarget.location(for: "javascript:alert(1)", requestPath: "/"))
    }

    func testParseRequest() {
        let raw = Array("GET /path?q=1 HTTP/1.1\r\nHost: YouTube.com:443\r\nAccept: */*\r\n\r\n".utf8)
        XCTAssertEqual(WebRedirectHTTP.parse(raw), .init(method: "GET", path: "/path?q=1", host: "youtube.com"))
        XCTAssertNil(WebRedirectHTTP.parse(Array("GET / HTTP/1.1\r\nHost: a".utf8)))
    }

    func testResponse() {
        let req = WebRedirectHTTP.Request(method: "GET", path: "/x", host: "youtube.com")
        let r = WebRedirectHTTP.response(for: req, redirects: ["youtube.com": "google.com"])
        XCTAssertEqual(r.status, 302)
        XCTAssertEqual(r.location, "https://google.com/x")
        let text = String(decoding: r.bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 302 Found\r\n"))
        XCTAssertTrue(text.contains("Location: https://google.com/x\r\n"))
        XCTAssertEqual(WebRedirectHTTP.response(for: .init(method: "GET", path: "/", host: "other.com"), redirects: [:]).status, 404)
    }

    func testEngineMapsWebRedirectToLoopbackWithWWW() async {
        var config = AppConfiguration()
        config.profiles[0].rules = [RedirectRule(source: "youtube.com", destination: "google.com", aliasMode: .webRedirect)]
        let out = await RuleEngine.evaluate(configuration: config, resolver: MockResolver(table: [:]))
        XCTAssertEqual(out.desired.webRedirects, ["youtube.com": "google.com", "www.youtube.com": "google.com"])
        XCTAssertEqual(out.desired.hostsMappings["youtube.com"], DesiredState.webRedirectAddresses)
        XCTAssertEqual(out.desired.hostsMappings["www.youtube.com"], DesiredState.webRedirectAddresses)
        XCTAssertEqual(out.evaluations[config.profiles[0].rules[0].id]?.mode, .webRedirect)
        XCTAssertTrue(out.evaluations[config.profiles[0].rules[0].id]?.state.willInstall ?? false)
    }

    func testDERInteger() {
        XCTAssertEqual(DER.integer(2), [0x02, 0x01, 0x02])
        XCTAssertEqual(DER.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
        XCTAssertEqual(DER.oid("1.2.840.10045.4.3.2"), [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        XCTAssertEqual(DER.length(300), [0x82, 0x01, 0x2C])
    }

    func testCertificateChainVerifies() throws {
        let caKey = try CertificateBuilder.makeKey()
        let leafKey = try CertificateBuilder.makeKey()
        let (ca, _) = try CertificateBuilder.make(commonName: "Test CA", subjectKey: caKey, issuerCommonName: "Test CA",
                                                  issuerKey: caKey, isCA: true, validityDays: 30)
        let (leaf, _) = try CertificateBuilder.make(commonName: "youtube.com", subjectKey: leafKey, issuerCommonName: "Test CA",
                                                    issuerKey: caKey, isCA: false, dnsNames: ["youtube.com", "www.youtube.com"], validityDays: 30)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates([leaf, ca] as CFArray, SecPolicyCreateSSL(true, "www.youtube.com" as CFString), &trust), errSecSuccess)
        SecTrustSetAnchorCertificates(trust!, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust!, true)
        var error: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(trust!, &error), "\(String(describing: error))")

        var wrongHost: SecTrust?
        SecTrustCreateWithCertificates([leaf, ca] as CFArray, SecPolicyCreateSSL(true, "google.com" as CFString), &wrongHost)
        SecTrustSetAnchorCertificates(wrongHost!, [ca] as CFArray)
        XCTAssertFalse(SecTrustEvaluateWithError(wrongHost!, nil))
    }

    func testServerAnswersOverHTTP() async throws {
        let server = WebRedirectServer()
        server.setRedirects(["youtube.com": "google.com"])
        let ports = await server.start(httpPort: 0, httpsPort: 0, identity: nil)
        defer { server.stop() }
        let port = try XCTUnwrap(ports.http, server.state.error ?? "no port")
        let result = try await WebRedirectProbe.probe(host: "youtube.com", port: port, tls: false)
        XCTAssertEqual(result, .init(status: 302, location: "https://google.com/"))
        XCTAssertEqual(server.statistics.redirected, 1)
    }
}
