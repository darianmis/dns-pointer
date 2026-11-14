import Foundation

/// What kind of destination a rule points to.
public enum RuleKind: String, Codable, Sendable {
    case ip
    case domain

    public var label: String { self == .ip ? "IP" : "Domain" }
}

/// How a domain → domain rule is realised on the system.
public enum AliasMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Resolve the destination now and write its addresses into /etc/hosts.
    case hostsSnapshot
    /// Answer queries dynamically from the bundled local DNS resolver (CNAME-style alias).
    case liveResolver
    /// Point the source at this Mac and answer browsers with an HTTP(S) redirect to the destination,
    /// so the address bar actually changes to the destination site.
    case webRedirect

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hostsSnapshot: return "Snapshot (hosts file)"
        case .liveResolver: return "Live alias (local resolver)"
        case .webRedirect: return "Web redirect (browser)"
        }
    }
}

public enum RuleValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidSource(DomainValidationError)
    case invalidDestination(String)
    case selfReference
    case mixedDestination
    case resolverNeedsMultiLabel

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let e): return "Source: \(e.localizedDescription)"
        case .invalidDestination(let m): return "Destination: \(m)"
        case .selfReference: return "A domain cannot redirect to itself."
        case .mixedDestination: return "Destination must be either IP addresses or a single domain, not both."
        case .resolverNeedsMultiLabel:
            return "Live resolver aliases need a multi-label domain (e.g. app.example.com). Single labels would hijack an entire top-level domain."
        }
    }
}

/// A parsed, validated destination.
public enum RuleDestination: Hashable, Sendable {
    case addresses([IPAddress])
    case domain(String)

    public var kind: RuleKind {
        if case .addresses = self { return .ip }
        return .domain
    }

    /// Accepts one or more IP addresses (comma/space separated) or exactly one domain.
    public static func parse(_ raw: String) throws -> RuleDestination {
        let tokens = DomainName.splitList(raw)
        guard !tokens.isEmpty else { throw RuleValidationError.invalidDestination("Enter an IP address or domain.") }
        let ips = tokens.compactMap(IPAddress.init)
        if ips.count == tokens.count {
            var seen = Set<IPAddress>()
            return .addresses(ips.filter { seen.insert($0).inserted })
        }
        if !ips.isEmpty { throw RuleValidationError.mixedDestination }
        guard tokens.count == 1 else {
            throw RuleValidationError.invalidDestination("Only one destination domain is allowed per rule.")
        }
        do {
            return .domain(try DomainName.validate(tokens[0], allowReserved: true))
        } catch let e as DomainValidationError {
            throw RuleValidationError.invalidDestination(e.localizedDescription)
        }
    }

    public var displayText: String {
        switch self {
        case .addresses(let a): return a.map(\.description).joined(separator: ", ")
        case .domain(let d): return d
        }
    }
}

public struct RedirectRule: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var source: String
    public var destination: String
    public var isEnabled: Bool
    public var aliasMode: AliasMode
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), source: String, destination: String, isEnabled: Bool = true,
                aliasMode: AliasMode = .hostsSnapshot, note: String = "",
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.source = DomainName.normalize(source)
        self.destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.aliasMode = aliasMode
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var parsedDestination: RuleDestination? { try? RuleDestination.parse(destination) }

    public var kind: RuleKind {
        parsedDestination?.kind ?? (DomainName.splitList(destination).allSatisfy { IPAddress($0) != nil } ? .ip : .domain)
    }

    /// Effective alias mode (IP rules always go to the hosts file).
    public var effectiveMode: AliasMode { kind == .ip ? .hostsSnapshot : aliasMode }

    /// Full validation of the rule in isolation.
    public func validated() throws -> (source: String, destination: RuleDestination) {
        let src: String
        do { src = try DomainName.validate(source) } catch let e as DomainValidationError {
            throw RuleValidationError.invalidSource(e)
        }
        let dest = try RuleDestination.parse(destination)
        if case .domain(let d) = dest, d == src { throw RuleValidationError.selfReference }
        if dest.kind == .domain, aliasMode == .liveResolver, DomainName.labelCount(src) < 2 {
            throw RuleValidationError.resolverNeedsMultiLabel
        }
        return (src, dest)
    }

    /// Two rules are duplicates when they map the same source to the same destination.
    public func isDuplicate(of other: RedirectRule) -> Bool {
        source == other.source && parsedDestination != nil && parsedDestination == other.parsedDestination
    }

    enum CodingKeys: String, CodingKey {
        case id, source, destination, isEnabled = "enabled", aliasMode = "mode", note, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = DomainName.normalize(try c.decode(String.self, forKey: .source))
        destination = try c.decode(String.self, forKey: .destination).trimmingCharacters(in: .whitespacesAndNewlines)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        aliasMode = try c.decodeIfPresent(AliasMode.self, forKey: .aliasMode) ?? .hostsSnapshot
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct Profile: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var isActive: Bool
    public var rules: [RedirectRule]

    public init(id: UUID = UUID(), name: String, isActive: Bool = true, rules: [RedirectRule] = []) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case id, name, isActive = "active", rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Imported"
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        rules = try c.decodeIfPresent([RedirectRule].self, forKey: .rules) ?? []
    }
}

public enum AppearancePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case dark, system
    public var id: String { rawValue }
}

public struct AppSettings: Hashable, Sendable, Codable {
    /// Push rule changes to the system automatically (prompts for admin when needed).
    public var autoApply: Bool = true
    /// Re-apply rules at launch if the system state drifted.
    public var applyAtLaunch: Bool = true
    public var showMenuBarExtra: Bool = true
    public var resolverEnabled: Bool = false
    public var resolverPort: UInt16 = 53535
    /// Remove /etc/resolver entries on quit so aliased domains don't fail while the app is closed.
    public var removeResolverConfigOnQuit: Bool = true
    public var appearance: AppearancePreference = .dark

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        autoApply = try c.decodeIfPresent(Bool.self, forKey: .autoApply) ?? d.autoApply
        applyAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .applyAtLaunch) ?? d.applyAtLaunch
        showMenuBarExtra = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarExtra) ?? d.showMenuBarExtra
        resolverEnabled = try c.decodeIfPresent(Bool.self, forKey: .resolverEnabled) ?? d.resolverEnabled
        resolverPort = try c.decodeIfPresent(UInt16.self, forKey: .resolverPort) ?? d.resolverPort
        removeResolverConfigOnQuit = try c.decodeIfPresent(Bool.self, forKey: .removeResolverConfigOnQuit) ?? d.removeResolverConfigOnQuit
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? d.appearance
    }
}

/// Addresses that a domain destination resolved to at a point in time.
public struct ResolvedSnapshot: Hashable, Sendable, Codable {
    public var addresses: [IPAddress]
    public var resolvedAt: Date

    public init(addresses: [IPAddress], resolvedAt: Date = Date()) {
        self.addresses = addresses
        self.resolvedAt = resolvedAt
    }
}

public struct AppConfiguration: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int = AppConfiguration.currentVersion
    /// Master switch: when false no application-managed overrides are installed.
    public var redirectsEnabled: Bool = true
    public var profiles: [Profile]
    public var settings: AppSettings = AppSettings()
    public var resolvedCache: [String: ResolvedSnapshot] = [:]

    public init(profiles: [Profile] = [Profile(name: "Default")]) {
        self.profiles = profiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        redirectsEnabled = try c.decodeIfPresent(Bool.self, forKey: .redirectsEnabled) ?? true
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? [Profile(name: "Default")]
        if profiles.isEmpty { profiles = [Profile(name: "Default")] }
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        resolvedCache = try c.decodeIfPresent([String: ResolvedSnapshot].self, forKey: .resolvedCache) ?? [:]
    }

    public var allRules: [RedirectRule] { profiles.flatMap(\.rules) }

    public func profile(containing ruleID: UUID) -> Profile? {
        profiles.first { $0.rules.contains { $0.id == ruleID } }
    }

    public func rule(id: UUID) -> RedirectRule? {
        for p in profiles { if let r = p.rules.first(where: { $0.id == id }) { return r } }
        return nil
    }
}
