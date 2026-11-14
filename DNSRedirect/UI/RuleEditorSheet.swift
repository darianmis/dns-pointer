import DNSRedirectCore
import SwiftUI

struct RuleEditorSheet: View {
    let request: EditorRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var sources = ""
    @State private var destination = ""
    @State private var mode: AliasMode = .webRedirect
    @State private var note = ""
    @State private var enabled = true
    @State private var profileID: UUID = UUID()
    @State private var loaded = false
    @State private var showErrors = false

    private var editingRule: RedirectRule? {
        if case .edit(let id) = request { return model.configuration.rule(id: id) }
        return nil
    }

    private var isEditing: Bool { editingRule != nil }

    // MARK: Validation

    private var sourceList: [String] {
        isEditing ? [sources.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty } : DomainName.splitList(sources)
    }

    private var sourceErrors: [String] {
        if sourceList.isEmpty { return ["Enter a source domain."] }
        var errors: [String] = []
        var seen = Set<String>()
        for s in sourceList {
            do {
                let n = try DomainName.validate(s)
                if !seen.insert(n).inserted { errors.append("\(n) is listed twice.") }
            } catch {
                errors.append("\(s): \(error.localizedDescription)")
            }
        }
        return errors
    }

    private var parsedDestination: Result<RuleDestination, Error> {
        Result { try RuleDestination.parse(destination) }
    }

    private var destinationDescription: (text: String, ok: Bool) {
        switch parsedDestination {
        case .success(.addresses(let a)):
            let v4 = a.filter { $0.family == .v4 }.count, v6 = a.count - v4
            var parts: [String] = []
            if v4 > 0 { parts.append("\(v4) IPv4") }
            if v6 > 0 { parts.append("\(v6) IPv6") }
            return ("IP mapping · " + parts.joined(separator: " + ") + (a.count > 1 ? " addresses" : " address"), true)
        case .success(.domain(let d)):
            return ("Domain alias → \(d)", true)
        case .failure(let e):
            return (destination.isEmpty ? "Enter an IP address (IPv4 or IPv6) or a domain name." : e.localizedDescription, destination.isEmpty)
        }
    }

    private var isDomainDestination: Bool {
        if case .success(.domain) = parsedDestination { return true }
        return false
    }

    private var candidateRules: [RedirectRule] {
        sourceList.map { s in
            var r = RedirectRule(id: editingRule?.id ?? UUID(), source: s, destination: destination,
                                 isEnabled: enabled, aliasMode: isDomainDestination ? mode : .hostsSnapshot, note: note)
            if let e = editingRule { r.createdAt = e.createdAt }
            return r
        }
    }

    private var ruleErrors: [String] {
        var errors: [String] = []
        for r in candidateRules {
            do { _ = try r.validated() } catch {
                let message = error.localizedDescription
                if case .invalidSource = error as? RuleValidationError { continue } // already shown
                if case .invalidDestination = error as? RuleValidationError { continue }
                if case .mixedDestination = error as? RuleValidationError { continue }
                errors.append("\(r.source): \(message)")
            }
        }
        return Array(Set(errors)).sorted()
    }

    private var conflictIssues: [RuleIssue] {
        guard sourceErrors.isEmpty, case .success = parsedDestination else { return [] }
        var all: [RuleIssue] = []
        for r in candidateRules { all += RuleConflictChecker.issues(for: r, in: profileID, configuration: model.configuration) }
        var seen = Set<String>()
        return all.filter { seen.insert($0.message).inserted }
    }

    private var canSave: Bool {
        guard sourceErrors.isEmpty, case .success = parsedDestination, ruleErrors.isEmpty else { return false }
        return !conflictIssues.contains { $0.severity == .error }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: isEditing ? "pencil.line" : "plus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                    .shadow(color: Theme.cyan.opacity(0.5), radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Redirect" : "Add Redirect")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text("Map hostnames to an IP address or another domain, on this Mac only.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(isEditing ? "Source domain" : "Source domain(s)",
                          hint: isEditing ? nil : "To point several domains at the same destination, separate them with commas or spaces.") {
                        NeonTextField(placeholder: "example.com", text: $sources, invalid: showErrors && !sourceErrors.isEmpty)
                        if (showErrors || !sources.isEmpty) && !sourceErrors.isEmpty {
                            errorList(sourceErrors)
                        } else if sourceList.count > 1 {
                            Text("\(sourceList.count) rules will be created.")
                                .font(.system(size: 11)).foregroundStyle(Theme.cyan)
                        }
                    }

                    field("Destination", hint: nil) {
                        NeonTextField(placeholder: "192.168.1.100  ·  ::1  ·  new.example.com", text: $destination,
                                      invalid: !destinationDescription.ok && !destination.isEmpty)
                        HStack(spacing: 6) {
                            Image(systemName: destinationDescription.ok ? (destination.isEmpty ? "info.circle" : "checkmark.circle.fill") : "xmark.circle.fill")
                            Text(destinationDescription.text)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(destinationDescription.ok ? (destination.isEmpty ? Theme.textTertiary : Theme.green) : Theme.red)
                    }

                    if isDomainDestination {
                        modePicker
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    HStack(alignment: .top, spacing: 16) {
                        field("Profile", hint: nil) {
                            Picker("Profile", selection: $profileID) {
                                ForEach(model.configuration.profiles) { p in
                                    Text(p.name + (p.isActive ? "" : " (inactive)")).tag(p.id)
                                }
                            }
                            .labelsHidden()
                        }
                        field("Status", hint: nil) {
                            Toggle(isOn: $enabled) {
                                Text(enabled ? "Enabled" : "Disabled").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            }
                            .toggleStyle(NeonToggleStyle())
                        }
                    }

                    field("Note", hint: nil) {
                        NeonTextField(placeholder: "Optional, e.g. “staging API”", text: $note, mono: false)
                    }

                    if !ruleErrors.isEmpty { errorList(ruleErrors) }

                    ForEach(conflictIssues, id: \.message) { issue in
                        Banner(kind: issue.severity == .error ? .error : .warning, message: issue.message)
                    }

                    InfoNote(text: "This is a DNS-level mapping. It changes which IP address apps connect to. It does not redirect HTTP, change the URL in the browser, or change the HTTPS certificate. The server at the destination must accept requests for the original hostname.")
                }
                .padding(.trailing, 6)
                .animation(.easeOut(duration: 0.2), value: isDomainDestination)
            }

            HStack {
                if isEditing, let rule = editingRule {
                    Button("Duplicate") { model.duplicateRule(rule.id); dismiss() }
                        .buttonStyle(NeonButtonStyle(kind: .ghost))
                    Button("Delete", role: .destructive) {
                        model.deleteRules([rule.id])
                        dismiss()
                    }
                    .buttonStyle(NeonButtonStyle(kind: .destructive))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(NeonButtonStyle(kind: .ghost))
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save Changes" : (sourceList.count > 1 ? "Add \(sourceList.count) Redirects" : "Add Redirect")) { save() }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave && showErrors)
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 580, height: 640)
        .background(Theme.background)
        .onAppear(perform: load)
    }

    private var modePicker: some View {
        field("Domain alias method", hint: nil) {
            VStack(spacing: 8) {
                modeOption(.webRedirect, symbol: "arrow.uturn.right.circle",
                           text: "Recommended for websites. Browsers that open the source land on the destination site, and the address bar changes to it. The path is kept (source.com/page → destination.com/page). Works for http and https while DNS Redirect is running. HTTPS needs the DNS Redirect certificate to be trusted once (you'll be asked for your password).")
                if mode == .webRedirect && !model.certificateTrusted {
                    Banner(kind: .info, message: "HTTPS web redirects need the DNS Redirect certificate to be trusted on this Mac. You'll be asked when the rule is applied, or you can do it now.",
                           actionTitle: "Trust Certificate…") { model.trustCertificate() }
                }
                modeOption(.hostsSnapshot, symbol: "doc.text",
                           text: "DNS only. Resolves the destination now and writes its current IP addresses into /etc/hosts. Works even when DNS Redirect is closed. Sites on shared hosting (Google, Cloudflare, AWS…) will still show the original site, because the server sees the original name.")
                modeOption(.liveResolver, symbol: "dot.radiowaves.left.and.right",
                           text: "DNS only. The local resolver answers with a CNAME to the destination on every lookup, so address changes are followed automatically. Same shared-hosting caveat as Snapshot. Requires DNS Redirect to be running.")
                if mode == .liveResolver && !model.settings.resolverEnabled {
                    Banner(kind: .warning, message: "The local resolver is turned off. This rule won't work until you turn it on.",
                           actionTitle: "Turn On Resolver") { model.updateSettings { $0.resolverEnabled = true } }
                }
            }
        }
    }

    private func modeOption(_ value: AliasMode, symbol: String, text: String) -> some View {
        let selected = mode == value
        return Button { withAnimation(.easeOut(duration: 0.15)) { mode = value } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.cyan : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Label(value.title, systemImage: symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.cyan.opacity(0.07) : Theme.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.cyan.opacity(0.5) : Theme.stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field<Content: View>(_ title: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textTertiary)
            content()
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorList(_ errors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(errors, id: \.self) { e in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                    Text(e)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.red)
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch request {
        case .edit(let id):
            guard let rule = model.configuration.rule(id: id) else { return }
            sources = rule.source
            destination = rule.destination
            mode = rule.aliasMode
            note = rule.note
            enabled = rule.isEnabled
            profileID = model.profileID(containing: id) ?? model.configuration.profiles[0].id
        case .add(let pid):
            profileID = pid ?? model.configuration.profiles.first(where: \.isActive)?.id ?? model.configuration.profiles[0].id
        }
    }

    private func save() {
        showErrors = true
        guard canSave else { return }
        let normalized = sourceList.compactMap { try? DomainName.validate($0) }
        let effectiveMode = isDomainDestination ? mode : .hostsSnapshot
        if var rule = editingRule {
            rule.source = normalized[0]
            rule.destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.aliasMode = effectiveMode
            rule.note = note
            rule.isEnabled = enabled
            model.updateRule(rule, profileID: profileID)
        } else {
            model.addRules(sources: normalized, destination: destination, mode: effectiveMode, note: note, enabled: enabled, profileID: profileID)
        }
        dismiss()
    }
}
