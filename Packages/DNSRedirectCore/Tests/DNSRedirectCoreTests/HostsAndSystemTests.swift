import XCTest
@testable import DNSRedirectCore

let stockHosts = """
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1\tlocalhost
255.255.255.255\tbroadcasthost
::1             localhost
10.1.1.1  intranet.corp   # user's own entry

"""

final class ManagedHostsBlockTests: XCTestCase {
    let entries = [
        HostsEntry(address: IPAddress("192.168.1.100")!, hostnames: ["example.com", "www.example.com"]),
        HostsEntry(address: IPAddress("::1")!, hostnames: ["test.local"]),
    ]

    func testInsertThenRemoveRestoresOriginalExactly() throws {
        let applied = try ManagedHostsBlock.applying(entries, to: stockHosts)
        XCTAssertTrue(applied.hasPrefix(stockHosts), "unrelated content must be preserved verbatim")
        XCTAssertTrue(applied.contains("192.168.1.100\texample.com www.example.com"))
        XCTAssertTrue(applied.contains("::1\ttest.local"))
        XCTAssertEqual(try ManagedHostsBlock.removing(from: applied), stockHosts)
    }

    func testReplaceKeepsSurroundingContent() throws {
        let withBlock = try ManagedHostsBlock.applying(entries, to: stockHosts) + "# user line added after block\n"
        let replaced = try ManagedHostsBlock.applying([HostsEntry(address: IPAddress("10.0.0.9")!, hostnames: ["x.dev"])], to: withBlock)
        XCTAssertTrue(replaced.hasPrefix(stockHosts))
        XCTAssertTrue(replaced.hasSuffix("# user line added after block\n"))
        XCTAssertFalse(replaced.contains("example.com"))
        XCTAssertEqual(try ManagedHostsBlock.managedEntries(in: replaced), [HostsEntry(address: IPAddress("10.0.0.9")!, hostnames: ["x.dev"])])
    }

    func testIdempotent() throws {
        let once = try ManagedHostsBlock.applying(entries, to: stockHosts)
        XCTAssertEqual(try ManagedHostsBlock.applying(entries, to: once), once)
    }

    func testFileWithoutTrailingNewline() throws {
        let applied = try ManagedHostsBlock.applying(entries, to: "127.0.0.1 localhost")
        XCTAssertTrue(applied.hasPrefix("127.0.0.1 localhost\n" + ManagedHostsBlock.beginMarker))
    }

    func testEmptyEntriesWithoutBlockIsNoOp() throws {
        XCTAssertEqual(try ManagedHostsBlock.applying([], to: stockHosts), stockHosts)
    }

    func testDamagedBlocksAreRefused() {
        let unterminated = stockHosts + ManagedHostsBlock.beginMarker + "\n1.2.3.4 a.com\n"
        XCTAssertThrowsError(try ManagedHostsBlock.applying(entries, to: unterminated)) {
            XCTAssertEqual($0 as? HostsFileError, .unterminatedBlock(line: 11))
        }
        let orphanEnd = stockHosts + ManagedHostsBlock.endMarker + "\n"
        XCTAssertThrowsError(try ManagedHostsBlock.applying(entries, to: orphanEnd))
        let block = try! ManagedHostsBlock.render(entries: entries).joined(separator: "\n")
        XCTAssertThrowsError(try ManagedHostsBlock.applying(entries, to: block + "\n" + block + "\n")) {
            XCTAssertEqual($0 as? HostsFileError, .multipleBlocks)
        }
    }

    func testRenderRejectsInvalidHostnames() {
        XCTAssertThrowsError(try ManagedHostsBlock.render(entries: [HostsEntry(address: IPAddress("1.1.1.1")!, hostnames: ["bad host;rm -rf"])]))
        XCTAssertThrowsError(try ManagedHostsBlock.render(entries: [HostsEntry(address: IPAddress("1.1.1.1")!, hostnames: ["localhost"])]))
    }

    func testLongHostnameListsAreSplit() throws {
        let names = (1...14).map { "h\($0).test" }
        let lines = try ManagedHostsBlock.render(entries: [HostsEntry(address: IPAddress("1.1.1.1")!, hostnames: names)])
        XCTAssertEqual(lines.filter { $0.hasPrefix("1.1.1.1") }.count, 3)
    }

    func testUnmanagedMappings() throws {
        let applied = try ManagedHostsBlock.applying(entries, to: stockHosts)
        let map = ManagedHostsBlock.unmanagedMappings(in: applied)
        XCTAssertEqual(map["intranet.corp"], [IPAddress("10.1.1.1")!])
        XCTAssertNil(map["example.com"], "managed entries are excluded")
        XCTAssertEqual(Set(map["localhost"] ?? []), [IPAddress("127.0.0.1")!, IPAddress("::1")!])
    }
}

final class SystemOperationsTests: XCTestCase {
    var dir: URL!
    var paths: SystemPaths!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dnsredirect-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = SystemPaths(hostsFile: dir.appendingPathComponent("hosts"), resolverDirectory: dir.appendingPathComponent("resolver"))
        try stockHosts.write(to: paths.hostsFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func hostsText() throws -> String { try String(contentsOf: paths.hostsFile, encoding: .utf8) }

    func testApplyAndRestoreRoundTrip() throws {
        // A resolver file the user created themselves must never be touched.
        try FileManager.default.createDirectory(at: paths.resolverDirectory, withIntermediateDirectories: true)
        let foreign = paths.resolverDirectory.appendingPathComponent("corp.example")
        try "nameserver 10.0.0.53\n".write(to: foreign, atomically: true, encoding: .utf8)

        let request = PrivilegedRequest(
            hostsEntries: [HostsEntry(address: IPAddress("127.0.0.1")!, hostnames: ["test.local"])],
            resolverDomains: ["old.example.com", "corp.example"],
            resolverPort: 53535)
        let result = try SystemOperations.apply(request, paths: paths)
        XCTAssertTrue(result.hostsChanged)
        XCTAssertEqual(result.resolverFilesWritten, ["old.example.com"])
        XCTAssertEqual(result.resolverConflicts, ["corp.example"])
        XCTAssertTrue(try hostsText().contains("127.0.0.1\ttest.local"))

        let snapshot = SystemSnapshot.read(paths: paths)
        XCTAssertEqual(snapshot.managedMappings["test.local"], [IPAddress("127.0.0.1")!])
        XCTAssertEqual(snapshot.resolverDomains, ["old.example.com": 53535])
        XCTAssertEqual(snapshot.unmanagedMappings["intranet.corp"], [IPAddress("10.1.1.1")!])

        // Re-applying the same request is a no-op.
        let again = try SystemOperations.apply(request, paths: paths)
        XCTAssertFalse(again.changedAnything)

        // Restore removes only what the app created.
        let restored = try SystemOperations.apply(.restore(port: 53535), paths: paths)
        XCTAssertTrue(restored.hostsChanged)
        XCTAssertEqual(restored.resolverFilesRemoved, ["old.example.com"])
        XCTAssertEqual(try hostsText(), stockHosts)
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "nameserver 10.0.0.53\n")
        XCTAssertFalse(SystemSnapshot.read(paths: paths).hasManagedChanges)
    }

    func testPreservesFilePermissions() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: paths.hostsFile.path)
        _ = try SystemOperations.apply(PrivilegedRequest(hostsEntries: [HostsEntry(address: IPAddress("1.1.1.1")!, hostnames: ["a.test"])],
                                                         resolverDomains: [], resolverPort: 53535), paths: paths)
        let mode = try FileManager.default.attributesOfItem(atPath: paths.hostsFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o640)
    }

    func testWritesThroughSymlinkedHostsFile() throws {
        let real = dir.appendingPathComponent("real-hosts")
        try FileManager.default.moveItem(at: paths.hostsFile, to: real)
        try FileManager.default.createSymbolicLink(at: paths.hostsFile, withDestinationURL: real)
        _ = try SystemOperations.apply(PrivilegedRequest(hostsEntries: [HostsEntry(address: IPAddress("1.1.1.1")!, hostnames: ["a.test"])],
                                                         resolverDomains: [], resolverPort: 53535), paths: paths)
        let type = try FileManager.default.attributesOfItem(atPath: paths.hostsFile.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "the user's symlink is kept")
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("a.test"))
    }

    func testRejectsInvalidRequests() {
        let bad = PrivilegedRequest(hostsEntries: [HostsEntry(address: IPAddress("1.1.1.1")!, hostnames: ["$(reboot)"])], resolverDomains: [], resolverPort: 53535)
        XCTAssertThrowsError(try SystemOperations.apply(bad, paths: paths))
        let tld = PrivilegedRequest(hostsEntries: [], resolverDomains: ["com"], resolverPort: 53535)
        XCTAssertThrowsError(try SystemOperations.apply(tld, paths: paths))
        let port = PrivilegedRequest(hostsEntries: [], resolverDomains: ["a.com"], resolverPort: 53)
        XCTAssertThrowsError(try SystemOperations.apply(port, paths: paths))
        XCTAssertEqual(try hostsText(), stockHosts, "nothing written on rejection")
    }

    func testRefusesDamagedManagedSection() throws {
        try (stockHosts + ManagedHostsBlock.beginMarker + "\n").write(to: paths.hostsFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SystemOperations.apply(.restore(port: 53535), paths: paths)) { error in
            guard case .hostsFormat(.unterminatedBlock)? = error as? SystemOperationError else { return XCTFail("\(error)") }
        }
        XCTAssertNotNil(SystemSnapshot.read(paths: paths).hostsError)
    }

    func testDirectExecutorAndRequestCoding() async throws {
        let request = PrivilegedRequest(hostsEntries: [HostsEntry(address: IPAddress("::1")!, hostnames: ["v6.test"])], resolverDomains: [], resolverPort: 60000)
        let decoded = try JSONDecoder().decode(PrivilegedRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        let result = try await DirectExecutor(paths: paths).perform(decoded)
        XCTAssertTrue(result.hostsChanged)
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(AppleScriptExecutor.escape(#"/Apps/My "Dev" \ Tools"#), #"/Apps/My \"Dev\" \\ Tools"#)
    }
}
