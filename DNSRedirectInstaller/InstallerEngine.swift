import AppKit
import DNSRedirectCore
import Foundation
import Security

// MARK: - Environment detection

enum CPUArchitecture: String, Codable {
    case arm64, x86_64, unknown

    var title: String {
        switch self {
        case .arm64: return "Apple Silicon (arm64)"
        case .x86_64: return "Intel (x86_64)"
        case .unknown: return "Unknown"
        }
    }

    /// Mach-O CPU type for this architecture.
    var cpuType: Int32? {
        switch self {
        case .arm64: return 0x0100_000C
        case .x86_64: return 0x0100_0007
        case .unknown: return nil
        }
    }

    static func from(cpuType: Int32) -> CPUArchitecture {
        switch cpuType {
        case 0x0100_000C: return .arm64
        case 0x0100_0007: return .x86_64
        default: return .unknown
        }
    }
}

enum HostInfo {
    /// The machine's real architecture, even when the installer itself runs under Rosetta.
    static var hardwareArchitecture: CPUArchitecture {
        if sysctlInt("hw.optional.arm64") == 1 { return .arm64 }
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        if machine == "arm64" { return .arm64 }
        if machine == "x86_64" { return .x86_64 }
        return .unknown
    }

    static var isTranslated: Bool { sysctlInt("sysctl.proc_translated") == 1 }

    static var modelName: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static var osVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    static var osVersionString: String {
        let v = osVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// True when the current user is in the local "admin" group (gid 80).
    static var userIsAdmin: Bool {
        guard let name = getpwuid(getuid())?.pointee.pw_name else { return false }
        let base = Int32(bitPattern: getgid())
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        if getgrouplist(name, base, &groups, &count) == -1 {
            groups = [Int32](repeating: 0, count: Int(count))
            _ = getgrouplist(name, base, &groups, &count)
        }
        return groups.prefix(Int(count)).contains(80)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

enum MachO {
    /// Architectures contained in a Mach-O (thin or universal) executable.
    static func architectures(of url: URL) -> [CPUArchitecture] {
        guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 4096) else { return [] }
        try? handle.close()
        let bytes = [UInt8](header)
        guard bytes.count >= 8 else { return [] }
        func be32(_ o: Int) -> UInt32 { UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3]) }
        func le32(_ o: Int) -> UInt32 { UInt32(bytes[o + 3]) << 24 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o]) }
        let magic = be32(0)
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            let count = Int(be32(4))
            let stride = magic == 0xCAFE_BABE ? 20 : 32
            return (0..<count).compactMap { i -> CPUArchitecture? in
                let offset = 8 + i * stride
                guard offset + 4 <= bytes.count else { return nil }
                return CPUArchitecture.from(cpuType: Int32(bitPattern: be32(offset)))
            }
        }
        if le32(0) == 0xFEED_FACF { return [CPUArchitecture.from(cpuType: Int32(bitPattern: le32(4)))] }
        return []
    }

    /// Minimum macOS version (LC_BUILD_VERSION) of the first slice matching `arch`.
    static func minimumOS(of url: URL, arch: CPUArchitecture) -> OperatingSystemVersion? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let bytes = [UInt8](data.prefix(4 * 1024 * 1024))
        func be32(_ o: Int) -> UInt32 { UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3]) }
        func le32(_ o: Int) -> UInt32 { UInt32(bytes[o + 3]) << 24 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o]) }
        var sliceOffset = 0
        if be32(0) == 0xCAFE_BABE {
            for i in 0..<Int(be32(4)) {
                let o = 8 + i * 20
                if Int32(bitPattern: be32(o)) == arch.cpuType { sliceOffset = Int(be32(o + 8)) }
            }
        }
        guard sliceOffset + 32 <= bytes.count, le32(sliceOffset) == 0xFEED_FACF else { return nil }
        let ncmds = Int(le32(sliceOffset + 16))
        var cursor = sliceOffset + 32
        for _ in 0..<ncmds {
            guard cursor + 16 <= bytes.count else { return nil }
            let cmd = le32(cursor), size = Int(le32(cursor + 4))
            if cmd == 0x32 { // LC_BUILD_VERSION
                let minos = le32(cursor + 12)
                return OperatingSystemVersion(majorVersion: Int(minos >> 16), minorVersion: Int((minos >> 8) & 0xFF), patchVersion: Int(minos & 0xFF))
            }
            guard size > 0 else { return nil }
            cursor += size
        }
        return nil
    }
}

// MARK: - Payload

struct Payload {
    static let appName = "DNS Redirect.app"
    static let bundleIdentifier = "com.dnsredirect.app"

    let url: URL

    static func embedded() -> Payload? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(appName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Payload(url: url)
    }

    var bundle: Bundle? { Bundle(url: url) }
    var version: String { Payload.version(of: url) ?? "?" }
    var executableURL: URL { url.appendingPathComponent("Contents/MacOS/DNS Redirect") }
    var helperURL: URL { url.appendingPathComponent("Contents/MacOS/dnsredirect-helper") }
    var architectures: [CPUArchitecture] { MachO.architectures(of: executableURL) }

    static func version(of app: URL) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var sizeInBytes: Int64 { Payload.allocatedSize(of: url) }

    static func allocatedSize(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

enum CodeSignature {
    /// Validates the bundle's signature (all architectures, nested code, strict) and reports the signer.
    static func verify(_ url: URL) -> (ok: Bool, detail: String) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return (false, "Not code-signed")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status == errSecSuccess else {
            let message = error?.takeRetainedValue().localizedDescription ?? (SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
            return (false, "Invalid signature: \(message)")
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
           let name = SecCertificateCopySubjectSummary(leaf) as String? {
            return (true, name)
        }
        return (true, "Ad-hoc signature (valid)")
    }
}

// MARK: - System check

struct CheckItem: Identifiable, Equatable {
    enum Level: Equatable { case pass, warning, fail, info }
    let id: String
    var title: String
    var detail: String
    var level: Level
    var symbol: String
}

struct SystemCheck {
    static let minimumOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    var items: [CheckItem] = []
    var architecture: CPUArchitecture = .unknown
    var existingInstall: URL?
    var existingVersion: String?
    var installDirectory: URL = URL(fileURLWithPath: "/Applications")
    var hasManagedDNSChanges = false

    var canInstall: Bool { payloadOK && !items.contains { $0.level == .fail } }
    private var payloadOK = false

    static func run(payload: Payload?, preferredDirectory: URL? = nil, systemPaths: SystemPaths = .system) -> SystemCheck {
        var check = SystemCheck()
        let fm = FileManager.default

        // macOS version
        let osOK = ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumOS)
        check.items.append(CheckItem(id: "os", title: "macOS \(HostInfo.osVersionString)",
                                     detail: osOK ? "Supported (macOS 14 Sonoma or later required)." : "DNS Redirect needs macOS 14 Sonoma or later.",
                                     level: osOK ? .pass : .fail, symbol: "apple.logo"))

        // Architecture
        let arch = HostInfo.hardwareArchitecture
        check.architecture = arch
        let slices = payload?.architectures ?? []
        let archOK = slices.contains(arch)
        var archDetail = "\(HostInfo.modelName). App includes \(slices.map(\.rawValue).joined(separator: " + "))"
        archDetail += archOK ? ", runs natively." : ". No native build for this Mac."
        if HostInfo.isTranslated { archDetail += " (Installer is running under Rosetta.)" }
        check.items.append(CheckItem(id: "arch", title: arch.title, detail: archDetail,
                                     level: archOK ? .pass : .fail, symbol: "cpu"))

        // Payload integrity
        if let payload {
            let sig = CodeSignature.verify(payload.url)
            var minOSDetail = ""
            if let min = MachO.minimumOS(of: payload.executableURL, arch: arch == .unknown ? .arm64 : arch) {
                minOSDetail = " Built for macOS \(min.majorVersion).\(min.minorVersion)+."
            }
            check.payloadOK = sig.ok
            check.items.append(CheckItem(id: "payload", title: "DNS Redirect \(payload.version)",
                                         detail: (sig.ok ? "Package intact · signed by \(sig.detail)." : sig.detail) + minOSDetail,
                                         level: sig.ok ? .pass : .fail, symbol: "shippingbox"))
        } else {
            check.items.append(CheckItem(id: "payload", title: "Application package missing",
                                         detail: "This installer is incomplete. Download it again.", level: .fail, symbol: "shippingbox"))
        }

        // Install location
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        var dir = preferredDirectory ?? system
        if preferredDirectory == nil && !fm.isWritableFile(atPath: system.path) { dir = user }
        check.installDirectory = dir
        let writable = fm.isWritableFile(atPath: dir.path) || (!fm.fileExists(atPath: dir.path) && fm.isWritableFile(atPath: dir.deletingLastPathComponent().path))
        check.items.append(CheckItem(id: "location", title: "Install to \(dir.path)",
                                     detail: writable
                                        ? (dir == user ? "/Applications isn't writable for this account, so the app goes into your personal Applications folder." : "Writable without an administrator password.")
                                        : "This folder isn't writable. Ask an administrator to install DNS Redirect.",
                                     level: writable ? (dir == user ? .warning : .pass) : .fail, symbol: "folder"))

        // Disk space
        let need = (payload?.sizeInBytes ?? 0) * 2
        let free = (try? dir.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            ?? (try? system.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let spaceOK = free == 0 || free > need
        let fmt = ByteCountFormatter()
        check.items.append(CheckItem(id: "disk", title: "Disk space",
                                     detail: "Needs \(fmt.string(fromByteCount: max(need / 2, 1))) · \(free > 0 ? fmt.string(fromByteCount: free) : "unknown") available.",
                                     level: spaceOK ? .pass : .fail, symbol: "internaldrive"))

        // Existing installation
        let existing = SystemCheck.findExistingInstall(candidates: [dir.appendingPathComponent(Payload.appName),
                                                                    system.appendingPathComponent(Payload.appName),
                                                                    user.appendingPathComponent(Payload.appName)])
        check.existingInstall = existing
        check.existingVersion = existing.flatMap { Payload.version(of: $0) }
        if let existing {
            check.items.append(CheckItem(id: "existing", title: "Existing installation found",
                                         detail: "Version \(check.existingVersion ?? "?") at \(existing.path) will be replaced. Your rules and settings are kept.",
                                         level: .info, symbol: "arrow.triangle.2.circlepath"))
        }

        // Administrator rights (needed later by the app, not by the installer)
        let admin = HostInfo.userIsAdmin
        check.items.append(CheckItem(id: "admin", title: admin ? "Administrator account" : "Standard account",
                                     detail: admin
                                        ? "No password needed to install. DNS Redirect asks for it only when it changes /etc/hosts or DNS settings."
                                        : "Installing works, but changing DNS settings later needs an administrator's name and password.",
                                     level: admin ? .pass : .warning, symbol: "person.badge.key"))

        // Leftover DNS changes
        let snapshot = SystemSnapshot.read(paths: systemPaths)
        check.hasManagedDNSChanges = snapshot.hasManagedChanges
        if snapshot.hasManagedChanges {
            check.items.append(CheckItem(id: "dns", title: "DNS Redirect rules are active",
                                         detail: "\(snapshot.managedMappings.count) hosts entr\(snapshot.managedMappings.count == 1 ? "y" : "ies") and \(snapshot.resolverDomains.count) resolver file(s) from a previous install. They are kept.",
                                         level: .info, symbol: "network"))
        }
        return check
    }

    static func findExistingInstall(candidates: [URL]) -> URL? {
        for c in candidates where FileManager.default.fileExists(atPath: c.appendingPathComponent("Contents/Info.plist").path) {
            if Bundle(url: c)?.bundleIdentifier == Payload.bundleIdentifier { return c }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Payload.bundleIdentifier),
           !url.path.contains("/Volumes/"), !url.path.contains("/DerivedData/"), !url.path.hasPrefix(Bundle.main.bundlePath) {
            return url
        }
        return nil
    }
}

// MARK: - Options

struct InstallOptions: Equatable {
    var launchAtLogin = false
    var showMenuBarExtra = true
    var autoApply = true
    var applyAtLaunch = true
}

// MARK: - Steps

struct StepState: Identifiable, Equatable {
    enum Status: Equatable { case pending, running, done, skipped, failed }
    let id: String
    var title: String
    var detail: String = ""
    var status: Status = .pending
}

struct InstallerFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Performs installs and uninstalls. Paths are injectable for headless tests.
@MainActor
final class InstallerEngine {
    var installDirectory: URL
    var dataDirectory: URL
    var systemPaths: SystemPaths
    /// Used to remove app-managed DNS changes. Defaults to the bundled helper via the macOS admin prompt.
    var executor: PrivilegedExecuting?
    var progress: (String, StepState.Status, String) -> Void = { _, _, _ in }

    let payload: Payload?

    init(payload: Payload? = .embedded(), installDirectory: URL, dataDirectory: URL = ConfigurationStore.defaultDirectory,
         systemPaths: SystemPaths = .system, executor: PrivilegedExecuting? = nil) {
        self.payload = payload
        self.installDirectory = installDirectory
        self.dataDirectory = dataDirectory
        self.systemPaths = systemPaths
        self.executor = executor
    }

    var destination: URL { installDirectory.appendingPathComponent(Payload.appName) }

    static let installSteps: [StepState] = [
        StepState(id: "verify", title: "Verifying package"),
        StepState(id: "quit", title: "Closing running copies"),
        StepState(id: "copy", title: "Installing DNS Redirect.app"),
        StepState(id: "check", title: "Validating installed app"),
        StepState(id: "register", title: "Registering with macOS"),
        StepState(id: "configure", title: "Configuring first launch"),
    ]

    static let uninstallSteps: [StepState] = [
        StepState(id: "quit", title: "Closing DNS Redirect"),
        StepState(id: "dns", title: "Removing DNS changes"),
        StepState(id: "cert", title: "Removing HTTPS certificate"),
        StepState(id: "login", title: "Removing login item"),
        StepState(id: "app", title: "Removing the app"),
        StepState(id: "data", title: "Removing rules and settings"),
        StepState(id: "verify", title: "Verifying system is clean"),
    ]

    private func step(_ id: String, _ status: StepState.Status, _ detail: String = "") {
        progress(id, status, detail)
    }

    private func pause() async { try? await Task.sleep(for: .milliseconds(Self.stepDelay)) }
    /// Small delay so each step is visible in the UI; 0 in headless mode.
    nonisolated(unsafe) static var stepDelay = 350

    // MARK: Install

    func install(options: InstallOptions) async throws {
        let fm = FileManager.default
        guard let payload else { throw InstallerFailure(message: "The installer is missing its application package.") }

        step("verify", .running)
        let sig = CodeSignature.verify(payload.url)
        guard sig.ok else { step("verify", .failed, sig.detail); throw InstallerFailure(message: "The application package is damaged: \(sig.detail)") }
        guard payload.architectures.contains(HostInfo.hardwareArchitecture) else {
            step("verify", .failed); throw InstallerFailure(message: "This build doesn't include \(HostInfo.hardwareArchitecture.title).")
        }
        await pause()
        step("verify", .done, "\(payload.version) · \(payload.architectures.map(\.rawValue).joined(separator: " + "))")

        step("quit", .running)
        let closed = try await quitRunningApp()
        step("quit", closed == 0 ? .skipped : .done, closed == 0 ? "Not running" : "Closed \(closed) running cop\(closed == 1 ? "y" : "ies")")

        step("copy", .running, destination.path)
        try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let staging = installDirectory.appendingPathComponent(".DNS Redirect.app.installing-\(UUID().uuidString.prefix(8))")
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: payload.url, to: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            step("copy", .failed, error.localizedDescription)
            throw InstallerFailure(message: "Could not copy the app to \(installDirectory.path): \(error.localizedDescription)")
        }
        await pause()
        step("copy", .done, destination.path)

        step("check", .running)
        let installed = CodeSignature.verify(destination)
        let helperOK = fm.isExecutableFile(atPath: destination.appendingPathComponent("Contents/MacOS/dnsredirect-helper").path)
        guard installed.ok, helperOK else {
            step("check", .failed, installed.ok ? "Helper missing" : installed.detail)
            throw InstallerFailure(message: "The installed copy failed validation: \(installed.ok ? "the DNS helper is missing" : installed.detail).")
        }
        await pause()
        step("check", .done, "Signature valid · helper present")

        step("register", .running)
        let status = LSRegisterURL(destination as CFURL, true)
        await pause()
        step("register", status == noErr ? .done : .skipped, status == noErr ? "Added to Launchpad and Spotlight" : "Launch Services returned \(status)")

        step("configure", .running)
        let detail = try configure(options: options)
        await pause()
        step("configure", .done, detail)

        writeReceipt(payload: payload)
    }

    /// Writes first-run settings without touching existing rules.
    func configure(options: InstallOptions) throws -> String {
        let store = ConfigurationStore(directory: dataDirectory)
        let existed = FileManager.default.fileExists(atPath: store.configurationURL.path)
        var (config, _) = store.load()
        config.settings.showMenuBarExtra = options.showMenuBarExtra
        config.settings.autoApply = options.autoApply
        config.settings.applyAtLaunch = options.applyAtLaunch
        try store.save(config)
        let pending = ["launchAtLogin": options.launchAtLogin]
        let data = try JSONEncoder().encode(pending)
        try data.write(to: dataDirectory.appendingPathComponent("pending-setup.json"), options: .atomic)
        let rules = config.allRules.count
        return existed ? "Kept \(rules) existing rule\(rules == 1 ? "" : "s"), updated preferences" : "Created a fresh configuration"
    }

    private func writeReceipt(payload: Payload) {
        let receipt: [String: String] = [
            "path": destination.path,
            "version": payload.version,
            "architecture": HostInfo.hardwareArchitecture.rawValue,
            "macOS": HostInfo.osVersionString,
            "installedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dataDirectory.appendingPathComponent("install-receipt.json"), options: .atomic)
        }
    }

    /// Asks running copies of DNS Redirect to quit (they clean up their own temporary DNS state).
    func quitRunningApp(timeout: TimeInterval = 60) async throws -> Int {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Payload.bundleIdentifier)
        guard !running.isEmpty else { return 0 }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) { return running.count }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw InstallerFailure(message: "DNS Redirect is still running. Quit it from its menu bar icon, then try again.")
    }

    // MARK: Uninstall

    struct UninstallReport {
        var dnsRemoved = false
        var appRemoved: [URL] = []
        var dataRemoved = false
    }

    func uninstall(removeUserData: Bool, appLocations: [URL]) async throws -> UninstallReport {
        var report = UninstallReport()
        let fm = FileManager.default

        step("quit", .running)
        let closed = try await quitRunningApp()
        step("quit", closed == 0 ? .skipped : .done, closed == 0 ? "Not running" : "Closed")

        // DNS changes: hosts section + resolver files. Only these are touched.
        step("dns", .running)
        let before = SystemSnapshot.read(paths: systemPaths)
        if before.hasManagedChanges {
            let executor = try self.executor ?? makeAdminExecutor()
            do {
                let result = try await executor.perform(.restore(port: 53535))
                report.dnsRemoved = result.changedAnything
            } catch {
                step("dns", .failed, error.localizedDescription)
                throw InstallerFailure(message: (error as? PrivilegedError) == .authorizationDenied
                    ? "Administrator permission is needed to remove DNS Redirect's entries from /etc/hosts. Nothing was uninstalled."
                    : "Could not remove DNS changes: \(error.localizedDescription). Nothing was uninstalled.")
            }
            step("dns", .done, "Removed \(before.managedMappings.count) hosts entr\(before.managedMappings.count == 1 ? "y" : "ies"), \(before.resolverDomains.count) resolver file(s)")
        } else {
            step("dns", .skipped, "No DNS changes installed")
        }

        step("cert", .running)
        let certs = WebCertificateManager(directory: dataDirectory)
        if certs.existingCA() != nil || certs.isTrusted() || fm.fileExists(atPath: dataDirectory.appendingPathComponent("WebRedirect").path) {
            do { try certs.removeAll(); step("cert", .done, "Trust and keys removed") } catch {
                step("cert", .failed, error.localizedDescription)
            }
        } else {
            step("cert", .skipped, "None installed")
        }

        step("login", .running)
        var unregistered = false
        for app in appLocations where fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/DNS Redirect").path) {
            let p = Process()
            p.executableURL = app.appendingPathComponent("Contents/MacOS/DNS Redirect")
            p.arguments = ["--unregister-login-item"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                unregistered = unregistered || p.terminationStatus == 0
            }
        }
        step("login", unregistered ? .done : .skipped, unregistered ? "Login item cleared" : "Nothing to remove")

        step("app", .running)
        for app in appLocations where fm.fileExists(atPath: app.path) {
            guard Bundle(url: app)?.bundleIdentifier == Payload.bundleIdentifier else { continue }
            do {
                try fm.trashItem(at: app, resultingItemURL: nil)
            } catch {
                try fm.removeItem(at: app)
            }
            report.appRemoved.append(app)
        }
        await pause()
        step("app", report.appRemoved.isEmpty ? .skipped : .done,
             report.appRemoved.isEmpty ? "No installed copy found" : "Moved \(report.appRemoved.map(\.path).joined(separator: ", ")) to the Trash")

        step("data", .running)
        if removeUserData {
            try? fm.removeItem(at: dataDirectory)
            UserDefaults.standard.removePersistentDomain(forName: Payload.bundleIdentifier)
            report.dataRemoved = true
            step("data", .done, "Deleted \(dataDirectory.path)")
        } else if fm.fileExists(atPath: dataDirectory.path) {
            // Keep rules, but make sure a reinstall doesn't silently re-apply them.
            let store = ConfigurationStore(directory: dataDirectory)
            var (config, _) = store.load()
            config.redirectsEnabled = false
            try? store.save(config)
            try? fm.removeItem(at: dataDirectory.appendingPathComponent("install-receipt.json"))
            try? fm.removeItem(at: dataDirectory.appendingPathComponent("pending-setup.json"))
            step("data", .skipped, "Kept in \(dataDirectory.path) (redirects paused)")
        } else {
            step("data", .skipped, "Nothing stored")
        }

        step("verify", .running)
        let after = SystemSnapshot.read(paths: systemPaths)
        await pause()
        if after.hasManagedChanges {
            step("verify", .failed, "DNS changes are still present")
            throw InstallerFailure(message: "DNS Redirect's entries are still in /etc/hosts or /etc/resolver.")
        }
        step("verify", .done, "No DNS Redirect entries remain · other hosts entries untouched")
        return report
    }

    /// Uses the helper inside the installer's own payload, so uninstall works even if the
    /// installed app was already deleted.
    private func makeAdminExecutor() throws -> PrivilegedExecuting {
        guard let helper = payload?.helperURL, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw InstallerFailure(message: "The installer is missing the DNS helper needed to remove DNS changes.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("DNSRedirectInstaller-\(getpid())", isDirectory: true)
        return AppleScriptExecutor(helperURL: helper, stagingDirectory: staging)
    }
}
