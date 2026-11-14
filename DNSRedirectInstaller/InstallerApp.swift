import AppKit
import DNSRedirectCore
import SwiftUI

@main
enum InstallerEntry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--unattended") {
            Headless.run(Array(args[(i + 1)...]))
        }
        #if DEBUG
        if let i = args.firstIndex(of: "--render-pages"), i + 1 < args.count {
            MainActor.assumeIsolated { PageSnapshots.run(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        #endif
        InstallerApp.main()
    }
}

struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerDelegate.self) private var delegate
    @State private var model = InstallerModel()

    var body: some Scene {
        Window("DNS Redirect Installer", id: "installer") {
            WizardView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(width: 820, height: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `--unattended install|uninstall|check [--target DIR] [--data-dir DIR] [--system-root DIR] [--launch-at-login] [--remove-data]`
/// Prints one JSON object per step and exits 0 on success. Used for automated testing.
enum Headless {
    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return (args[i + 1] as NSString).expandingTildeInPath
        }
        let command = args.first ?? "check"
        let target = value("--target").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let dataDir = value("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ConfigurationStore.defaultDirectory
        var paths = SystemPaths.system
        var executor: PrivilegedExecuting?
        if let root = value("--system-root") {
            paths = SystemPaths(hostsFile: URL(fileURLWithPath: root).appendingPathComponent("etc/hosts"),
                                resolverDirectory: URL(fileURLWithPath: root).appendingPathComponent("etc/resolver"))
            executor = DirectExecutor(paths: paths)
        }
        InstallerEngine.stepDelay = 0
        func emit(_ object: [String: Any]) {
            if let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(d + Data("\n".utf8))
            }
        }
        Task { @MainActor in
            let check = SystemCheck.run(payload: .embedded(), preferredDirectory: target, systemPaths: paths)
            for item in check.items {
                emit(["check": item.id, "title": item.title, "detail": item.detail, "level": "\(item.level)"])
            }
            let engine = InstallerEngine(installDirectory: target ?? check.installDirectory, dataDirectory: dataDir,
                                         systemPaths: paths, executor: executor)
            engine.progress = { id, status, detail in emit(["step": id, "status": "\(status)", "detail": detail]) }
            do {
                switch command {
                case "check":
                    emit(["result": check.canInstall ? "compatible" : "incompatible"])
                    exit(check.canInstall ? 0 : 2)
                case "install":
                    guard check.canInstall else { emit(["result": "incompatible"]); exit(2) }
                    var options = InstallOptions()
                    options.launchAtLogin = args.contains("--launch-at-login")
                    try await engine.install(options: options)
                    emit(["result": "installed", "path": engine.destination.path])
                case "uninstall":
                    let locations = [engine.destination] + (check.existingInstall.map { [$0] } ?? [])
                    let report = try await engine.uninstall(removeUserData: args.contains("--remove-data"),
                                                            appLocations: Array(Set(locations)))
                    emit(["result": "uninstalled", "removed": report.appRemoved.map(\.path), "dnsRemoved": report.dnsRemoved])
                default:
                    emit(["error": "unknown command \(command)"]); exit(64)
                }
                exit(0)
            } catch {
                emit(["result": "failed", "error": error.localizedDescription])
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
