// dnsredirect-helper
//
// The only code in DNS Redirect that runs as root. It is launched by the app through the
// macOS administrator authentication dialog and supports exactly two fixed commands:
//
//   dnsredirect-helper apply <request.json>   Apply a declarative PrivilegedRequest
//   dnsredirect-helper flush                  Flush the macOS DNS cache
//
// It never executes user-supplied strings. The request is decoded with Codable and fully
// re-validated (hostnames, IP addresses, resolver domains, port) before any file is touched.
// Only the marked section of /etc/hosts and marker-tagged files in /etc/resolver are modified.

import DNSRedirectCore
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func flushDNSCache() -> Bool {
    func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    let a = run("/usr/bin/dscacheutil", ["-flushcache"])
    let b = run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    return a && b
}

/// Reads the request file defensively: regular file, not a symlink, bounded size.
func readRequest(at path: String) -> PrivilegedRequest {
    var st = stat()
    guard lstat(path, &st) == 0 else { fail("Request file not found.") }
    guard (st.st_mode & S_IFMT) == S_IFREG else { fail("Request must be a regular file.") }
    guard st.st_size <= 4 * 1024 * 1024 else { fail("Request file is too large.") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("Request file is unreadable.") }
    do {
        return try JSONDecoder().decode(PrivilegedRequest.self, from: data)
    } catch {
        fail("Malformed request: \(error.localizedDescription)")
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: dnsredirect-helper apply <request.json> | flush", code: 64) }
guard getuid() == 0 else {
    fail(SystemOperationError.notRoot.localizedDescription, code: 77)
}

switch args[1] {
case "apply":
    guard args.count == 3 else { fail("usage: dnsredirect-helper apply <request.json>", code: 64) }
    let request = readRequest(at: args[2])
    do {
        var result = try SystemOperations.apply(request, paths: .system)
        if request.flushCache && result.changedAnything {
            result.cacheFlushed = flushDNSCache()
        }
        let out = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(out)
    } catch {
        fail(error.localizedDescription)
    }
case "flush":
    guard flushDNSCache() else { fail("Flushing the DNS cache failed.") }
    FileHandle.standardOutput.write(Data(#"{"cacheFlushed":true}"#.utf8))
default:
    fail("Unknown command.", code: 64)
}
