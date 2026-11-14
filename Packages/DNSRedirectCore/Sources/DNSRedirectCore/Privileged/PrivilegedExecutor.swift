import Foundation

public enum PrivilegedError: Error, LocalizedError, Equatable, Sendable {
    case authorizationDenied
    case helperMissing(String)
    case helperFailed(String)
    case staging(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Administrator authorization was cancelled. No system files were changed."
        case .helperMissing(let path):
            return "The privileged helper is missing from the app bundle (\(path)). Rebuild the app."
        case .helperFailed(let m):
            return m
        case .staging(let m):
            return "Could not prepare the change request: \(m)"
        }
    }
}

/// Performs a privileged request. The production implementation asks macOS for an
/// administrator password; tests use `DirectExecutor` against temporary files.
public protocol PrivilegedExecuting: Sendable {
    func perform(_ request: PrivilegedRequest) async throws -> OperationResult
    func flushCache() async throws
}

/// Runs operations in-process without privileges against arbitrary paths (tests, previews).
public struct DirectExecutor: PrivilegedExecuting {
    public var paths: SystemPaths
    public init(paths: SystemPaths) { self.paths = paths }

    public func perform(_ request: PrivilegedRequest) async throws -> OperationResult {
        try SystemOperations.apply(request, paths: paths)
    }

    public func flushCache() async throws {}
}

/// Runs the bundled `dnsredirect-helper` as root through the standard macOS
/// administrator authentication dialog (`do shell script … with administrator privileges`).
///
/// - The command line is fixed: `<helper> apply <request.json>`. Both paths are app-controlled
///   and passed through AppleScript's `quoted form of`; no user text reaches a shell.
/// - The request file is written to a 0700 directory; the helper re-validates its contents.
/// - Runs in-process via NSAppleScript, so macOS caches the authorization for a few minutes
///   and repeated edits don't prompt every time.
@MainActor
public final class AppleScriptExecutor: PrivilegedExecuting {
    public let helperURL: URL
    public let stagingDirectory: URL

    public init(helperURL: URL, stagingDirectory: URL) {
        self.helperURL = helperURL
        self.stagingDirectory = stagingDirectory
    }

    public func perform(_ request: PrivilegedRequest) async throws -> OperationResult {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw PrivilegedError.helperMissing(helperURL.path)
        }
        let fm = FileManager.default
        let requestURL = stagingDirectory.appendingPathComponent("request-\(UUID().uuidString).json")
        do {
            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
            let data = try JSONEncoder().encode(request)
            guard fm.createFile(atPath: requestURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw PrivilegedError.staging("could not write \(requestURL.path)")
            }
        } catch let e as PrivilegedError {
            throw e
        } catch {
            throw PrivilegedError.staging(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: requestURL) }
        let text = try runHelper(arguments: ["apply", requestURL.path])
        guard let result = try? JSONDecoder().decode(OperationResult.self, from: Data(text.utf8)) else {
            throw PrivilegedError.helperFailed("The helper returned an unexpected response: \(text.prefix(200))")
        }
        return result
    }

    public func flushCache() async throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw PrivilegedError.helperMissing(helperURL.path)
        }
        _ = try runHelper(arguments: ["flush"])
    }

    /// Runs the helper with a fixed set of app-controlled arguments as root.
    private func runHelper(arguments: [String]) throws -> String {
        let command = ([helperURL.path] + arguments)
            .map { "(quoted form of \"\(Self.escape($0))\")" }
            .joined(separator: " & \" \" & ")
        let source = """
        do shell script \(command) ¬
            with prompt "DNS Redirect wants to update /etc/hosts and its DNS resolver settings." ¬
            with administrator privileges
        """
        guard let script = NSAppleScript(source: source) else {
            throw PrivilegedError.helperFailed("Could not prepare the authorization script.")
        }
        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -128 { throw PrivilegedError.authorizationDenied }
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown error (\(number))."
            throw PrivilegedError.helperFailed(message)
        }
        return output.stringValue ?? ""
    }

    /// Escapes a string for inclusion inside an AppleScript string literal.
    nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
