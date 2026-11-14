import Foundation

public enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooLong
    case emptyLabel
    case labelTooLong(String)
    case invalidCharacters(String)
    case hyphenPosition(String)
    case wildcard
    case nonASCII
    case isIPAddress
    case reserved(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter a domain name."
        case .tooLong: return "Domain names must be 253 characters or fewer."
        case .emptyLabel: return "Domain contains an empty label (\"..\")."
        case .labelTooLong(let l): return "Label \"\(l)\" is longer than 63 characters."
        case .invalidCharacters(let l): return "Label \"\(l)\" may only contain letters, digits and hyphens."
        case .hyphenPosition(let l): return "Label \"\(l)\" cannot start or end with a hyphen."
        case .wildcard: return "Wildcards are not supported by /etc/hosts. Use a resolver rule to cover a domain and its subdomains."
        case .nonASCII: return "Internationalized names must be entered in punycode form (xn--…)."
        case .isIPAddress: return "This is an IP address, not a domain name."
        case .reserved(let n): return "\"\(n)\" is a reserved system hostname and cannot be redirected."
        }
    }
}

public enum DomainName {
    /// Hostnames macOS relies on; redirecting them can break the system.
    public static let reservedNames: Set<String> = [
        "localhost", "localhost.localdomain", "broadcasthost",
        "ip6-localhost", "ip6-loopback", "local",
    ]

    /// Lowercases, trims and strips a URL scheme/path/port or trailing dot that users commonly paste.
    public static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = text.range(of: "://") {
            text = String(text[schemeRange.upperBound...])
        }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<slash])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        // Strip a :port suffix, but never touch IPv6-looking strings.
        if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":"),
           text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            text = String(text[..<colon])
        }
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Validates and returns the normalized domain.
    @discardableResult
    public static func validate(_ raw: String, allowReserved: Bool = false) throws -> String {
        let name = normalize(raw)
        guard !name.isEmpty else { throw DomainValidationError.empty }
        if IPAddress(name) != nil { throw DomainValidationError.isIPAddress }
        if name.contains("*") { throw DomainValidationError.wildcard }
        guard name.unicodeScalars.allSatisfy(\.isASCII) else { throw DomainValidationError.nonASCII }
        guard name.utf8.count <= 253 else { throw DomainValidationError.tooLong }
        if !allowReserved, reservedNames.contains(name) { throw DomainValidationError.reserved(name) }

        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            let l = String(label)
            guard !l.isEmpty else { throw DomainValidationError.emptyLabel }
            guard l.utf8.count <= 63 else { throw DomainValidationError.labelTooLong(l) }
            guard l.allSatisfy({ allowed.contains($0) }) else { throw DomainValidationError.invalidCharacters(l) }
            guard !l.hasPrefix("-"), !l.hasSuffix("-") else { throw DomainValidationError.hyphenPosition(l) }
        }
        return name
    }

    public static func isValid(_ raw: String) -> Bool {
        (try? validate(raw)) != nil
    }

    public static func labelCount(_ name: String) -> Int {
        name.split(separator: ".").count
    }

    /// Splits user input such as "a.com, b.com\nc.com" into individual entries.
    public static func splitList(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",; \t\n\r"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
