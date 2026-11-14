import AppKit
import DNSRedirectCore
import Observation
import ServiceManagement
import SwiftUI

/// User-facing status of a rule, combining the engine's evaluation with what is actually installed.
enum RuleStatus: Hashable {
    case active(note: String?)
    case pending
    case evaluating
    case disabled
    case inactive(String)
    case error(String)

    var label: String {
        switch self {
        case .active(let note): return note == nil ? "Active" : "Active*"
        case .pending: return "Pending"
        case .evaluating: return "Checking"
        case .disabled: return "Disabled"
        case .inactive: return "Inactive"
        case .error: return "Error"
        }
    }

    var detail: String? {
        switch self {
        case .active(let note): return note
        case .pending: return "Saved, but not yet applied to the system."
        case .inactive(let m), .error(let m): return m
        default: return nil
        }
    }

    var isActive: Bool { if case .active = self { return true } else { return false } }
    var isProblem: Bool {
        switch self {
        case .error: return true
        case .active(let note): return note != nil
        default: return false
        }
    }
}

enum ApplyPhase: Equatable {
    case idle
    case evaluating
    case applying
    case failed(String)
}

enum EditorRequest: Identifiable, Equatable {
    case add(profileID: UUID?)
    case edit(ruleID: UUID)

    var id: String {
        switch self {
        case .add(let p): return "add-\(p?.uuidString ?? "any")"
        case .edit(let r): return "edit-\(r)"
        }
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct LookupResult: Identifiable {
    let id = UUID()
    var hostname: String
    var date = Date()
    var system: Result<[IPAddress], Error>
    var systemDuration: TimeInterval
    var upstream: Result<[IPAddress], Error>
    var upstreamServers: [String]
    var rule: RedirectRule?
    var intended: [IPAddress]
    var verdict: String
    var verdictOK: Bool?
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: State
    private(set) var configuration: AppConfiguration
    private(set) var evaluations: [UUID: RuleEvaluation] = [:]
    private(set) var desired: DesiredState = .empty
    private(set) var system = SystemSnapshot()
    private(set) var phase: ApplyPhase = .idle
    private(set) var lastAppliedAt: Date?
    private(set) var log: [ActivityEntry]
    private(set) var resolverState: LocalDNSServer.State = .stopped
    private(set) var resolverStats = LocalDNSServer.Statistics()
    private(set) var webState = WebRedirectServer.State()
    private(set) var webStats = WebRedirectServer.Statistics()
    private(set) var certificateTrusted = false
    private(set) var certificateBusy = false
    /// Hosts the running web-redirect server has a certificate for.
    private var webServedHosts: [String] = []
    private var webServingHTTPS = false
    private var askedForTrustThisSession = false
    var testResults: [UUID: RuleTestResult] = [:]
    private(set) var testsRunning: Set<UUID> = []
    var lookups: [LookupResult] = []
    var editor: EditorRequest?
    var alert: AlertMessage?
    var launchAtLoginError: String?

    // MARK: Dependencies
    let store: ConfigurationStore
    let paths: SystemPaths
    let executor: PrivilegedExecuting
    let server = LocalDNSServer()
    let web = WebRedirectServer()
    let certificates: WebCertificateManager
    private var saveTask: Task<Void, Never>?
    private var logSaveTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var started = false
    private(set) var isUninstalling = false

    /// `-DNSRedirectDataDirectory <path>` (a launch argument) points the app at an alternate
    /// configuration directory, useful for demos and manual testing.
    nonisolated static var dataDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "DNSRedirectDataDirectory"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return ConfigurationStore.defaultDirectory
    }

    init(store: ConfigurationStore = ConfigurationStore(directory: AppModel.dataDirectory),
         paths: SystemPaths = .system,
         executor: PrivilegedExecuting? = nil) {
        self.store = store
        self.paths = paths
        let helper = Bundle.main.url(forAuxiliaryExecutable: "dnsredirect-helper")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dnsredirect-helper")
        self.executor = executor ?? AppleScriptExecutor(helperURL: helper, stagingDirectory: store.stagingDirectory)
        let (config, warning) = store.load()
        self.configuration = config
        self.certificates = WebCertificateManager(directory: store.directory)
        self.certificateTrusted = certificates.isTrusted()
        self.log = store.loadLog()
        if let warning { record(.warning, .system, warning) }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.resolverState = state }
        }
        web.onStateChange = { [weak self] state in
            Task { @MainActor in self?.webState = state }
        }
    }

    // MARK: Derived

    var settings: AppSettings { configuration.settings }
    var resolverPort: UInt16 { configuration.settings.resolverPort }
    var preferredColorScheme: ColorScheme? { configuration.settings.appearance == .dark ? .dark : nil }

    var needsApply: Bool { !system.matches(desired, resolverPort: resolverPort) }
    var isBusy: Bool { phase == .applying || phase == .evaluating }

    var activeRuleCount: Int {
        configuration.allRules.filter { status(for: $0).isActive }.count
    }

    var enabledRuleCount: Int {
        configuration.profiles.filter(\.isActive).flatMap(\.rules).filter(\.isEnabled).count
    }

    var resolverRunning: Bool {
        if case .running = resolverState { return true }
        return false
    }

    var resolverStatusText: String {
        switch resolverState {
        case .stopped: return settings.resolverEnabled ? "Stopped" : "Off"
        case .starting: return "Starting…"
        case .running(let port): return "Running on 127.0.0.1:\(port)"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    var hostsStatusText: String {
        if let e = system.hostsError { return e }
        if system.hostsLocked { return "Locked" }
        if phase == .applying { return "Applying…" }
        return needsApply ? "Changes pending" : "In sync"
    }

    func status(for rule: RedirectRule) -> RuleStatus {
        guard let e = evaluations[rule.id] else { return .evaluating }
        switch e.state {
        case .disabled: return .disabled
        case .inactive(let m): return .inactive(m)
        case .error(let m): return .error(m)
        case .ready, .warning:
            let note = e.state.message
            if e.mode == .webRedirect {
                let installed = Set(system.managedMappings[rule.source] ?? [])
                guard installed == Set(e.addresses) else { return .pending }
                guard webState.httpRunning || webState.httpsRunning else {
                    return .error("The web redirect server is not running" + (webState.error.map { ": \($0)" } ?? "."))
                }
                if !webState.httpsRunning {
                    return .active(note: "Only http:// is redirected. HTTPS pages (most sites) need the DNS Redirect certificate to be trusted. See System → Web Redirect.")
                }
                return .active(note: note)
            }
            if e.mode == .liveResolver {
                guard system.resolverDomains[rule.source] == resolverPort else { return .pending }
                guard resolverRunning, server.currentAliases()[rule.source] != nil else {
                    return .error("The local resolver is not running, so lookups for this domain will fail.")
                }
                return .active(note: note)
            }
            let installed = Set(system.managedMappings[rule.source] ?? [])
            return installed == Set(e.addresses) && !installed.isEmpty ? .active(note: note) : .pending
        }
    }

    func profile(_ id: UUID?) -> Profile? {
        guard let id else { return nil }
        return configuration.profiles.first { $0.id == id }
    }

    func profileID(containing ruleID: UUID) -> UUID? {
        configuration.profile(containing: ruleID)?.id
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        record(.info, .system, "DNS Redirect started.")
        applyPendingSetup()
        if settings.resolverEnabled { await startResolver() }
        await reconcile(applyChanges: settings.applyAtLaunch)
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let s = self.server.statistics
                if s != self.resolverStats { self.resolverStats = s }
                let w = self.web.statistics
                if w != self.webStats { self.webStats = w }
            }
        }
    }

    /// Called from applicationShouldTerminate. Removes resolver files if configured so
    /// aliased domains don't fail while the app isn't running.
    func prepareForTermination() async {
        flushPendingSaves()
        web.stop()
        // Web-redirect hosts point at this Mac; without the app they would just fail to load.
        let webHosts = Set(desired.webRedirects.keys)
        let keptEntries = system.managedEntries.compactMap { entry -> HostsEntry? in
            let names = entry.hostnames.filter { !webHosts.contains($0) }
            return names.isEmpty ? nil : HostsEntry(address: entry.address, hostnames: names)
        }
        let hostsNeedCleanup = keptEntries != system.managedEntries
        guard settings.removeResolverConfigOnQuit, !system.resolverDomains.isEmpty || hostsNeedCleanup else { return }
        let request = PrivilegedRequest(hostsEntries: keptEntries, resolverDomains: [], resolverPort: resolverPort)
        do {
            _ = try await executor.perform(request)
            record(.info, .resolver, "Removed resolver configuration and web redirects on quit. They are restored the next time DNS Redirect opens.")
        } catch {
            record(.warning, .resolver, "Could not remove resolver configuration on quit: \(error.localizedDescription)")
        }
        flushPendingSaves()
    }

    // MARK: Reconciliation

    /// Re-reads the system, re-evaluates rules and (optionally) applies differences.
    func reconcile(applyChanges: Bool, refreshResolutions: Bool = false) async {
        system = SystemSnapshot.read(paths: paths)
        if phase != .applying { phase = .evaluating }
        let output = await RuleEngine.evaluate(configuration: configuration,
                                               resolver: DestinationResolver(),
                                               unmanagedHosts: system.unmanagedMappings,
                                               refreshResolutions: refreshResolutions)
        evaluations = output.evaluations
        desired = output.desired
        server.setAliases(desired.resolverAliases)
        await syncWebRedirect()
        if configuration.resolvedCache != output.resolvedCache {
            configuration.resolvedCache = output.resolvedCache
            scheduleSave()
        }
        if phase == .evaluating { phase = .idle }
        if applyChanges && needsApply { await applyNow() }
    }

    func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            await self.reconcile(applyChanges: self.settings.autoApply)
        }
    }

    func refreshSystemState() {
        let fresh = SystemSnapshot.read(paths: paths)
        if fresh.managedEntries != system.managedEntries || fresh.resolverDomains != system.resolverDomains
            || fresh.hostsError != system.hostsError || fresh.hostsLocked != system.hostsLocked {
            system = fresh
        }
    }

    func applyNow() async {
        guard phase != .applying else { return }
        system = SystemSnapshot.read(paths: paths)
        if let err = system.hostsError {
            phase = .failed(err)
            record(.error, .system, err)
            return
        }
        phase = .applying
        if !desired.hostsEntries.isEmpty, system.managedEntries.isEmpty {
            do {
                if let backup = try store.backupHostsIfNeeded(from: paths.hostsFile) {
                    record(.info, .system, "Saved a copy of the original /etc/hosts to \(backup.path).")
                }
            } catch {
                record(.warning, .system, "Could not back up /etc/hosts: \(error.localizedDescription)")
            }
        }
        let request = PrivilegedRequest(hostsEntries: desired.hostsEntries,
                                        resolverDomains: desired.resolverDomains,
                                        resolverPort: resolverPort)
        do {
            let result = try await executor.perform(request)
            lastAppliedAt = Date()
            phase = .idle
            var parts: [String] = []
            if result.hostsChanged { parts.append("updated /etc/hosts (\(desired.hostsMappings.count) hostnames)") }
            if !result.resolverFilesWritten.isEmpty { parts.append("installed resolver for \(result.resolverFilesWritten.joined(separator: ", "))") }
            if !result.resolverFilesRemoved.isEmpty { parts.append("removed resolver for \(result.resolverFilesRemoved.joined(separator: ", "))") }
            if result.cacheFlushed { parts.append("flushed DNS cache") }
            record(.success, .system, parts.isEmpty ? "System already up to date." : "Applied: " + parts.joined(separator: "; ") + ".")
            if !result.resolverConflicts.isEmpty {
                record(.warning, .resolver, "Skipped \(result.resolverConflicts.joined(separator: ", ")): /etc/resolver already has a file for it that DNS Redirect did not create.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
            let level: ActivityEntry.Level = (error as? PrivilegedError) == .authorizationDenied ? .warning : .error
            record(level, .system, "Apply failed: \(error.localizedDescription)")
        }
        system = SystemSnapshot.read(paths: paths)
    }

    func refreshResolvedAddresses() async {
        record(.info, .rules, "Refreshing resolved addresses for domain destinations.")
        await reconcile(applyChanges: settings.autoApply, refreshResolutions: true)
    }

    func flushDNSCache() async {
        do {
            try await executor.flushCache()
            record(.success, .system, "Flushed the macOS DNS cache.")
        } catch {
            record((error as? PrivilegedError) == .authorizationDenied ? .warning : .error, .system,
                   "Flushing the DNS cache failed: \(error.localizedDescription)")
            alert = AlertMessage(title: "Could Not Flush DNS Cache", message: error.localizedDescription)
        }
    }

    /// Removes every change the app made to the system and pauses redirects so they aren't re-applied.
    func restoreOriginalConfiguration() async {
        phase = .applying
        do {
            let result = try await executor.perform(.restore(port: resolverPort))
            mutate(log: nil) { $0.redirectsEnabled = false }
            phase = .idle
            record(.success, .system, result.changedAnything
                   ? "Restored the original DNS configuration. Removed the DNS Redirect section and resolver files. Redirects are paused."
                   : "Nothing to restore. No DNS Redirect changes were installed. Redirects are paused.")
        } catch {
            phase = .failed(error.localizedDescription)
            record(.error, .system, "Restore failed: \(error.localizedDescription)")
        }
        system = SystemSnapshot.read(paths: paths)
    }

    // MARK: Mutations

    private func mutate(log message: String?, category: ActivityEntry.Category = .rules, _ change: (inout AppConfiguration) -> Void) {
        change(&configuration)
        if let message { record(.info, category, message) }
        scheduleSave()
        scheduleReconcile()
    }

    func setRedirectsEnabled(_ on: Bool) {
        guard on != configuration.redirectsEnabled else { return }
        mutate(log: on ? "Enabled all redirects." : "Paused all redirects.") { $0.redirectsEnabled = on }
    }

    /// Adds one rule per source domain (multiple domains → one destination).
    @discardableResult
    func addRules(sources: [String], destination: String, mode: AliasMode, note: String, enabled: Bool, profileID: UUID) -> [UUID] {
        let rules = sources.map { RedirectRule(source: $0, destination: destination, isEnabled: enabled, aliasMode: mode, note: note) }
        mutate(log: "Added \(rules.map { "\($0.source) → \($0.destination)" }.joined(separator: ", ")).") { c in
            guard let i = c.profiles.firstIndex(where: { $0.id == profileID }) else { return }
            c.profiles[i].rules.append(contentsOf: rules)
        }
        return rules.map(\.id)
    }

    func updateRule(_ rule: RedirectRule, profileID: UUID) {
        guard let old = configuration.rule(id: rule.id) else { return }
        var updated = rule
        updated.updatedAt = Date()
        mutate(log: "Edited \(old.source) → \(old.destination) to \(updated.source) → \(updated.destination).") { c in
            // Same profile: replace in place. Otherwise move it to the end of the new profile.
            if let p = c.profiles.firstIndex(where: { $0.id == profileID }),
               let r = c.profiles[p].rules.firstIndex(where: { $0.id == rule.id }) {
                c.profiles[p].rules[r] = updated
                return
            }
            for i in c.profiles.indices { c.profiles[i].rules.removeAll { $0.id == rule.id } }
            if let p = c.profiles.firstIndex(where: { $0.id == profileID }) { c.profiles[p].rules.append(updated) }
        }
        testResults[rule.id] = nil
    }

    func setRuleEnabled(_ id: UUID, _ enabled: Bool) {
        guard let rule = configuration.rule(id: id), rule.isEnabled != enabled else { return }
        mutate(log: "\(enabled ? "Enabled" : "Disabled") \(rule.source) → \(rule.destination).") { c in
            for p in c.profiles.indices {
                if let r = c.profiles[p].rules.firstIndex(where: { $0.id == id }) {
                    c.profiles[p].rules[r].isEnabled = enabled
                    c.profiles[p].rules[r].updatedAt = Date()
                }
            }
        }
    }

    func deleteRules(_ ids: Set<UUID>) {
        let names = configuration.allRules.filter { ids.contains($0.id) }.map(\.source)
        guard !names.isEmpty else { return }
        mutate(log: "Deleted \(names.joined(separator: ", ")).") { c in
            for p in c.profiles.indices { c.profiles[p].rules.removeAll { ids.contains($0.id) } }
        }
        for id in ids { testResults[id] = nil }
    }

    func duplicateRule(_ id: UUID) {
        guard let rule = configuration.rule(id: id), let pid = profileID(containing: id) else { return }
        editor = nil
        var copy = rule
        copy.id = UUID()
        copy.isEnabled = false
        copy.createdAt = Date()
        copy.updatedAt = Date()
        mutate(log: "Duplicated \(rule.source) (copy is disabled).") { c in
            if let i = c.profiles.firstIndex(where: { $0.id == pid }) { c.profiles[i].rules.append(copy) }
        }
    }

    // MARK: Profiles

    @discardableResult
    func addProfile(named name: String) -> UUID {
        let profile = Profile(name: uniqueProfileName(name), isActive: false)
        mutate(log: "Created profile “\(profile.name)”.", category: .profiles) { $0.profiles.append(profile) }
        return profile.id
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let old = profile(id), old.name != trimmed else { return }
        mutate(log: "Renamed profile “\(old.name)” to “\(trimmed)”.", category: .profiles) { c in
            if let i = c.profiles.firstIndex(where: { $0.id == id }) { c.profiles[i].name = trimmed }
        }
    }

    func setProfileActive(_ id: UUID, _ active: Bool) {
        guard let p = profile(id), p.isActive != active else { return }
        mutate(log: "\(active ? "Activated" : "Deactivated") profile “\(p.name)”.", category: .profiles) { c in
            if let i = c.profiles.firstIndex(where: { $0.id == id }) { c.profiles[i].isActive = active }
        }
    }

    /// Switches to a profile: activates it and deactivates all others.
    func switchToProfile(_ id: UUID) {
        guard let p = profile(id) else { return }
        mutate(log: "Switched to profile “\(p.name)” (other profiles deactivated).", category: .profiles) { c in
            for i in c.profiles.indices { c.profiles[i].isActive = c.profiles[i].id == id }
        }
    }

    func deleteProfile(_ id: UUID) {
        guard configuration.profiles.count > 1, let p = profile(id) else { return }
        mutate(log: "Deleted profile “\(p.name)” and its \(p.rules.count) rule(s).", category: .profiles) { c in
            c.profiles.removeAll { $0.id == id }
        }
    }

    private func uniqueProfileName(_ base: String) -> String {
        let names = Set(configuration.profiles.map { $0.name.lowercased() })
        var candidate = base.isEmpty ? "Profile" : base
        var n = 2
        while names.contains(candidate.lowercased()) { candidate = "\(base) \(n)"; n += 1 }
        return candidate
    }

    // MARK: Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        let before = configuration.settings
        var after = before
        change(&after)
        guard after != before else { return }
        configuration.settings = after
        scheduleSave()
        if after.resolverEnabled != before.resolverEnabled || (after.resolverEnabled && after.resolverPort != before.resolverPort) {
            Task {
                if after.resolverEnabled {
                    record(.info, .resolver, before.resolverEnabled ? "Resolver port changed to \(after.resolverPort)." : "Enabled the local resolver.")
                    await startResolver()
                } else {
                    server.stop()
                    record(.info, .resolver, "Disabled the local resolver.")
                }
                await reconcile(applyChanges: settings.autoApply)
            }
        } else if after.autoApply && !before.autoApply {
            scheduleReconcile()
        }
    }

    func startResolver() async {
        do {
            let port = try await server.start(port: resolverPort)
            server.setAliases(desired.resolverAliases)
            record(.success, .resolver, "Local resolver listening on 127.0.0.1:\(port).")
        } catch {
            record(.error, .resolver, "Local resolver failed to start: \(server.state == .stopped ? error.localizedDescription : resolverStatusText)")
        }
    }

    // MARK: Installer integration

    /// Choices made in the installer that only the app itself can apply (login item).
    struct PendingSetup: Codable {
        var launchAtLogin: Bool?
    }

    private func applyPendingSetup() {
        let url = store.directory.appendingPathComponent("pending-setup.json")
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let setup = try? JSONDecoder().decode(PendingSetup.self, from: data) else { return }
        if let login = setup.launchAtLogin, login != launchAtLogin {
            setLaunchAtLogin(login)
        }
        record(.info, .system, "Applied first-run settings from the installer.")
    }

    /// Removes everything DNS Redirect added to the system, then moves the app to the Trash and quits.
    func uninstall(removeUserData: Bool) async {
        phase = .applying
        system = SystemSnapshot.read(paths: paths)
        if system.hasManagedChanges {
            do {
                _ = try await executor.perform(.restore(port: resolverPort))
            } catch {
                phase = .failed(error.localizedDescription)
                alert = AlertMessage(title: "Uninstall Stopped",
                                     message: "DNS Redirect could not remove its DNS changes, so nothing was uninstalled.\n\n\(error.localizedDescription)")
                return
            }
        }
        isUninstalling = true
        web.stop()
        server.stop()
        if certificates.existingCA() != nil || certificateTrusted { try? certificates.removeAll() }
        if SMAppService.mainApp.status == .enabled { try? await SMAppService.mainApp.unregister() }
        saveTask?.cancel()
        logSaveTask?.cancel()
        reconcileTask?.cancel()
        if removeUserData {
            try? FileManager.default.removeItem(at: store.directory)
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.dnsredirect.app")
        } else {
            configuration.redirectsEnabled = false
            saveNow()
        }
        let bundle = Bundle.main.bundleURL
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
        } catch {
            alert = AlertMessage(title: "Almost Done",
                                 message: "DNS changes were removed, but the app could not be moved to the Trash (\(error.localizedDescription)). Drag \(bundle.lastPathComponent) to the Trash to finish.")
            NSWorkspace.shared.activateFileViewerSelecting([bundle])
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Web redirect

    var webRunning: Bool { webState.httpRunning || webState.httpsRunning }

    var webStatusText: String {
        if desired.webRedirects.isEmpty && !webRunning { return "Off · no web redirect rules" }
        if let e = webState.error, !webRunning { return "Failed: \(e)" }
        switch (webState.httpRunning, webState.httpsRunning) {
        case (true, true): return "Running · HTTP + HTTPS"
        case (true, false): return "Running · HTTP only"
        case (false, true): return "Running · HTTPS only"
        default: return "Stopped"
        }
    }

    /// Starts, restarts or stops the web-redirect server to match the desired rules.
    func syncWebRedirect() async {
        let map = desired.webRedirects
        web.setRedirects(map)
        guard !map.isEmpty else {
            if web.isRunning { web.stop(); record(.info, .system, "Stopped the web redirect server (no web redirect rules).") }
            webServedHosts = []
            return
        }
        if !certificateTrusted && !askedForTrustThisSession {
            askedForTrustThisSession = true
            trustCertificate(automatic: true)
        }
        let hosts = map.keys.sorted()
        let wantHTTPS = certificateTrusted
        if web.isRunning, hosts == webServedHosts, wantHTTPS == webServingHTTPS, webState.error == nil { return }
        var identity: SecIdentity?
        if wantHTTPS {
            do { identity = try certificates.serverIdentity(for: hosts) } catch {
                record(.error, .system, "Could not create the HTTPS certificate for web redirects: \(error.localizedDescription)")
            }
        }
        _ = await web.start(identity: identity)
        webState = web.state
        webServedHosts = hosts
        webServingHTTPS = identity != nil
        if let e = webState.error {
            record(.error, .system, "Web redirect server problem: \(e)")
        } else {
            record(.success, .system, "Web redirect server answering for \(hosts.joined(separator: ", ")) on \(identity != nil ? "http and https" : "http only").")
        }
    }

    /// Creates the local CA if needed and asks macOS to trust it for HTTPS (password prompt).
    func trustCertificate(automatic: Bool = false) {
        guard !certificateBusy else { return }
        certificateBusy = true
        defer { certificateBusy = false }
        do {
            try certificates.trustCA()
            certificateTrusted = certificates.isTrusted()
            record(.success, .system, "Trusted the “\(WebCertificateManager.caCommonName)” certificate for HTTPS web redirects (this Mac and user only).")
            if !automatic { webServedHosts = []; Task { await syncWebRedirect() } }
        } catch {
            certificateTrusted = certificates.isTrusted()
            record(.warning, .system, "HTTPS web redirects are off: \(error.localizedDescription)")
            if !automatic { alert = AlertMessage(title: "Certificate Not Trusted", message: error.localizedDescription) }
        }
    }

    /// Removes the local CA, its trust setting and keys. HTTPS web redirects stop working.
    func removeCertificate() {
        do {
            try certificates.removeAll()
            certificateTrusted = false
            askedForTrustThisSession = true
            record(.info, .system, "Removed the “\(WebCertificateManager.caCommonName)” certificate and its keys.")
            webServedHosts = []
            Task { await syncWebRedirect() }
        } catch {
            alert = AlertMessage(title: "Could Not Remove Certificate", message: error.localizedDescription)
        }
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
            record(.info, .system, on ? "Enabled launch at login." : "Disabled launch at login.")
        } catch {
            launchAtLoginError = error.localizedDescription
            record(.error, .system, "Could not change launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: Testing & lookup

    func testRule(_ id: UUID) async {
        guard let rule = configuration.rule(id: id), !testsRunning.contains(id) else { return }
        testsRunning.insert(id)
        let https = webState.httpsRunning
        let result = await RuleTester.test(rule: rule, evaluation: evaluations[id], webProbe: { host in
            do {
                let r = try await WebRedirectProbe.probe(host: host, port: https ? 443 : 80, tls: https)
                guard r.status == 302, let location = r.location else {
                    return (false, "the server answered HTTP \(r.status) without a redirect.")
                }
                return (true, "\(https ? "https" : "http")://\(host) redirects to \(location).")
            } catch {
                return (false, https ? "HTTPS check failed (\(error.localizedDescription)). Is the certificate trusted?" : error.localizedDescription)
            }
        })
        testsRunning.remove(id)
        testResults[id] = result
        let level: ActivityEntry.Level
        switch result.outcome {
        case .pass: level = .success
        case .partial: level = .warning
        case .fail: level = .error
        case .notApplicable: level = .info
        }
        record(level, .test, "Test \(rule.source): \(result.summary)")
    }

    func testAll(_ ids: [UUID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.testRule(id) } }
        }
    }

    func isTesting(_ id: UUID) -> Bool { testsRunning.contains(id) }

    func lookup(_ raw: String) async {
        let host = DomainName.normalize(raw)
        guard !host.isEmpty else { return }
        let started = Date()
        let systemResult: Result<[IPAddress], Error>
        do { systemResult = .success(try await SystemAddressResolver().resolve(host)) } catch { systemResult = .failure(error) }
        let elapsed = Date().timeIntervalSince(started)
        let client = DNSClient()
        let upstreamResult: Result<[IPAddress], Error>
        do { upstreamResult = .success(try await client.addresses(for: host)) } catch { upstreamResult = .failure(error) }

        let rule = configuration.profiles.filter(\.isActive).flatMap(\.rules).first { $0.source == host && $0.isEnabled }
            ?? configuration.allRules.first { $0.source == host }
        var intended: [IPAddress] = []
        var verdict: String
        var ok: Bool?
        if let rule, let e = evaluations[rule.id], e.state.willInstall {
            if e.mode == .liveResolver, case .domain(let d)? = rule.parsedDestination {
                intended = (try? await DNSClient().addresses(for: d)) ?? []
            } else {
                intended = e.addresses
            }
            let got = Set((try? systemResult.get()) ?? [])
            if got.isEmpty {
                verdict = "Override not working: the system could not resolve \(host)."
                ok = false
            } else if !got.isDisjoint(with: intended) && got.isSubset(of: Set(intended)) {
                verdict = "Override working. The system returns the addresses DNS Redirect intends."
                ok = true
            } else if !got.isDisjoint(with: intended) {
                verdict = "Partly working. The system also returns addresses that are not in the rule."
                ok = nil
            } else {
                verdict = "Override not in effect. The system returns different addresses (stale cache, pending apply, or another resolver)."
                ok = false
            }
        } else if let rule {
            verdict = "A rule exists for \(host), but it is not active (\(status(for: rule).label.lowercased()))."
        } else {
            verdict = "No DNS Redirect rule for \(host). Showing normal resolution."
        }
        let result = LookupResult(hostname: host, system: systemResult, systemDuration: elapsed, upstream: upstreamResult,
                                  upstreamServers: client.servers, rule: rule, intended: intended, verdict: verdict, verdictOK: ok)
        lookups.insert(result, at: 0)
        if lookups.count > 20 { lookups.removeLast() }
        if case .failure(let e) = systemResult {
            record(.warning, .lookup, "Lookup \(host) failed: \(e.localizedDescription)")
        } else {
            record(.info, .lookup, "Looked up \(host): \(verdict)")
        }
    }

    // MARK: Import / Export

    func exportData(profileIDs: [UUID]? = nil) throws -> Data {
        let profiles = profileIDs.map { ids in configuration.profiles.filter { ids.contains($0.id) } } ?? configuration.profiles
        return try RulesDocument(profiles: profiles).encoded()
    }

    func importRules(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let document = try RulesDocument.decode(try Data(contentsOf: url))
            var summary = ImportSummary()
            mutate(log: nil) { summary = $0.merge(document) }
            var message = "Imported \(summary.added) rule(s) from \(url.lastPathComponent)"
            if summary.profilesCreated > 0 { message += ", created \(summary.profilesCreated) profile(s)" }
            if summary.duplicatesSkipped > 0 { message += ", skipped \(summary.duplicatesSkipped) duplicate(s)" }
            message += "."
            record(summary.invalid.isEmpty ? .success : .warning, .importExport, message)
            if !summary.invalid.isEmpty {
                record(.warning, .importExport, "Skipped invalid rules: " + summary.invalid.joined(separator: "; "))
                alert = AlertMessage(title: "Import Finished with Problems",
                                     message: message + "\n\nSkipped \(summary.invalid.count) invalid rule(s):\n" + summary.invalid.prefix(8).joined(separator: "\n"))
            }
        } catch {
            record(.error, .importExport, "Import failed: \(error.localizedDescription)")
            alert = AlertMessage(title: "Import Failed", message: error.localizedDescription)
        }
    }

    func recordExport(to url: URL, count: Int) {
        record(.success, .importExport, "Exported \(count) rule(s) to \(url.lastPathComponent).")
    }

    // MARK: Log & persistence

    func record(_ level: ActivityEntry.Level, _ category: ActivityEntry.Category, _ message: String) {
        log.insert(ActivityEntry(level: level, category: category, message: message), at: 0)
        if log.count > 1000 { log.removeLast(log.count - 1000) }
        logSaveTask?.cancel()
        logSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            try? self.store.saveLog(self.log)
        }
    }

    func clearLog() {
        log.removeAll()
        try? store.saveLog([])
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        do { try store.save(configuration) } catch {
            record(.error, .system, "Could not save configuration: \(error.localizedDescription)")
        }
    }

    func flushPendingSaves() {
        saveTask?.cancel()
        saveNow()
        logSaveTask?.cancel()
        try? store.saveLog(log)
    }
}
