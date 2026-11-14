import Foundation

/// JSON persistence for the configuration and activity log.
public struct ConfigurationStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DNS Redirect", isDirectory: true)
    }

    public var configurationURL: URL { directory.appendingPathComponent("configuration.json") }
    public var logURL: URL { directory.appendingPathComponent("activity-log.json") }
    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    public var stagingDirectory: URL { directory.appendingPathComponent("Staging", isDirectory: true) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads the configuration. A missing file yields defaults; a corrupt file is moved aside
    /// (never silently overwritten) and defaults are returned along with a warning.
    public func load() -> (AppConfiguration, warning: String?) {
        guard let data = try? Data(contentsOf: configurationURL) else { return (AppConfiguration(), nil) }
        do {
            return (try Self.decoder.decode(AppConfiguration.self, from: data), nil)
        } catch {
            let aside = directory.appendingPathComponent("configuration.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: configurationURL, to: aside)
            return (AppConfiguration(), "The saved configuration could not be read and was moved to \(aside.lastPathComponent). Starting fresh.")
        }
    }

    public func save(_ configuration: AppConfiguration) throws {
        try ensureDirectory()
        try Self.encoder.encode(configuration).write(to: configurationURL, options: .atomic)
    }

    public func loadLog() -> [ActivityEntry] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        return (try? Self.decoder.decode([ActivityEntry].self, from: data)) ?? []
    }

    public func saveLog(_ entries: [ActivityEntry]) throws {
        try ensureDirectory()
        try Self.encoder.encode(entries).write(to: logURL, options: .atomic)
    }

    /// Copies the hosts file once, before the app first modifies it.
    @discardableResult
    public func backupHostsIfNeeded(from hosts: URL) throws -> URL? {
        let target = backupsDirectory.appendingPathComponent("hosts.original")
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: hosts.resolvingSymlinksInPath(), to: target)
        return target
    }
}

public struct ActivityEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable {
        case info, success, warning, error
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case rules, system, resolver, test, lookup, profiles, importExport
    }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var category: Category
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: Level, category: Category, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

// MARK: - Import / Export

public struct RulesDocument: Codable, Sendable {
    public static let formatIdentifier = "dns-redirect.rules"

    public var format: String = RulesDocument.formatIdentifier
    public var version: Int = 1
    public var exportedAt: Date = Date()
    public var profiles: [Profile]

    public init(profiles: [Profile]) {
        self.profiles = profiles
    }

    public func encoded() throws -> Data {
        try ConfigurationStore.encoder.encode(self)
    }

    public enum ImportError: Error, LocalizedError {
        case unrecognized(String)
        public var errorDescription: String? {
            if case .unrecognized(let m) = self { return "This file is not a DNS Redirect rules export. \(m)" }
            return nil
        }
    }

    /// Accepts a full export, a single profile object, or a bare array of rules.
    public static func decode(_ data: Data) throws -> RulesDocument {
        let decoder = ConfigurationStore.decoder
        if let doc = try? decoder.decode(RulesDocument.self, from: data), doc.format == formatIdentifier {
            return doc
        }
        if let rules = try? decoder.decode([RedirectRule].self, from: data) {
            return RulesDocument(profiles: [Profile(name: "Imported", rules: rules)])
        }
        if let profile = try? decoder.decode(Profile.self, from: data), !profile.rules.isEmpty {
            return RulesDocument(profiles: [profile])
        }
        do {
            _ = try decoder.decode(RulesDocument.self, from: data)
            throw ImportError.unrecognized("Unknown format identifier.")
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.unrecognized(error.localizedDescription)
        }
    }
}

public struct ImportSummary: Equatable, Sendable {
    public var added = 0
    public var duplicatesSkipped = 0
    public var invalid: [String] = []
    public var profilesCreated = 0

    public init() {}
}

public extension AppConfiguration {
    /// Merges imported profiles. Profiles with matching names are merged; duplicates are skipped;
    /// invalid rules are reported and skipped. Imported rules get fresh IDs.
    mutating func merge(_ document: RulesDocument) -> ImportSummary {
        var summary = ImportSummary()
        for incoming in document.profiles {
            let index: Int
            if let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame }) {
                index = i
            } else {
                profiles.append(Profile(name: incoming.name, isActive: incoming.isActive))
                index = profiles.count - 1
                summary.profilesCreated += 1
            }
            for var rule in incoming.rules {
                do { _ = try rule.validated() } catch {
                    summary.invalid.append("\(rule.source) → \(rule.destination): \(error.localizedDescription)")
                    continue
                }
                if profiles[index].rules.contains(where: { $0.isDuplicate(of: rule) }) {
                    summary.duplicatesSkipped += 1
                    continue
                }
                rule.id = UUID()
                rule.updatedAt = Date()
                profiles[index].rules.append(rule)
                summary.added += 1
            }
        }
        return summary
    }
}
