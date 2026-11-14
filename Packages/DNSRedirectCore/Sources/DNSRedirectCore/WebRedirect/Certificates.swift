import CryptoKit
import Foundation
import Security

/// Minimal DER (ASN.1) encoder: just enough to build X.509 v3 certificates.
enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func boolean(_ b: Bool) -> [UInt8] { tlv(0x01, [b ? 0xFF : 0x00]) }
    static func octetString(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
    static func bitString(_ b: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + b) }
    static func utf8(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static func ia5(_ s: String) -> [UInt8] { tlv(0x16, Array(s.utf8)) }
    static func explicit(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }

    static func integer(_ raw: [UInt8]) -> [UInt8] {
        var b = Array(raw.drop { $0 == 0 })
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func integer(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return integer(bytes)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        var out: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }

    static func time(_ date: Date) -> [UInt8] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            f.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Array(f.string(from: date).utf8))
        }
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Array(f.string(from: date).utf8))
    }
}

public enum CertificateError: Error, LocalizedError {
    case keyGeneration(String)
    case signing(String)
    case invalidCertificate
    case keychain(OSStatus, String)
    case trust(OSStatus)
    case identity(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keyGeneration(let m): return "Could not create a key: \(m)"
        case .signing(let m): return "Could not sign the certificate: \(m)"
        case .invalidCertificate: return "The generated certificate was rejected by macOS."
        case .keychain(let s, let what): return "Keychain error while \(what) (\(s)): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
        case .trust(let s):
            if s == errSecAuthFailed || s == errAuthorizationCanceled || s == -128 {
                return "Trusting the certificate was cancelled. HTTPS redirects stay disabled."
            }
            return "Could not change certificate trust settings (\(s)): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
        case .identity(let s): return "Could not load the server identity (\(s)): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
        }
    }
}

/// Builds and signs X.509 v3 certificates with P-256 ECDSA keys.
public enum CertificateBuilder {
    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"

    public static func publicKeyBytes(_ key: SecKey) throws -> [UInt8] {
        guard let pub = SecKeyCopyPublicKey(key) ?? Optional(key),
              let data = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw CertificateError.keyGeneration("public key unavailable")
        }
        return Array(data)
    }

    static func name(commonName: String, organization: String) -> [UInt8] {
        DER.sequence([
            DER.set([DER.sequence([DER.oid("2.5.4.10"), DER.utf8(organization)])]),
            DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8(commonName)])]),
        ])
    }

    static func extensionField(_ oid: String, critical: Bool, _ value: [UInt8]) -> [UInt8] {
        var items = [DER.oid(oid)]
        if critical { items.append(DER.boolean(true)) }
        items.append(DER.octetString(value))
        return DER.sequence(items)
    }

    /// - Parameters:
    ///   - subjectKey: private (or public) key whose public half goes into the certificate.
    ///   - issuerKey: private key that signs. For a self-signed CA, pass the same key.
    public static func make(
        commonName: String,
        organization: String = "DNS Redirect",
        subjectKey: SecKey,
        issuerCommonName: String,
        issuerKey: SecKey,
        isCA: Bool,
        dnsNames: [String] = [],
        validityDays: Int,
        now: Date = Date()
    ) throws -> (certificate: SecCertificate, der: Data) {
        let subjectPub = try publicKeyBytes(subjectKey)
        let issuerPub = try publicKeyBytes(issuerKey)
        let ski = Array(Insecure.SHA1.hash(data: subjectPub))
        let aki = Array(Insecure.SHA1.hash(data: issuerPub))

        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        serial[0] |= 0x01

        var extensions: [[UInt8]] = []
        if isCA {
            extensions.append(extensionField("2.5.29.19", critical: true, DER.sequence([DER.boolean(true), DER.integer(0)])))
            // keyCertSign (bit 5) + cRLSign (bit 6)
            extensions.append(extensionField("2.5.29.15", critical: true, DER.tlv(0x03, [0x01, 0x06])))
        } else {
            extensions.append(extensionField("2.5.29.19", critical: true, DER.sequence([])))
            // digitalSignature (bit 0)
            extensions.append(extensionField("2.5.29.15", critical: true, DER.tlv(0x03, [0x07, 0x80])))
            extensions.append(extensionField("2.5.29.37", critical: false, DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])))
            extensions.append(extensionField("2.5.29.17", critical: false,
                                             DER.sequence(dnsNames.map { DER.tlv(0x82, Array($0.utf8)) })))
            extensions.append(extensionField("2.5.29.35", critical: false, DER.sequence([DER.tlv(0x80, aki)])))
        }
        extensions.append(extensionField("2.5.29.14", critical: false, DER.octetString(ski)))

        let algorithm = DER.sequence([DER.oid(ecdsaWithSHA256)])
        let spki = DER.sequence([
            DER.sequence([DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")]),
            DER.bitString(subjectPub),
        ])
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.integer(serial),
            algorithm,
            name(commonName: issuerCommonName, organization: organization),
            DER.sequence([DER.time(now.addingTimeInterval(-86_400)), DER.time(now.addingTimeInterval(Double(validityDays) * 86_400))]),
            name(commonName: commonName, organization: organization),
            spki,
            DER.explicit(3, DER.sequence(extensions)),
        ])

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(issuerKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) as Data? else {
            throw CertificateError.signing(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        let der = Data(DER.sequence([tbs, algorithm, DER.bitString(Array(signature))]))
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw CertificateError.invalidCertificate }
        return (cert, der)
    }

    /// A P-256 key. Permanent keys live in the login keychain and cannot be exported.
    public static func makeKey(permanentTag: String? = nil, label: String? = nil) throws -> SecKey {
        var privateAttrs: [String: Any] = [kSecAttrIsPermanent as String: permanentTag != nil]
        if let permanentTag {
            privateAttrs[kSecAttrApplicationTag as String] = Data(permanentTag.utf8)
            privateAttrs[kSecAttrIsExtractable as String] = false
            if let label { privateAttrs[kSecAttrLabel as String] = label }
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttrs,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw CertificateError.keyGeneration(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return key
    }
}

/// Owns the "DNS Redirect Local CA" (key in the login keychain, certificate in the data folder),
/// its trust setting (SSL only, current user only) and the server certificate for web-redirect hosts.
public final class WebCertificateManager: @unchecked Sendable {
    public static let caCommonName = "DNS Redirect Local CA"
    static let caKeyTag = "com.dnsredirect.webredirect.ca-key"
    static let leafKeyTag = "com.dnsredirect.webredirect.server-key"

    public let directory: URL
    private var caURL: URL { directory.appendingPathComponent("WebRedirect/local-ca.cer") }

    public init(directory: URL) {
        self.directory = directory
    }

    static func findKey(tag: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else { return nil }
        return (item as! SecKey)
    }

    static func deleteKey(tag: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(tag.utf8)]
        SecItemDelete(query as CFDictionary)
    }

    /// The CA certificate if one has been created.
    public func existingCA() -> SecCertificate? {
        guard let data = try? Data(contentsOf: caURL), Self.findKey(tag: Self.caKeyTag) != nil else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    public func caCertificateURL() -> URL? { existingCA() == nil ? nil : caURL }

    /// Creates the CA key + certificate if needed. Does not change trust (no password prompt).
    @discardableResult
    public func loadOrCreateCA() throws -> SecCertificate {
        if let ca = existingCA() { return ca }
        Self.deleteKey(tag: Self.caKeyTag)
        let key = try CertificateBuilder.makeKey(permanentTag: Self.caKeyTag, label: Self.caCommonName)
        let (cert, der) = try CertificateBuilder.make(commonName: Self.caCommonName, subjectKey: key,
                                                      issuerCommonName: Self.caCommonName, issuerKey: key,
                                                      isCA: true, validityDays: 3650)
        try FileManager.default.createDirectory(at: caURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try der.write(to: caURL, options: .atomic)
        return cert
    }

    public func isTrusted() -> Bool {
        guard let ca = existingCA() else { return false }
        var settings: CFArray?
        return SecTrustSettingsCopyTrustSettings(ca, .user, &settings) == errSecSuccess
    }

    /// Marks the CA as trusted for TLS server authentication for this user. macOS shows its own
    /// password confirmation. Main thread only.
    public func trustCA() throws {
        let ca = try loadOrCreateCA()
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: ca,
                                  kSecAttrLabel as String: Self.caCommonName]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw CertificateError.keychain(status, "adding the CA certificate")
        }
        let settings: [[String: Any]] = [[
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue,
        ]]
        let trust = SecTrustSettingsSetTrustSettings(ca, .user, settings as CFArray)
        guard trust == errSecSuccess else { throw CertificateError.trust(trust) }
    }

    /// Removes trust, the CA certificate, both keys and the stored certificate file.
    public func removeAll() throws {
        if let ca = existingCA() ?? (try? Data(contentsOf: caURL)).flatMap({ SecCertificateCreateWithData(nil, $0 as CFData) }) {
            let status = SecTrustSettingsRemoveTrustSettings(ca, .user)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw CertificateError.trust(status)
            }
            let del: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: ca]
            SecItemDelete(del as CFDictionary)
        }
        Self.deleteKey(tag: Self.caKeyTag)
        Self.deleteKey(tag: Self.leafKeyTag)
        try? FileManager.default.removeItem(at: caURL)
    }

    /// A TLS server identity whose certificate covers `hosts`, signed by the local CA.
    public func serverIdentity(for hosts: [String]) throws -> SecIdentity {
        guard let caKey = Self.findKey(tag: Self.caKeyTag), existingCA() != nil else {
            throw CertificateError.keychain(errSecItemNotFound, "loading the local CA key")
        }
        let leafKey = try Self.findKey(tag: Self.leafKeyTag)
            ?? CertificateBuilder.makeKey(permanentTag: Self.leafKeyTag, label: "DNS Redirect Web Redirect Server")
        let (cert, _) = try CertificateBuilder.make(commonName: hosts.first ?? "localhost", subjectKey: leafKey,
                                                    issuerCommonName: Self.caCommonName, issuerKey: caKey,
                                                    isCA: false, dnsNames: hosts, validityDays: 365)
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard status == errSecSuccess, let identity else { throw CertificateError.identity(status) }
        return identity
    }
}
