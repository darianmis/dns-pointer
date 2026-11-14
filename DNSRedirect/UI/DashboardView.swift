import DNSRedirectCore
import SwiftUI
import UniformTypeIdentifiers

enum RuleFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", pending = "Pending", disabled = "Off", issues = "Issues"
    var id: String { rawValue }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case any = "Any type", ip = "IP", domain = "Domain"
    var id: String { rawValue }
}

struct RuleRowModel: Identifiable {
    var rule: RedirectRule
    var profile: Profile
    var status: RuleStatus
    var id: UUID { rule.id }
}

struct DashboardView: View {
    let profileID: UUID?
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: RuleFilter = .all
    @State private var kindFilter: KindFilter = .any
    @State private var selection: Set<UUID> = []
    @State private var pendingDelete: Set<UUID> = []
    @State private var exporting = false
    @State private var importing = false
    @State private var exportDocument: JSONFile?

    private var profile: Profile? { model.profile(profileID) }

    private var allRows: [RuleRowModel] {
        model.configuration.profiles
            .filter { profileID == nil || $0.id == profileID }
            .flatMap { p in p.rules.map { RuleRowModel(rule: $0, profile: p, status: model.status(for: $0)) } }
    }

    private var rows: [RuleRowModel] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return allRows.filter { row in
            if !q.isEmpty {
                let hay = [row.rule.source, row.rule.destination, row.rule.note, row.profile.name].joined(separator: " ").lowercased()
                    + " " + (model.evaluations[row.rule.id]?.addresses.map(\.description).joined(separator: " ") ?? "")
                guard hay.contains(q) else { return false }
            }
            switch kindFilter {
            case .any: break
            case .ip: guard row.rule.kind == .ip else { return false }
            case .domain: guard row.rule.kind == .domain else { return false }
            }
            switch filter {
            case .all: return true
            case .active: return row.status.isActive
            case .pending: return row.status == .pending || row.status == .evaluating
            case .disabled:
                if case .disabled = row.status { return true }
                if case .inactive = row.status { return true }
                return false
            case .issues: return row.status.isProblem
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statStrip
            banners
            toolbar
            ruleTable
            InfoNote(text: "DNS-level mapping only. Apps get a different IP address for the name. This is not an HTTP redirect: the URL in the browser and the HTTPS certificate the server must present stay the same.")
        }
        .padding(24)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "dns-redirect-\(profile?.name.lowercased().replacingOccurrences(of: " ", with: "-") ?? "rules").json") { result in
            if case .success(let url) = result {
                model.recordExport(to: url, count: profile?.rules.count ?? model.configuration.allRules.count)
            } else if case .failure(let error) = result {
                model.alert = AlertMessage(title: "Export Failed", message: error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.importRules(from: url) }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                withAnimation(.easeOut(duration: 0.2)) { model.deleteRules(pendingDelete) }
                selection.subtract(pendingDelete)
                pendingDelete = []
            }
        } message: {
            Text("Only the overrides DNS Redirect created for these rules are removed.")
        }
        .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection } }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? "Delete \(model.configuration.rule(id: pendingDelete.first!)?.source ?? "rule")?"
            : "Delete \(pendingDelete.count) rules?"
    }

    // MARK: Sections

    private var header: some View {
        PageHeader(title: profile?.name ?? "All Rules",
                   subtitle: profile.map { $0.isActive ? "Active profile · \($0.rules.count) rule(s)" : "Inactive profile · its rules are not applied" }
                    ?? "Every redirect across \(model.configuration.profiles.count) profile(s)") {
            HStack(spacing: 14) {
                if let profile {
                    Toggle(isOn: Binding(get: { profile.isActive }, set: { model.setProfileActive(profile.id, $0) })) {
                        Text("Profile").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .toggleStyle(NeonToggleStyle())
                }
                Toggle(isOn: Binding(get: { model.configuration.redirectsEnabled }, set: { model.setRedirectsEnabled($0) })) {
                    Text("All Redirects").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(NeonToggleStyle())
                .help("Master switch for every rule managed by DNS Redirect")
                Button {
                    model.editor = .add(profileID: profileID)
                } label: {
                    Label("Add Redirect", systemImage: "plus")
                }
                .buttonStyle(NeonButtonStyle(kind: .primary))
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var statStrip: some View {
        HStack(spacing: 12) {
            StatCard(title: "Active Rules", value: "\(model.activeRuleCount) / \(model.enabledRuleCount)",
                     symbol: "bolt.horizontal.fill", tint: Theme.green,
                     detail: "Rules currently installed out of enabled rules in active profiles")
            StatCard(title: "Hosts File", value: hostsCardValue,
                     symbol: "doc.text.fill",
                     tint: model.system.hostsError != nil || model.system.hostsLocked ? Theme.red : (model.needsApply ? Theme.amber : Theme.cyan),
                     detail: model.hostsStatusText)
            StatCard(title: "Local Resolver", value: resolverCardValue,
                     symbol: "server.rack",
                     tint: model.resolverRunning ? Theme.cyan : (model.settings.resolverEnabled ? Theme.red : Theme.textTertiary),
                     detail: model.resolverStatusText)
            StatCard(title: "Last Applied", value: model.lastAppliedAt?.relativeShort ?? "Not yet",
                     symbol: "clock.arrow.circlepath", tint: Theme.blue,
                     detail: "Last time DNS Redirect changed system files in this session")
        }
    }

    private var hostsCardValue: String {
        if model.system.hostsError != nil { return "Error" }
        if model.system.hostsLocked { return "Locked" }
        if model.phase == .applying { return "Applying…" }
        return model.needsApply ? "Pending" : "In sync"
    }

    private var resolverCardValue: String {
        switch model.resolverState {
        case .running(let port): return "On · :\(port)"
        case .starting: return "Starting…"
        case .failed: return "Failed"
        case .stopped: return model.settings.resolverEnabled ? "Stopped" : "Off"
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 8) {
            if case .failed(let message) = model.phase {
                Banner(kind: .error, message: message, actionTitle: "Retry") { Task { await model.applyNow() } }
            } else if model.phase == .applying {
                Banner(kind: .working, message: "Applying changes. macOS may ask for an administrator password.")
            } else if model.needsApply && model.phase == .idle && model.system.hostsError == nil {
                Banner(kind: .warning,
                       message: model.settings.autoApply
                        ? "The system doesn't match your rules yet."
                        : "You have changes that are not applied yet. Automatic apply is off.",
                       actionTitle: "Apply Now") { Task { await model.applyNow() } }
            }
            if let err = model.system.hostsError {
                Banner(kind: .error, message: err, actionTitle: "Re-check") { model.refreshSystemState() }
            } else if model.system.hostsLocked {
                Banner(kind: .error, message: SystemOperationError.hostsLocked.localizedDescription, actionTitle: "Re-check") { model.refreshSystemState() }
            }
            if !model.configuration.redirectsEnabled {
                Banner(kind: .info, message: "All redirects are paused. Nothing from DNS Redirect is installed on this Mac.",
                       actionTitle: "Enable") { model.setRedirectsEnabled(true) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.phase)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            SearchField(placeholder: "Search domains, IPs, notes…", text: $search)
                .frame(maxWidth: 320)
            Picker("Status", selection: $filter) {
                ForEach(RuleFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Picker("Type", selection: $kindFilter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            Spacer()
            Button {
                Task { await model.testAll(rows.filter { $0.status.isActive || $0.status == .pending }.map(\.id)) }
            } label: {
                Label("Test All", systemImage: "checkmark.seal")
            }
            .buttonStyle(NeonButtonStyle(kind: .secondary, compact: true))
            .disabled(rows.isEmpty)
            Menu {
                Button("Apply Changes Now") { Task { await model.applyNow() } }
                Button("Refresh Resolved Addresses") { Task { await model.refreshResolvedAddresses() } }
                Button("Flush DNS Cache") { Task { await model.flushDNSCache() } }
                Divider()
                Button("Import Rules…") { importing = true }
                Button(profile == nil ? "Export All Rules…" : "Export “\(profile!.name)”…") {
                    do {
                        exportDocument = JSONFile(data: try model.exportData(profileIDs: profileID.map { [$0] }))
                        exporting = true
                    } catch {
                        model.alert = AlertMessage(title: "Export Failed", message: error.localizedDescription)
                    }
                }
                if !selection.isEmpty {
                    Divider()
                    Button("Enable Selected") { selection.forEach { model.setRuleEnabled($0, true) } }
                    Button("Disable Selected") { selection.forEach { model.setRuleEnabled($0, false) } }
                    Button("Delete Selected…", role: .destructive) { pendingDelete = selection }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    private var ruleTable: some View {
        VStack(spacing: 0) {
            TableHeader()
            Divider().overlay(Theme.stroke)
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            RuleRow(row: row, showProfile: profileID == nil, selected: selection.contains(row.id),
                                    onSelect: { extend in select(row.id, extend: extend) },
                                    onDelete: { pendingDelete = [row.id] })
                                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: rows.map(\.id))
                }
            }
        }
        .frame(maxHeight: .infinity)
        .glowPanel(glow: false, padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func select(_ id: UUID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: allRows.isEmpty ? "point.3.connected.trianglepath.dotted" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accentGradient)
                .shadow(color: Theme.cyan.opacity(0.5), radius: 12)
            Text(allRows.isEmpty ? "No redirects yet" : "No rules match your filters")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            Text(allRows.isEmpty
                 ? "Point a domain at an IP address or at another domain. For example, example.com → 192.168.1.100."
                 : "Try clearing the search or choosing a different filter.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if allRows.isEmpty {
                Button { model.editor = .add(profileID: profileID) } label: { Label("Add Redirect", systemImage: "plus") }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
            } else {
                Button("Clear Filters") { search = ""; filter = .all; kindFilter = .any }
                    .buttonStyle(NeonButtonStyle(kind: .secondary))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Table

enum Columns {
    static let toggle: CGFloat = 46
    static let type: CGFloat = 74
    static let status: CGFloat = 104
    static let actions: CGFloat = 70
}

struct TableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("").frame(width: Columns.toggle)
            label("Source Domain").frame(maxWidth: .infinity, alignment: .leading)
            label("Destination").frame(maxWidth: .infinity, alignment: .leading)
            label("Type").frame(width: Columns.type, alignment: .leading)
            label("Resolved IP").frame(maxWidth: .infinity, alignment: .leading)
            label("Status").frame(width: Columns.status, alignment: .leading)
            Text("").frame(width: Columns.actions)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panelRaised.opacity(0.6))
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Theme.textTertiary)
    }
}

struct RuleRow: View {
    let row: RuleRowModel
    let showProfile: Bool
    let selected: Bool
    let onSelect: (_ extend: Bool) -> Void
    let onDelete: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var rule: RedirectRule { row.rule }
    private var evaluation: RuleEvaluation? { model.evaluations[rule.id] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { model.setRuleEnabled(rule.id, $0) }))
                    .toggleStyle(NeonToggleStyle(size: 0.85))
                    .labelsHidden()
                    .frame(width: Columns.toggle)
                    .accessibilityLabel("Enable \(rule.source)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.source)
                        .font(Theme.mono(13, weight: .medium))
                        .foregroundStyle(rule.isEnabled ? Theme.text : Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    if showProfile || !rule.note.isEmpty {
                        Text([showProfile ? row.profile.name : nil, rule.note.isEmpty ? nil : rule.note].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.cyan.opacity(0.7))
                    Text(rule.destination)
                        .font(Theme.mono(13))
                        .foregroundStyle(rule.isEnabled ? Theme.cyan : Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Tag(text: rule.kind.label, color: rule.kind == .ip ? Theme.blue : Theme.violet)
                    if rule.effectiveMode == .webRedirect {
                        Image(systemName: "arrow.uturn.right.circle").font(.system(size: 10)).foregroundStyle(Theme.cyan)
                            .help("Web redirect: browsers are sent to the destination")
                    }
                    if rule.effectiveMode == .liveResolver {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10)).foregroundStyle(Theme.violet)
                            .help("Live alias served by the local resolver")
                    }
                }
                .frame(width: Columns.type, alignment: .leading)

                resolvedColumn.frame(maxWidth: .infinity, alignment: .leading)

                StatusBadge(status: row.status)
                    .id(row.status)
                    .frame(width: Columns.status, alignment: .leading)

                HStack(spacing: 2) {
                    if model.isTesting(rule.id) {
                        ProgressView().controlSize(.small).frame(width: 26, height: 26)
                    } else {
                        IconButton(symbol: "checkmark.seal", help: "Test this rule") { Task { await model.testRule(rule.id) } }
                    }
                    IconButton(symbol: "pencil", help: "Edit") { model.editor = .edit(ruleID: rule.id) }
                }
                .frame(width: Columns.actions, alignment: .trailing)
                .opacity(hovering || selected || model.isTesting(rule.id) ? 1 : 0.35)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let message = row.status.detail, row.status.isProblem || { if case .inactive = row.status { return selected } else { return false } }() {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(message).font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(row.status.color)
                .padding(.leading, 14 + Columns.toggle + 12)
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            }

            if let result = model.testResults[rule.id] {
                TestResultView(result: result) { model.testResults[rule.id] = nil }
                    .padding(.leading, 14 + Columns.toggle + 12)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider().overlay(Theme.stroke)
        }
        .background(
            Rectangle()
                .fill(selected ? Theme.cyan.opacity(0.08) : (hovering ? Theme.panelRaised.opacity(0.7) : .clear))
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.accentGradient).frame(width: 2).opacity(selected ? 1 : 0)
                .shadow(color: Theme.cyan, radius: 4)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { model.editor = .edit(ruleID: rule.id) })
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { onSelect(true) })
        .simultaneousGesture(TapGesture().onEnded { onSelect(false) })
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: model.testResults[rule.id])
        .contextMenu {
            Button("Edit…") { model.editor = .edit(ruleID: rule.id) }
            Button("Test") { Task { await model.testRule(rule.id) } }
            Button(rule.isEnabled ? "Disable" : "Enable") { model.setRuleEnabled(rule.id, !rule.isEnabled) }
            Button("Duplicate") { model.duplicateRule(rule.id) }
            Divider()
            Button("Copy Source Domain") { copy(rule.source) }
            Button("Copy Destination") { copy(rule.destination) }
            if let e = evaluation, !e.addresses.isEmpty {
                Button("Copy Resolved Addresses") { copy(e.addresses.map(\.description).joined(separator: ", ")) }
            }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var resolvedColumn: some View {
        if let e = evaluation, e.mode == .webRedirect, e.state.willInstall {
            Text("→ https://\(rule.destination)")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.cyan.opacity(0.85))
                .lineLimit(1).truncationMode(.tail)
                .help("Served by DNS Redirect on this Mac (127.0.0.1 / ::1), which redirects browsers to the destination")
        } else if let e = evaluation, e.mode == .liveResolver, e.state.willInstall {
            Text("dynamic (CNAME)")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.violet)
                .help("Resolved on every query by the local resolver")
        } else if let e = evaluation, !e.addresses.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(e.addresses.map(\.description).joined(separator: ", "))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .textSelection(.enabled)
                if rule.kind == .domain, let at = e.resolvedAt {
                    Text("resolved \(at.relativeShort)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .help(e.addresses.map(\.description).joined(separator: "\n"))
        } else {
            Text("—").font(Theme.mono(11.5)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct TestResultView: View {
    let result: RuleTestResult
    let onDismiss: () -> Void

    private var color: Color {
        switch result.outcome {
        case .pass: return Theme.green
        case .partial: return Theme.amber
        case .fail: return Theme.red
        case .notApplicable: return Theme.textSecondary
        }
    }

    private var symbol: String {
        switch result.outcome {
        case .pass: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .notApplicable: return "minus.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                    .shadow(color: color.opacity(0.6), radius: 4)
                Text(result.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                Spacer()
                Text(result.testedAt.formatted(date: .omitted, time: .standard))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                IconButton(symbol: "xmark", help: "Dismiss", action: onDismiss)
            }
            if result.outcome != .notApplicable {
                HStack(spacing: 18) {
                    labeled("system resolver", result.resolved.isEmpty ? (result.resolutionError ?? "—") : result.resolved.map(\.description).joined(separator: ", "))
                    labeled("expected", result.expected.isEmpty ? "—" : result.expected.map(\.description).joined(separator: ", "))
                }
            }
            ForEach(result.hints, id: \.self) { hint in
                HStack(alignment: .top, spacing: 6) {
                    Text("›").font(Theme.mono(11)).foregroundStyle(Theme.cyan)
                    Text(hint).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.3), lineWidth: 1))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.mono(11.5)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
        }
    }
}

/// Minimal FileDocument wrapper for exporting JSON.
struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
