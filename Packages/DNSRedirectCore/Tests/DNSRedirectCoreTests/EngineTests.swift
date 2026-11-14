import XCTest
@testable import DNSRedirectCore

struct MockResolver: AddressResolving {
    var table: [String: [String]]
    struct NotFound: Error {}

    func resolve(_ host: String) async throws -> [IPAddress] {
        guard let a = table[host] else { throw NotFound() }
        return a.compactMap(IPAddress.init)
    }
}

final class RuleEngineTests: XCTestCase {
    let resolver = MockResolver(table: ["new.example.com": ["93.184.216.34", "2606:2800::1"]])

    func config(_ rules: [RedirectRule], resolverEnabled: Bool = false) -> AppConfiguration {
        var c = AppConfiguration(profiles: [Profile(name: "Default", rules: rules)])
        c.settings.resolverEnabled = resolverEnabled
        return c
    }

    func testIPAndDomainRules() async {
        let r1 = RedirectRule(source: "example.com", destination: "192.168.1.100")
        let r2 = RedirectRule(source: "test.local", destination: "127.0.0.1")
        let r3 = RedirectRule(source: "old.example.com", destination: "new.example.com")
        let r4 = RedirectRule(source: "api.example.com", destination: "192.168.1.100")
        let out = await RuleEngine.evaluate(configuration: config([r1, r2, r3, r4]), resolver: resolver)

        let map = out.desired.hostsMappings
        XCTAssertEqual(map["example.com"], [IPAddress("192.168.1.100")!])
        XCTAssertEqual(map["old.example.com"].map(Set.init), [IPAddress("93.184.216.34")!, IPAddress("2606:2800::1")!])
        // Multiple domains → one IP are grouped onto one hosts line.
        XCTAssertEqual(out.desired.hostsEntries.first?.hostnames, ["example.com", "api.example.com"])
        XCTAssertTrue(out.evaluations[r3.id]!.state.willInstall)
        XCTAssertNotNil(out.resolvedCache["new.example.com"])
    }

    func testDisabledInactiveAndPaused() async {
        let off = RedirectRule(source: "a.test", destination: "1.1.1.1", isEnabled: false)
        let inactiveRule = RedirectRule(source: "b.test", destination: "1.1.1.1")
        var c = config([off])
        c.profiles.append(Profile(name: "Work", isActive: false, rules: [inactiveRule]))
        var out = await RuleEngine.evaluate(configuration: c, resolver: resolver)
        XCTAssertEqual(out.evaluations[off.id]?.state, .disabled)
        if case .inactive = out.evaluations[inactiveRule.id]?.state {} else { XCTFail() }
        XCTAssertTrue(out.desired.hostsEntries.isEmpty)

        c.profiles[1].isActive = true
        c.redirectsEnabled = false
        out = await RuleEngine.evaluate(configuration: c, resolver: resolver)
        XCTAssertEqual(out.desired, .empty, "master switch removes everything")
    }

    func testConflictsAndDuplicatesAcrossProfiles() async {
        let a = RedirectRule(source: "x.test", destination: "1.1.1.1")
        let dup = RedirectRule(source: "x.test", destination: "1.1.1.1")
        let conflict = RedirectRule(source: "x.test", destination: "2.2.2.2")
        var c = config([a])
        c.profiles.append(Profile(name: "P2", rules: [dup, conflict]))
        let out = await RuleEngine.evaluate(configuration: c, resolver: resolver)
        XCTAssertEqual(out.desired.hostsMappings["x.test"], [IPAddress("1.1.1.1")!])
        if case .inactive = out.evaluations[dup.id]?.state {} else { XCTFail("duplicate should be inactive") }
        if case .error(let m) = out.evaluations[conflict.id]?.state { XCTAssertTrue(m.contains("Conflicts")) } else { XCTFail() }
    }

    func testChainsAndLoops() async {
        let base = RedirectRule(source: "db.test", destination: "10.0.0.5")
        let alias = RedirectRule(source: "app.test", destination: "db.test")
        let loopA = RedirectRule(source: "a.loop", destination: "b.loop")
        let loopB = RedirectRule(source: "b.loop", destination: "a.loop")
        let out = await RuleEngine.evaluate(configuration: config([base, alias, loopA, loopB]), resolver: resolver)
        XCTAssertEqual(out.desired.hostsMappings["app.test"], [IPAddress("10.0.0.5")!], "chains resolve through other rules, not DNS")
        if case .error(let m) = out.evaluations[loopA.id]?.state { XCTAssertTrue(m.contains("loop")) } else { XCTFail() }
        if case .error = out.evaluations[loopB.id]?.state {} else { XCTFail() }
    }

    func testResolutionFailureFallsBackToCache() async {
        let r = RedirectRule(source: "old.test", destination: "gone.example")
        var c = config([r])
        var out = await RuleEngine.evaluate(configuration: c, resolver: resolver)
        if case .error = out.evaluations[r.id]?.state {} else { XCTFail("unresolvable without cache") }

        c.resolvedCache["gone.example"] = ResolvedSnapshot(addresses: [IPAddress("5.5.5.5")!], resolvedAt: Date(timeIntervalSince1970: 0))
        out = await RuleEngine.evaluate(configuration: c, resolver: resolver)
        if case .warning(let m) = out.evaluations[r.id]?.state { XCTAssertTrue(m.contains("cached")) } else { XCTFail() }
        XCTAssertEqual(out.desired.hostsMappings["old.test"], [IPAddress("5.5.5.5")!])
    }

    func testSnapshotsAreStickyUnlessRefreshed() async {
        let r = RedirectRule(source: "old.example.com", destination: "new.example.com")
        var c = config([r])
        c.resolvedCache["new.example.com"] = ResolvedSnapshot(addresses: [IPAddress("1.2.3.4")!])
        var out = await RuleEngine.evaluate(configuration: c, resolver: resolver, refreshResolutions: false)
        XCTAssertEqual(out.desired.hostsMappings["old.example.com"], [IPAddress("1.2.3.4")!])
        out = await RuleEngine.evaluate(configuration: c, resolver: resolver, refreshResolutions: true)
        XCTAssertEqual(out.desired.hostsMappings["old.example.com"]?.count, 2)
    }

    func testLiveResolverRules() async {
        let r = RedirectRule(source: "old.example.com", destination: "new.example.com", aliasMode: .liveResolver)
        var out = await RuleEngine.evaluate(configuration: config([r], resolverEnabled: false), resolver: resolver)
        if case .error(let m) = out.evaluations[r.id]?.state { XCTAssertTrue(m.contains("resolver")) } else { XCTFail() }

        out = await RuleEngine.evaluate(configuration: config([r], resolverEnabled: true), resolver: resolver)
        XCTAssertEqual(out.desired.resolverAliases, ["old.example.com": "new.example.com"])
        XCTAssertTrue(out.desired.hostsEntries.isEmpty)
    }

    func testWarnsAboutUnmanagedHostsEntries() async {
        let r = RedirectRule(source: "intranet.corp", destination: "10.9.9.9, ::1")
        let out = await RuleEngine.evaluate(configuration: config([r]), resolver: resolver,
                                            unmanagedHosts: ["intranet.corp": [IPAddress("10.1.1.1")!]])
        if case .warning(let m) = out.evaluations[r.id]?.state { XCTAssertTrue(m.contains("outside")) } else { XCTFail() }
    }

    func testSnapshotMatching() async {
        let r = RedirectRule(source: "a.test", destination: "1.1.1.1, ::1")
        let out = await RuleEngine.evaluate(configuration: config([r]), resolver: resolver)
        var snap = SystemSnapshot()
        XCTAssertFalse(snap.matches(out.desired, resolverPort: 53535))
        snap.managedEntries = [HostsEntry(address: IPAddress("::1")!, hostnames: ["a.test"]),
                               HostsEntry(address: IPAddress("1.1.1.1")!, hostnames: ["a.test"])]
        XCTAssertTrue(snap.matches(out.desired, resolverPort: 53535), "order-insensitive")
    }

    func testConflictChecker() {
        let existing = RedirectRule(source: "a.test", destination: "1.1.1.1")
        let other = RedirectRule(source: "b.test", destination: "a.test")
        var c = AppConfiguration(profiles: [Profile(name: "One", rules: [existing, other]), Profile(name: "Two")])
        let p1 = c.profiles[0].id, p2 = c.profiles[1].id
        XCTAssertEqual(RuleConflictChecker.issues(for: RedirectRule(source: "a.test", destination: "1.1.1.1"), in: p1, configuration: c).first?.severity, .error)
        XCTAssertEqual(RuleConflictChecker.issues(for: RedirectRule(source: "a.test", destination: "2.2.2.2"), in: p2, configuration: c).first?.severity, .warning)
        XCTAssertTrue(RuleConflictChecker.issues(for: existing, in: p1, configuration: c).isEmpty, "editing a rule ignores itself")
        XCTAssertTrue(RuleConflictChecker.issues(for: RedirectRule(source: "a.test", destination: "b.test"), in: p2, configuration: c)
            .contains { $0.message.contains("loop") })
        c.profiles[0].isActive = false
        XCTAssertTrue(RuleConflictChecker.issues(for: RedirectRule(source: "a.test", destination: "2.2.2.2"), in: p2, configuration: c).isEmpty)
    }
}

final class RuleTesterTests: XCTestCase {
    func testOutcomes() async {
        let rule = RedirectRule(source: "example.com", destination: "192.168.1.100")
        let eval = RuleEvaluation(ruleID: rule.id, state: .ready, addresses: [IPAddress("192.168.1.100")!])

        var result = await RuleTester.test(rule: rule, evaluation: eval, system: MockResolver(table: ["example.com": ["192.168.1.100"]]))
        XCTAssertEqual(result.outcome, .pass)

        result = await RuleTester.test(rule: rule, evaluation: eval, system: MockResolver(table: ["example.com": ["192.168.1.100", "2606:2800::1"]]))
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertTrue(result.hints.contains { $0.contains("IPv6") })

        result = await RuleTester.test(rule: rule, evaluation: eval, system: MockResolver(table: ["example.com": ["93.184.216.34"]]))
        XCTAssertEqual(result.outcome, .fail)
        XCTAssertFalse(result.hints.isEmpty, "caching hints are shown on failure")

        result = await RuleTester.test(rule: rule, evaluation: RuleEvaluation(ruleID: rule.id, state: .disabled), system: MockResolver(table: [:]))
        XCTAssertEqual(result.outcome, .notApplicable)
    }

    func testLiveAliasComparesWithDestination() async {
        let rule = RedirectRule(source: "old.test", destination: "new.test", aliasMode: .liveResolver)
        let eval = RuleEvaluation(ruleID: rule.id, state: .ready, mode: .liveResolver)
        let result = await RuleTester.test(rule: rule, evaluation: eval,
                                           system: MockResolver(table: ["old.test": ["7.7.7.7"]]),
                                           destinationResolver: MockResolver(table: ["new.test": ["7.7.7.7"]]))
        XCTAssertEqual(result.outcome, .pass)
    }
}
