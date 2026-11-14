import AppKit
import DNSRedirectCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Applying Rules") {
                Toggle("Apply changes automatically", isOn: binding(\.autoApply))
                Text("Saves to the system right after each edit. macOS asks for your password, then remembers it for a few minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Re-apply rules when DNS Redirect launches", isOn: binding(\.applyAtLaunch))
            }
            Section("App") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { v in
                    model.setLaunchAtLogin(v)
                    launchAtLogin = model.launchAtLogin
                }))
                if let err = model.launchAtLoginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: binding(\.showMenuBarExtra))
                Picker("Appearance", selection: binding(\.appearance)) {
                    Text("Dark").tag(AppearancePreference.dark)
                    Text("Match System").tag(AppearancePreference.system)
                }
            }
            Section("Local Resolver") {
                Toggle("Enable local resolver for live aliases", isOn: binding(\.resolverEnabled))
                Toggle("Remove resolver files when quitting", isOn: binding(\.removeResolverConfigOnQuit))
                LabeledContent("Port", value: String(model.settings.resolverPort))
                Text("Change the port under System in the main window.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { v in model.updateSettings { $0[keyPath: keyPath] = v } })
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.configuration.redirectsEnabled
             ? "\(model.activeRuleCount) active rule\(model.activeRuleCount == 1 ? "" : "s")"
             : "Redirects paused")
        Text("Hosts: \(model.hostsStatusText)")
        Text("Resolver: \(model.resolverStatusText)")
        Divider()
        Toggle("Redirects Enabled", isOn: Binding(get: { model.configuration.redirectsEnabled },
                                                  set: { model.setRedirectsEnabled($0) }))
        Menu("Profiles") {
            ForEach(model.configuration.profiles) { profile in
                Toggle(profile.name, isOn: Binding(get: { profile.isActive }, set: { model.setProfileActive(profile.id, $0) }))
            }
            Divider()
            Menu("Switch To") {
                ForEach(model.configuration.profiles) { profile in
                    Button(profile.name) { model.switchToProfile(profile.id) }
                }
            }
        }
        if model.needsApply {
            Button("Apply Pending Changes") { Task { await model.applyNow() } }
        }
        Button("Flush DNS Cache") { Task { await model.flushDNSCache() } }
        Divider()
        Button("Open Dashboard…") {
            openWindow(id: MainWindow.id)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")
        Button("Add Redirect…") {
            openWindow(id: MainWindow.id)
            NSApp.activate(ignoringOtherApps: true)
            model.editor = .add(profileID: nil)
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit DNS Redirect") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
