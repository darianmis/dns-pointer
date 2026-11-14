import Darwin
import Foundation

/// Locations of the system files the app manages. Injectable so tests can use a temp dir.
public struct SystemPaths: Sendable, Hashable {
    public var hostsFile: URL
    public var resolverDirectory: URL

    public init(hostsFile: URL, resolverDirectory: URL) {
        self.hostsFile = hostsFile
        self.resolverDirectory = resolverDirectory
    }

    public static let system = SystemPaths(hostsFile: URL(fileURLWithPath: "/etc/hosts"),
                                           resolverDirectory: URL(fileURLWithPath: "/etc/resolver"))
}

/// The complete, declarative request sent to the privileged helper. The helper never receives
/// free-form text or commands; it re-validates every field before touching the system.
public struct PrivilegedRequest: Codable, Hashable, Sendable {
    public static let maxEntries = 5000

    public var hostsEntries: [HostsEntry]
    public var resolverDomains: [String]
    public var resolverPort: UInt16
    public var flushCache: Bool

    public init(hostsEntries: [HostsEntry], resolverDomains: [String], resolverPort: UInt16, flushCache: Bool = true) {
        self.hostsEntries = hostsEntries
        self.resolverDomains = resolverDomains
        self.resolverPort = resolverPort
        self.flushCache = flushCache
    }

    /// Removes everything the app manages.
    public static func restore(port: UInt16) -> PrivilegedRequest {
        PrivilegedRequest(hostsEntries: [], resolverDomains: [], resolverPort: port)
    }

    public func validate() throws {
        guard hostsEntries.count <= Self.maxEntries, resolverDomains.count <= Self.maxEntries else {
            throw SystemOperationError.invalidRequest("Too many entries.")
        }
        for entry in hostsEntries {
            for host in entry.hostnames {
                do { try DomainName.validate(host) } catch {
                    throw SystemOperationError.invalidRequest("Invalid hostname “\(host)”: \(error.localizedDescription)")
                }
            }
        }
        for domain in resolverDomains {
            do { try DomainName.validate(domain) } catch {
                throw SystemOperationError.invalidRequest("Invalid resolver domain “\(domain)”: \(error.localizedDescription)")
            }
            guard DomainName.labelCount(domain) >= 2 else {
                throw SystemOperationError.invalidRequest("Refusing to create a resolver for single-label domain “\(domain)”.")
            }
        }
        guard resolverPort >= 1024 else {
            throw SystemOperationError.invalidRequest("Resolver port must be 1024 or higher.")
        }
    }
}

public struct OperationResult: Codable, Hashable, Sendable {
    public var hostsChanged: Bool = false
    public var resolverFilesWritten: [String] = []
    public var resolverFilesRemoved: [String] = []
    /// Domains whose /etc/resolver file exists but is not ours; left untouched.
    public var resolverConflicts: [String] = []
    public var cacheFlushed: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostsChanged = try c.decodeIfPresent(Bool.self, forKey: .hostsChanged) ?? false
        resolverFilesWritten = try c.decodeIfPresent([String].self, forKey: .resolverFilesWritten) ?? []
        resolverFilesRemoved = try c.decodeIfPresent([String].self, forKey: .resolverFilesRemoved) ?? []
        resolverConflicts = try c.decodeIfPresent([String].self, forKey: .resolverConflicts) ?? []
        cacheFlushed = try c.decodeIfPresent(Bool.self, forKey: .cacheFlushed) ?? false
    }

    public var changedAnything: Bool {
        hostsChanged || !resolverFilesWritten.isEmpty || !resolverFilesRemoved.isEmpty
    }
}

public enum SystemOperationError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case hostsLocked
    case hostsUnreadable(String)
    case writeFailed(String)
    case hostsFormat(HostsFileError)
    case notRoot

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let m): return "Rejected request: \(m)"
        case .hostsLocked:
            return "/etc/hosts is locked (it has the immutable flag set). Unlock it in Finder (Get Info → Locked) or with `chflags nouchg /etc/hosts`, then try again."
        case .hostsUnreadable(let m): return "Could not read /etc/hosts: \(m)"
        case .writeFailed(let m): return "Could not write system files: \(m)"
        case .hostsFormat(let e): return e.localizedDescription
        case .notRoot: return "The helper must run with administrator privileges."
        }
    }
}

/// File operations the privileged helper performs. Pure Foundation, path-injectable, testable.
public enum SystemOperations {
    public static let resolverMarker = "# Managed by DNS Redirect.app. This file is created and removed automatically."

    public static func resolverFileContent(port: UInt16) -> String {
        """
        \(resolverMarker)
        nameserver 127.0.0.1
        port \(port)
        timeout 3

        """
    }

    public static func isManagedResolverFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        return String(decoding: head, as: UTF8.self).hasPrefix(resolverMarker)
    }

    public static func isImmutable(_ url: URL) -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        return st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0
    }

    public static func apply(_ request: PrivilegedRequest, paths: SystemPaths) throws -> OperationResult {
        try request.validate()
        var result = OperationResult()

        // --- /etc/hosts ---
        let hostsURL = paths.hostsFile.resolvingSymlinksInPath()
        let original: String
        if FileManager.default.fileExists(atPath: hostsURL.path) {
            guard let data = FileManager.default.contents(atPath: hostsURL.path) else {
                throw SystemOperationError.hostsUnreadable("permission denied")
            }
            guard let text = String(data: data, encoding: .utf8) else { throw SystemOperationError.hostsFormat(.notUTF8) }
            original = text
        } else {
            original = ""
        }
        let updated: String
        do { updated = try ManagedHostsBlock.applying(request.hostsEntries, to: original) } catch let e as HostsFileError {
            throw SystemOperationError.hostsFormat(e)
        }
        if updated != original {
            if isImmutable(hostsURL) { throw SystemOperationError.hostsLocked }
            try atomicWrite(Data(updated.utf8), to: hostsURL, defaultMode: 0o644)
            result.hostsChanged = true
        }

        // --- /etc/resolver ---
        let fm = FileManager.default
        let dir = paths.resolverDirectory.resolvingSymlinksInPath()
        let desired = Set(request.resolverDomains)
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in existing where !desired.contains(name) {
            let url = dir.appendingPathComponent(name)
            if isManagedResolverFile(url) {
                do { try fm.removeItem(at: url) } catch {
                    throw SystemOperationError.writeFailed("removing \(url.path): \(error.localizedDescription)")
                }
                result.resolverFilesRemoved.append(name)
            }
        }
        if !desired.isEmpty {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                } catch {
                    throw SystemOperationError.writeFailed("creating \(dir.path): \(error.localizedDescription)")
                }
            }
            let content = resolverFileContent(port: request.resolverPort)
            for domain in desired.sorted() {
                let url = dir.appendingPathComponent(domain)
                if fm.fileExists(atPath: url.path) {
                    guard isManagedResolverFile(url) else {
                        result.resolverConflicts.append(domain)
                        continue
                    }
                    if fm.contents(atPath: url.path) == Data(content.utf8) { continue }
                }
                try atomicWrite(Data(content.utf8), to: url, defaultMode: 0o644)
                result.resolverFilesWritten.append(domain)
            }
        }
        return result
    }

    /// Writes via a temporary file in the same directory followed by rename(2), keeping the
    /// original file's permissions and (when running as root) ownership.
    static func atomicWrite(_ data: Data, to url: URL, defaultMode: Int) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).dnsredirect-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? defaultMode
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw SystemOperationError.writeFailed("could not create a temporary file in \(dir.path)")
        }
        if getuid() == 0 {
            let owner = (attrs?[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
            let group = (attrs?[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0
            chown(tmp.path, owner, group)
        }
        guard rename(tmp.path, url.path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(tmp.path)
            throw SystemOperationError.writeFailed("\(url.path): \(message)")
        }
    }
}

/// Unprivileged view of what the app currently has installed on the system.
public struct SystemSnapshot: Equatable, Sendable {
    public var managedEntries: [HostsEntry] = []
    public var unmanagedMappings: [String: [IPAddress]] = [:]
    public var resolverDomains: [String: UInt16?] = [:]
    public var hostsLocked = false
    public var hostsError: String?
    public var readAt = Date()

    public init() {}

    public var managedMappings: [String: [IPAddress]] { ManagedHostsBlock.mappings(from: managedEntries) }
    public var hasManagedChanges: Bool { !managedEntries.isEmpty || !resolverDomains.isEmpty }

    public static func read(paths: SystemPaths) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        let hostsURL = paths.hostsFile.resolvingSymlinksInPath()
        snapshot.hostsLocked = SystemOperations.isImmutable(hostsURL)
        if let data = FileManager.default.contents(atPath: hostsURL.path) {
            let text = String(decoding: data, as: UTF8.self)
            do {
                snapshot.managedEntries = try ManagedHostsBlock.managedEntries(in: text)
            } catch {
                snapshot.hostsError = error.localizedDescription
            }
            snapshot.unmanagedMappings = ManagedHostsBlock.unmanagedMappings(in: text)
        } else if FileManager.default.fileExists(atPath: hostsURL.path) {
            snapshot.hostsError = "/etc/hosts is not readable."
        }
        let dir = paths.resolverDirectory.resolvingSymlinksInPath()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let url = dir.appendingPathComponent(name)
            guard SystemOperations.isManagedResolverFile(url) else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let port = text.split(separator: "\n")
                .first { $0.hasPrefix("port ") }
                .flatMap { UInt16($0.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
            snapshot.resolverDomains.updateValue(port, forKey: name)
        }
        return snapshot
    }

    /// True when the system already matches `desired`.
    public func matches(_ desired: DesiredState, resolverPort: UInt16) -> Bool {
        let a = managedMappings.mapValues(Set.init)
        let b = desired.hostsMappings.mapValues(Set.init)
        guard a == b else { return false }
        guard Set(resolverDomains.keys) == Set(desired.resolverDomains) else { return false }
        return resolverDomains.values.allSatisfy { $0 == resolverPort }
    }
}
