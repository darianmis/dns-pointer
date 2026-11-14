import DNSRedirectCore
import SwiftUI

enum SidebarItem: Hashable {
    case rules(profileID: UUID?)
    case lookup
    case activity
    case system
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .rules(profileID: nil)

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            ZStack {
                Theme.background.ignoresSafeArea()
                detail
                    .id(selection)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .animation(.easeOut(duration: 0.2), value: selection)
        }
        .background(Theme.background)
        .sheet(item: $model.editor) { request in
            RuleEditorSheet(request: request)
                .environment(model)
                .preferredColorScheme(model.preferredColorScheme)
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        #if DEBUG
        .onAppear {
            switch DebugSnapshot.page {
            case "lookup": selection = .lookup
            case "activity": selection = .activity
            case "system": selection = .system
            default: break
            }
        }
        #endif
        .onChange(of: model.configuration.profiles.map(\.id)) { _, ids in
            if case .rules(let pid?) = selection, !ids.contains(pid) { selection = .rules(profileID: nil) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .rules(profileID: nil) {
        case .rules(let profileID): DashboardView(profileID: profileID)
        case .lookup: LookupView()
        case .activity: ActivityLogView()
        case .system: SystemView()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var renaming: Profile?
    @State private var deleting: Profile?
    @State private var newProfileName = ""

    var body: some View {
        List(selection: $selection) {
            brand
                .listRowSeparator(.hidden)
                .selectionDisabled()

            Section("Redirects") {
                row("All Rules", symbol: "square.stack.3d.up.fill", item: .rules(profileID: nil),
                    badge: model.configuration.allRules.count)
            }

            Section {
                ForEach(model.configuration.profiles) { profile in
                    profileRow(profile)
                }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    Button {
                        let id = model.addProfile(named: "New Profile")
                        selection = .rules(profileID: id)
                        renaming = model.profile(id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Profile")
                    .accessibilityLabel("New Profile")
                }
            }

            Section("Tools") {
                row("DNS Lookup", symbol: "scope", item: .lookup)
                row("Activity Log", symbol: "list.bullet.rectangle.portrait", item: .activity)
                row("System", symbol: "cpu", item: .system, alert: model.system.hostsError != nil || model.system.hostsLocked)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(item: $renaming) { profile in
            ProfileNameSheet(title: "Rename Profile", initial: profile.name) { name in
                model.renameProfile(profile.id, to: name)
            }
            .preferredColorScheme(model.preferredColorScheme)
        }
        .confirmationDialog("Delete profile “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Profile and \(deleting?.rules.count ?? 0) Rule(s)", role: .destructive) {
                if let d = deleting { model.deleteProfile(d.id) }
                deleting = nil
            }
        } message: {
            Text("Its redirects are removed from the system on the next apply.")
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.accentGradient)
                    .frame(width: 30, height: 30)
                    .shadow(color: Theme.cyan.opacity(0.5), radius: 8)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("DNS Redirect").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text("local resolution control").font(Theme.mono(9.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 8)
    }

    private func row(_ title: String, symbol: String, item: SidebarItem, badge: Int? = nil, alert: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if alert {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.red)
            } else if let badge {
                Text("\(badge)").font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .tag(item)
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack(spacing: 8) {
            Button {
                model.setProfileActive(profile.id, !profile.isActive)
            } label: {
                Circle()
                    .fill(profile.isActive ? Theme.green : Theme.textTertiary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .shadow(color: profile.isActive ? Theme.green.opacity(0.8) : .clear, radius: 4)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(profile.isActive ? "Active. Click to deactivate." : "Inactive. Click to activate.")
            .accessibilityLabel(profile.isActive ? "Deactivate \(profile.name)" : "Activate \(profile.name)")
            Text(profile.name).lineLimit(1)
            Spacer()
            Text("\(profile.rules.count)").font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
        }
        .tag(SidebarItem.rules(profileID: profile.id))
        .contextMenu {
            Button(profile.isActive ? "Deactivate" : "Activate") { model.setProfileActive(profile.id, !profile.isActive) }
            Button("Switch to This Profile Only") { model.switchToProfile(profile.id) }
            Divider()
            Button("Rename…") { renaming = profile }
            Button("Delete…", role: .destructive) { deleting = profile }
                .disabled(model.configuration.profiles.count <= 1)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(model.configuration.redirectsEnabled ? Theme.green : Theme.amber).frame(width: 6, height: 6)
                Text(model.configuration.redirectsEnabled ? "\(model.activeRuleCount) active" : "Paused")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 6) {
                Circle().fill(model.resolverRunning ? Theme.cyan : Theme.textTertiary.opacity(0.5)).frame(width: 6, height: 6)
                Text("resolver: \(model.resolverRunning ? "on" : "off")")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar)
    }
}

struct ProfileNameSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: title)
            NeonTextField(placeholder: "Profile name", text: $name, mono: false) { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(NeonButtonStyle(kind: .ghost))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
        .background(Theme.background)
        .onAppear { name = initial }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name)
        dismiss()
    }
}
