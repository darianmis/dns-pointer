import AppKit
import DNSRedirectCore
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        // Used by the uninstaller: remove the login item registered by this app, then exit
        // without showing UI or touching DNS settings.
        if CommandLine.arguments.contains("--unregister-login-item") {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                do { try SMAppService.mainApp.unregister() } catch {
                    FileHandle.standardError.write(Data("unregister failed: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            exit(0)
        }
        DNSRedirectApp.main()
    }
}

struct DNSRedirectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("DNS Redirect", id: MainWindow.id) {
            RootView()
                .environment(model)
                .preferredColorScheme(model.preferredColorScheme)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(model: model) }

        MenuBarExtra(isInserted: Binding(
            get: { model.settings.showMenuBarExtra },
            set: { value in model.updateSettings { $0.showMenuBarExtra = value } }
        )) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(count: model.activeRuleCount, enabled: model.configuration.redirectsEnabled)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.preferredColorScheme)
        }
    }
}

enum MainWindow {
    static let id = "main"
}

struct MenuBarLabel: View {
    let count: Int
    let enabled: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: enabled ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
            if enabled && count > 0 { Text("\(count)") }
        }
        .accessibilityLabel("DNS Redirect, \(count) active rules")
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Redirect…") { model.editor = .add(profileID: nil) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Redirects") {
            Button(model.configuration.redirectsEnabled ? "Pause All Redirects" : "Enable All Redirects") {
                model.setRedirectsEnabled(!model.configuration.redirectsEnabled)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Apply Changes Now") { Task { await model.applyNow() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Refresh Resolved Addresses") { Task { await model.refreshResolvedAddresses() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Flush DNS Cache") { Task { await model.flushDNSCache() } }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await AppModel.shared.start()
        }
        #if DEBUG
        MainActor.assumeIsolated { DebugSnapshot.scheduleIfRequested() }
        #endif
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.refreshSystemState() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppModel.shared.settings.showMenuBarExtra }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MainActor.assumeIsolated({ AppModel.shared.isUninstalling }) { return .terminateNow }
        Task { @MainActor in
            await AppModel.shared.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
