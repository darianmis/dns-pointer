import Foundation

/// Resolves a hostname to addresses. Injectable for tests.
public protocol AddressResolving: Sendable {
    func resolve(_ host: String) async throws -> [IPAddress]
}

public enum RuleEvaluationState: Hashable, Sendable {
    /// Rule will be installed.
    case ready
    /// Rule will be installed but there is something to know.
    case warning(String)
    /// Rule cannot be installed.
    case error(String)
    /// Rule is switched off by the user.
    case disabled
    /// Rule is enabled but not part of the effective set (inactive profile / master switch off).
    case inactive(String)

    public var willInstall: Bool {
        switch self {
        case .ready, .warning: return true
        default: return false
        }
    }

    public var message: String? {
        switch self {
        case .warning(let m), .error(let m), .inactive(let m): return m
        default: return nil
        }
    }
}

public struct RuleEvaluation: Hashable, Sendable {
    public var ruleID: UUID
    public var state: RuleEvaluationState
    /// Addresses that will be written for this rule (hosts mode).
    public var addresses: [IPAddress]
    public var mode: AliasMode
    public var resolvedAt: Date?

    public init(ruleID: UUID, state: RuleEvaluationState, addresses: [IPAddress] = [], mode: AliasMode = .hostsSnapshot, resolvedAt: Date? = nil) {
        self.ruleID = ruleID
        self.state = state
        self.addresses = addresses
        self.mode = mode
        self.resolvedAt = resolvedAt
    }
}

/// What the system should look like for the current configuration.
public struct DesiredState: Hashable, Sendable, Codable {
    public var hostsEntries: [HostsEntry]
    /// Live alias rules served by the local resolver (source → destination domain).
    public var resolverAliases: [String: String]
    /// Hosts answered by the local web-redirect server (host → destination domain).
    public var webRedirects: [String: String]

    public init(hostsEntries: [HostsEntry] = [], resolverAliases: [String: String] = [:], webRedirects: [String: String] = [:]) {
        self.hostsEntries = hostsEntries
        self.resolverAliases = resolverAliases
        self.webRedirects = webRedirects
    }

    enum CodingKeys: String, CodingKey { case hostsEntries, resolverAliases, webRedirects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostsEntries = try c.decodeIfPresent([HostsEntry].self, forKey: .hostsEntries) ?? []
        resolverAliases = try c.decodeIfPresent([String: String].self, forKey: .resolverAliases) ?? [:]
        webRedirects = try c.decodeIfPresent([String: String].self, forKey: .webRedirects) ?? [:]
    }

    /// Loopback addresses web-redirect hosts are mapped to.
    public static let webRedirectAddresses = [IPAddress("127.0.0.1")!, IPAddress("::1")!]

    public static let empty = DesiredState()

    public var hostsMappings: [String: [IPAddress]] { ManagedHostsBlock.mappings(from: hostsEntries) }
    public var resolverDomains: [String] { resolverAliases.keys.sorted() }
}

public struct EngineOutput: Sendable {
    public var desired: DesiredState
    public var evaluations: [UUID: RuleEvaluation]
    public var resolvedCache: [String: ResolvedSnapshot]
}

public enum RuleEngine {
    /// Builds the desired state.
    /// - Parameters:
    ///   - unmanagedHosts: mappings already present in /etc/hosts outside our section (for warnings).
    ///   - refreshResolutions: when false, domain destinations with cached addresses are not re-resolved.
    ///     This keeps snapshot rules stable (CDNs rotate addresses) until the user asks for a refresh.
    public static func evaluate(
        configuration config: AppConfiguration,
        resolver: AddressResolving,
        unmanagedHosts: [String: [IPAddress]] = [:],
        refreshResolutions: Bool = true,
        now: Date = Date()
    ) async -> EngineOutput {
        var evaluations: [UUID: RuleEvaluation] = [:]
        var cache = config.resolvedCache

        struct Candidate {
            var rule: RedirectRule
            var profileName: String
            var source: String
            var destination: RuleDestination
        }

        // 1. Filter and validate.
        var candidates: [Candidate] = []
        var winners: [String: Candidate] = [:]
        for profile in config.profiles {
            for rule in profile.rules {
                guard rule.isEnabled else {
                    evaluations[rule.id] = RuleEvaluation(ruleID: rule.id, state: .disabled, mode: rule.effectiveMode)
                    continue
                }
                guard config.redirectsEnabled else {
                    evaluations[rule.id] = RuleEvaluation(ruleID: rule.id, state: .inactive("All redirects are paused."), mode: rule.effectiveMode)
                    continue
                }
                guard profile.isActive else {
                    evaluations[rule.id] = RuleEvaluation(ruleID: rule.id, state: .inactive("Profile “\(profile.name)” is inactive."), mode: rule.effectiveMode)
                    continue
                }
                let validated: (source: String, destination: RuleDestination)
                do { validated = try rule.validated() } catch {
                    evaluations[rule.id] = RuleEvaluation(ruleID: rule.id, state: .error(error.localizedDescription), mode: rule.effectiveMode)
                    continue
                }
                let candidate = Candidate(rule: rule, profileName: profile.name, source: validated.source, destination: validated.destination)
                if let first = winners[validated.source] {
                    let state: RuleEvaluationState = first.destination == validated.destination
                        ? .inactive("Duplicate of the rule in “\(first.profileName)”; that one is used.")
                        : .error("Conflicts with \(first.source) → \(first.destination.displayText) in “\(first.profileName)”. Only the first rule is applied.")
                    evaluations[rule.id] = RuleEvaluation(ruleID: rule.id, state: state, mode: rule.effectiveMode)
                    continue
                }
                if rule.effectiveMode == .liveResolver && !config.settings.resolverEnabled {
                    evaluations[rule.id] = RuleEvaluation(ruleID: rule.id, state: .error("Needs the local resolver. Turn it on under System → Local Resolver."), mode: .liveResolver)
                    continue
                }
                winners[validated.source] = candidate
                candidates.append(candidate)
            }
        }

        // 2. Resolve addresses for hosts-mode rules (following chains through other rules).
        var resolved: [String: [IPAddress]] = [:]
        var failures: [String: String] = [:]
        var notes: [String: String] = [:]

        func addresses(for host: String, visiting: Set<String>) async -> [IPAddress]? {
            if let r = resolved[host] { return r }
            if visiting.contains(host) {
                failures[host] = "Redirect loop: \(visiting.sorted().joined(separator: " → "))"
                return nil
            }
            if let c = winners[host], c.rule.effectiveMode == .webRedirect {
                resolved[host] = DesiredState.webRedirectAddresses
                return DesiredState.webRedirectAddresses
            }
            if let c = winners[host], c.rule.effectiveMode == .hostsSnapshot {
                switch c.destination {
                case .addresses(let a):
                    resolved[host] = a
                    return a
                case .domain(let d):
                    guard let a = await addresses(for: d, visiting: visiting.union([host])) else {
                        if failures[host] == nil { failures[host] = failures[d] ?? "Could not resolve \(d)." }
                        return nil
                    }
                    resolved[host] = a
                    return a
                }
            }
            // External name: reuse the snapshot unless a refresh was requested, else ask the network.
            if !refreshResolutions, let cached = cache[host], !cached.addresses.isEmpty {
                resolved[host] = cached.addresses
                return cached.addresses
            }
            do {
                let a = try await resolver.resolve(host).sorted()
                guard !a.isEmpty else { throw URLError(.cannotFindHost) }
                cache[host] = ResolvedSnapshot(addresses: a, resolvedAt: now)
                resolved[host] = a
                return a
            } catch {
                if let cached = cache[host], !cached.addresses.isEmpty {
                    let f = DateFormatter.localizedString(from: cached.resolvedAt, dateStyle: .short, timeStyle: .short)
                    notes[host] = "Could not resolve \(host) just now; using addresses cached at \(f)."
                    resolved[host] = cached.addresses
                    return cached.addresses
                }
                failures[host] = "Could not resolve \(host): \(error.localizedDescription)"
                return nil
            }
        }

        var hostsOrder: [IPAddress] = []
        var hostsByIP: [IPAddress: [String]] = [:]
        var aliases: [String: String] = [:]
        var web: [String: String] = [:]

        func addHosts(_ host: String, _ addrs: [IPAddress]) {
            for ip in addrs {
                if hostsByIP[ip] == nil { hostsOrder.append(ip) }
                hostsByIP[ip, default: []].append(host)
            }
        }

        for c in candidates {
            let id = c.rule.id
            var warnings: [String] = []
            if let existing = unmanagedHosts[c.source] {
                warnings.append("/etc/hosts already maps \(c.source) to \(existing.map(\.description).joined(separator: ", ")) outside the DNS Redirect section, and that entry may take precedence.")
            }
            switch (c.rule.effectiveMode, c.destination) {
            case (.liveResolver, .domain(let d)):
                aliases[c.source] = d
                let state: RuleEvaluationState = warnings.isEmpty ? .ready : .warning(warnings.joined(separator: " "))
                evaluations[id] = RuleEvaluation(ruleID: id, state: state, mode: .liveResolver)
            case (.webRedirect, .domain(let d)):
                var hosts = [c.source]
                // example.com also covers www.example.com unless another rule handles www.
                let www = "www." + c.source
                if DomainName.labelCount(c.source) == 2, winners[www] == nil, d != www { hosts.append(www) }
                for h in hosts {
                    web[h] = d
                    addHosts(h, DesiredState.webRedirectAddresses)
                }
                let state: RuleEvaluationState = warnings.isEmpty ? .ready : .warning(warnings.joined(separator: " "))
                evaluations[id] = RuleEvaluation(ruleID: id, state: state, addresses: DesiredState.webRedirectAddresses, mode: .webRedirect)
            default:
                guard let addrs = await addresses(for: c.source, visiting: []) else {
                    evaluations[id] = RuleEvaluation(ruleID: id, state: .error(failures[c.source] ?? "Could not determine addresses."), mode: .hostsSnapshot)
                    continue
                }
                if case .domain(let d) = c.destination, let note = notes[d] { warnings.append(note) }
                if case .addresses(let a) = c.destination, Set(a.map(\.family)).count == 1 {
                    let missing = a[0].family == .v4 ? "IPv6" : "IPv4"
                    if a[0].family == .v4 {
                        warnings.append("No \(missing) address in this rule. If \(c.source) has real \(missing) DNS records, some apps may still connect over \(missing).")
                    }
                }
                addHosts(c.source, addrs)
                var resolvedAt: Date?
                if case .domain(let d) = c.destination { resolvedAt = cache[d]?.resolvedAt }
                let state: RuleEvaluationState = warnings.isEmpty ? .ready : .warning(warnings.joined(separator: " "))
                evaluations[id] = RuleEvaluation(ruleID: id, state: state, addresses: addrs, mode: .hostsSnapshot, resolvedAt: resolvedAt)
            }
        }

        let entries = hostsOrder.map { HostsEntry(address: $0, hostnames: hostsByIP[$0] ?? []) }
        // Drop cache entries that no rule references any more.
        let referenced = Set(config.allRules.compactMap { r -> String? in
            if case .domain(let d)? = r.parsedDestination { return d }
            return nil
        })
        cache = cache.filter { referenced.contains($0.key) }
        return EngineOutput(desired: DesiredState(hostsEntries: entries, resolverAliases: aliases, webRedirects: web),
                            evaluations: evaluations, resolvedCache: cache)
    }
}
