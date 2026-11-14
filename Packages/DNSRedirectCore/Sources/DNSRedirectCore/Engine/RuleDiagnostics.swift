import Foundation

public struct RuleIssue: Hashable, Sendable {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var message: String
}

public enum RuleConflictChecker {
    /// Problems with saving `rule` into `profileID`, ignoring the rule with the same id.
    public static func issues(for rule: RedirectRule, in profileID: UUID, configuration: AppConfiguration) -> [RuleIssue] {
        var issues: [RuleIssue] = []
        for profile in configuration.profiles {
            for other in profile.rules where other.id != rule.id && other.source == rule.source {
                if profile.id == profileID {
                    if other.isDuplicate(of: rule) {
                        issues.append(RuleIssue(severity: .error, message: "\(rule.source) already redirects to \(other.destination) in this profile."))
                    } else {
                        issues.append(RuleIssue(severity: .error, message: "\(rule.source) already has a rule in this profile (→ \(other.destination)). Edit that rule instead."))
                    }
                } else if profile.isActive && other.isEnabled {
                    issues.append(RuleIssue(severity: .warning, message: "Active profile “\(profile.name)” also maps \(rule.source) (→ \(other.destination)). Only one rule can be applied."))
                }
            }
        }
        if case .domain(let d)? = rule.parsedDestination,
           let loop = configuration.allRules.first(where: { $0.source == d && $0.parsedDestination == .domain(rule.source) }) {
            issues.append(RuleIssue(severity: .error, message: "This would create a loop with \(loop.source) → \(loop.destination)."))
        }
        return issues
    }
}

public struct RuleTestResult: Hashable, Sendable {
    public enum Outcome: Sendable { case pass, partial, fail, notApplicable }

    public var outcome: Outcome
    public var hostname: String
    public var expected: [IPAddress]
    public var resolved: [IPAddress]
    public var resolutionError: String?
    public var summary: String
    public var hints: [String]
    public var testedAt: Date
}

public enum RuleTester {
    public static let cachingHints = [
        "macOS caches DNS answers. DNS Redirect flushes the cache after each apply. If you changed /etc/hosts by hand, use Flush DNS Cache under System.",
        "Browsers keep their own DNS cache. Restart the browser, or in Chrome open chrome://net-internals/#dns and clear the host cache.",
        "Apps that use DNS-over-HTTPS (Secure DNS in Chrome or Firefox, iCloud Private Relay) or a VPN with its own DNS may bypass local overrides.",
        "Already-open connections keep using the old address until they reconnect.",
    ]

    /// Resolves the rule's source through the system resolver and compares against what the rule intends.
    public static func test(
        rule: RedirectRule,
        evaluation: RuleEvaluation?,
        system: AddressResolving = SystemAddressResolver(),
        destinationResolver: AddressResolving = DestinationResolver(),
        webProbe: (@Sendable (String) async -> (ok: Bool, message: String))? = nil
    ) async -> RuleTestResult {
        let host = rule.source
        guard let evaluation, evaluation.state.willInstall else {
            let reason = evaluation?.state.message ?? (rule.isEnabled ? "The rule is not active." : "The rule is disabled.")
            return RuleTestResult(outcome: .notApplicable, hostname: host, expected: [], resolved: [], resolutionError: nil,
                                  summary: "Not tested: \(reason)", hints: [], testedAt: Date())
        }

        var expected = evaluation.addresses
        if evaluation.mode == .liveResolver, case .domain(let d)? = rule.parsedDestination {
            expected = (try? await destinationResolver.resolve(d)) ?? []
        }

        let resolved: [IPAddress]
        do {
            resolved = try await system.resolve(host)
        } catch {
            return RuleTestResult(outcome: .fail, hostname: host, expected: expected, resolved: [], resolutionError: error.localizedDescription,
                                  summary: "\(host) did not resolve: \(error.localizedDescription)",
                                  hints: evaluation.mode == .liveResolver
                                    ? ["Check that the local resolver is running and that /etc/resolver/\(host) exists (see System)."] + cachingHints
                                    : cachingHints,
                                  testedAt: Date())
        }

        let expectedSet = Set(expected), resolvedSet = Set(resolved)
        let matching = resolvedSet.intersection(expectedSet)
        let outcome: RuleTestResult.Outcome
        var summary: String
        var hints: [String] = []
        if expectedSet.isEmpty {
            outcome = matching.isEmpty && !resolved.isEmpty ? .partial : .fail
            summary = "Resolved to \(list(resolved)), but the expected destination addresses could not be determined."
        } else if !matching.isEmpty && resolvedSet.isSubset(of: expectedSet) {
            outcome = .pass
            summary = "Working. \(host) resolves to \(list(resolved))."
        } else if !matching.isEmpty {
            outcome = .partial
            let extra = resolvedSet.subtracting(expectedSet).sorted()
            summary = "Partly working. The system also returned \(list(extra)), which is not part of this rule."
            if extra.contains(where: { $0.family == .v6 }) && !expectedSet.contains(where: { $0.family == .v6 }) {
                hints.append("The extra addresses are IPv6 records from DNS. Add an IPv6 address to the rule (for example ::1) so IPv6 connections are redirected too.")
            }
        } else {
            outcome = .fail
            summary = "Not working. \(host) resolves to \(list(resolved)); expected \(list(expected))."
            hints = cachingHints
        }
        if evaluation.mode == .webRedirect, outcome != .fail, let webProbe {
            let web = await webProbe(host)
            if web.ok {
                summary = "Working. \(host) points to this Mac and \(web.message)"
            } else {
                summary = "DNS is set, but the web redirect is not answering: \(web.message)"
                hints.append("Check the Web Redirect panel under System.")
                return RuleTestResult(outcome: .partial, hostname: host, expected: expected.sorted(), resolved: resolved.sorted(),
                                      resolutionError: nil, summary: summary, hints: hints, testedAt: Date())
            }
        }
        return RuleTestResult(outcome: outcome, hostname: host, expected: expected.sorted(), resolved: resolved.sorted(),
                              resolutionError: nil, summary: summary, hints: hints, testedAt: Date())
    }

    static func list(_ a: [IPAddress]) -> String {
        a.isEmpty ? "nothing" : a.map(\.description).joined(separator: ", ")
    }
}
