import DNSRedirectCore
import SwiftUI

struct SystemView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRestore = false
    @State private var confirmUninstall = false
    @State private var portText = ""
    @State private var showBlock = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "System", subtitle: "What DNS Redirect has installed on this Mac, and the tools to manage it.") {
                    Button { model.refreshSystemState() } label: { Label("Re-check", systemImage: "arrow.clockwise") }
                        .buttonStyle(NeonButtonStyle(kind: .secondary))
                }
                HStack(alignment: .top, spacing: 16) {
                    hostsPanel
                    resolverPanel
                }
                webPanel
                maintenancePanel
                limitationsPanel
            }
            .padding(24)
        }
        .onAppear { portText = String(model.settings.resolverPort) }
        .confirmationDialog("Restore the original DNS configuration?", isPresented: $confirmRestore) {
            Button("Remove All DNS Redirect Changes", role: .destructive) { Task { await model.restoreOriginalConfiguration() } }
        } message: {
            Text("This removes the DNS Redirect section from /etc/hosts and its files in /etc/resolver, then flushes the DNS cache. Everything else is left as it was. Your rules are kept and redirects are paused.")
        }
        .confirmationDialog("Uninstall DNS Redirect?", isPresented: $confirmUninstall) {
            Button("Uninstall, Keep My Rules", role: .destructive) { Task { await model.uninstall(removeUserData: false) } }
            Button("Uninstall and Delete Rules & Logs", role: .destructive) { Task { await model.uninstall(removeUserData: true) } }
        } message: {
            Text("This removes DNS Redirect's /etc/hosts section, /etc/resolver files, HTTPS certificate and login item, then moves the app to the Trash. You may be asked for an administrator password. Other hosts entries and system settings are not touched.")
        }
    }

    private var hostsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Hosts File", subtitle: "/etc/hosts · managed section only")
                Spacer()
                Tag(text: model.hostsStatusText.uppercased(),
                    color: model.system.hostsError != nil || model.system.hostsLocked ? Theme.red : (model.needsApply ? Theme.amber : Theme.green))
            }
            kv("Managed hostnames", "\(model.system.managedMappings.count)")
            kv("Desired hostnames", "\(model.desired.hostsMappings.count)")
            kv("Other entries in file", "\(model.system.unmanagedMappings.count) (untouched)")
            kv("Read", model.system.readAt.formatted(date: .omitted, time: .standard))
            if let err = model.system.hostsError { Banner(kind: .error, message: err) }
            DisclosureGroup(isExpanded: $showBlock) {
                Text(managedPreview)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
            } label: {
                Text("Installed section").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            }
            HStack {
                Button { Task { await model.applyNow() } } label: { Label("Apply Now", systemImage: "arrow.down.doc") }
                    .buttonStyle(NeonButtonStyle(kind: model.needsApply ? .primary : .secondary))
                    .disabled(model.phase == .applying)
                Button { Task { await model.refreshResolvedAddresses() } } label: { Label("Refresh Resolved IPs", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(NeonButtonStyle(kind: .secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowPanel()
    }

    private var managedPreview: String {
        if model.system.managedEntries.isEmpty { return "(no DNS Redirect section installed)" }
        let lines = (try? ManagedHostsBlock.render(entries: model.system.managedEntries)) ?? []
        return lines.joined(separator: "\n")
    }

    private var resolverPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Local Resolver", subtitle: "Optional · for live domain → domain aliases")
                Spacer()
                Toggle("", isOn: Binding(get: { model.settings.resolverEnabled }, set: { v in model.updateSettings { $0.resolverEnabled = v } }))
                    .toggleStyle(NeonToggleStyle())
                    .labelsHidden()
                    .accessibilityLabel("Enable local resolver")
            }
            kv("Status", model.resolverStatusText.replacingOccurrences(of: "Running on ", with: "Running · "))
            HStack {
                Text("Port").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                TextField("53535", text: $portText)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
                    .onSubmit(commitPort)
                Button("Set", action: commitPort)
                    .buttonStyle(NeonButtonStyle(kind: .secondary, compact: true))
                    .disabled(UInt16(portText) == model.settings.resolverPort)
            }
            if let p = UInt16(portText), p < 1024 {
                Text("Use a port of 1024 or higher. The resolver runs without root privileges.").font(.system(size: 11)).foregroundStyle(Theme.red)
            }
            kv("Live aliases served", "\(model.desired.resolverAliases.count)")
            kv("Installed /etc/resolver files", model.system.resolverDomains.isEmpty ? "none" : model.system.resolverDomains.keys.sorted().joined(separator: ", "))
            kv("Queries answered / forwarded / failed",
               "\(model.resolverStats.answered) / \(model.resolverStats.forwarded) / \(model.resolverStats.failed)")
            Toggle(isOn: Binding(get: { model.settings.removeResolverConfigOnQuit }, set: { v in model.updateSettings { $0.removeResolverConfigOnQuit = v } })) {
                Text("Remove resolver files and web redirects when quitting").font(.system(size: 12)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.checkbox)
            InfoNote(text: "For each live alias, macOS gets a file at /etc/resolver/<domain> that sends lookups for that domain to 127.0.0.1. The resolver only works while DNS Redirect is running. If the files are left in place after quitting, those domains won't resolve until you open the app again.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowPanel(glow: model.resolverRunning, tint: Theme.violet)
    }

    private var webPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Web Redirect", subtitle: "Sends browsers to the destination site · ports 80 and 443 on this Mac only")
                Spacer()
                Tag(text: model.webRunning ? (model.webState.httpsRunning ? "HTTP + HTTPS" : "HTTP ONLY") : "OFF",
                    color: model.webRunning ? (model.webState.httpsRunning ? Theme.green : Theme.amber) : Theme.textTertiary)
            }
            kv("Status", model.webStatusText)
            kv("Hosts served", model.desired.webRedirects.isEmpty ? "none" : model.desired.webRedirects.keys.sorted().joined(separator: ", "))
            kv("Redirected / not found / refused", "\(model.webStats.redirected) / \(model.webStats.notFound) / \(model.webStats.rejected)")
            kv("HTTPS certificate", model.certificateTrusted ? "Trusted · \(WebCertificateManager.caCommonName)" : "Not trusted")
            if let e = model.webState.error { Banner(kind: .error, message: e) }
            HStack {
                if model.certificateTrusted {
                    Button { model.removeCertificate() } label: { Label("Remove Certificate", systemImage: "xmark.seal") }
                        .buttonStyle(NeonButtonStyle(kind: .secondary))
                } else {
                    Button { model.trustCertificate() } label: { Label("Trust Certificate…", systemImage: "checkmark.seal") }
                        .buttonStyle(NeonButtonStyle(kind: .primary))
                        .disabled(model.certificateBusy)
                }
                if let url = model.certificates.caCertificateURL() {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show Certificate File", systemImage: "doc.badge.ellipsis") }
                        .buttonStyle(NeonButtonStyle(kind: .secondary))
                }
            }
            InfoNote(text: "Web redirect rules point the source domain at this Mac (127.0.0.1 and ::1). DNS Redirect answers on ports 80 and 443, accepts connections only from this Mac, and replies with a redirect to the destination. For HTTPS it uses a certificate from “\(WebCertificateManager.caCommonName)”, a certificate authority created on this Mac. Its private key stays in your login keychain and can't be exported, and trust is limited to your user account and to web server certificates. Firefox uses its own certificate store: turn on security.enterprise_roots.enabled in about:config to use it there. Some sites, Google's among them, are pinned in Chrome. Chrome normally accepts locally trusted certificates for these sites, but apps with their own pinning will refuse the connection.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowPanel(glow: model.webRunning, tint: Theme.cyan)
    }

    private var maintenancePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Maintenance")
            HStack(spacing: 10) {
                Button { Task { await model.flushDNSCache() } } label: { Label("Flush DNS Cache", systemImage: "wind") }
                    .buttonStyle(NeonButtonStyle(kind: .secondary))
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.store.backupsDirectory]) } label: {
                    Label("Show Backup in Finder", systemImage: "folder")
                }
                .buttonStyle(NeonButtonStyle(kind: .secondary))
                .disabled(!FileManager.default.fileExists(atPath: model.store.backupsDirectory.path))
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.store.configurationURL]) } label: {
                    Label("Show Rules File", systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(NeonButtonStyle(kind: .secondary))
                Spacer()
            }
            HStack(spacing: 10) {
                Button(role: .destructive) { confirmRestore = true } label: {
                    Label("Restore Original Configuration…", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(NeonButtonStyle(kind: .destructive))
                Button(role: .destructive) { confirmUninstall = true } label: {
                    Label("Uninstall…", systemImage: "trash")
                }
                .buttonStyle(NeonButtonStyle(kind: .destructive))
            }
            InfoNote(text: "Before its first change, DNS Redirect saves a copy of your original /etc/hosts. Restore removes only what DNS Redirect added, so entries you add by hand later are kept.")
        }
        .glowPanel()
    }

    private var limitationsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "How It Works & Limitations")
            ForEach(limitations, id: \.0) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.1).foregroundStyle(Theme.cyan).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(item.2).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .glowPanel()
    }

    private let limitations: [(String, String, String)] = [
        ("Administrator permission", "lock.shield",
         "Changing /etc/hosts and /etc/resolver needs an administrator password. DNS Redirect runs a small bundled helper through the standard macOS authorization dialog. The helper accepts only a validated list of hostnames, IP addresses and resolver domains. It never runs commands you type."),
        ("Snapshot and live aliases are DNS only", "arrow.uturn.right.circle",
         "Those two methods only change name resolution. The browser still asks the new server for the original name. Shared hosts (Google, Cloudflare, AWS…) then serve the original site, and other servers may show a certificate error. To land on the destination site, use a Web redirect rule."),
        ("Hosts file has no CNAMEs", "doc.text",
         "/etc/hosts maps names to IP addresses only. Snapshot aliases copy the destination's current IPs, which can go stale. Use Refresh Resolved IPs, or a live alias through the local resolver."),
        ("Apps that bypass system DNS", "exclamationmark.shield",
         "Browsers with Secure DNS / DNS-over-HTTPS turned on, iCloud Private Relay, some VPNs, and apps with their own resolvers can ignore local overrides."),
        ("Caching", "clock.arrow.circlepath",
         "macOS caches DNS. DNS Redirect flushes the cache after each change, but browsers and long-lived connections keep their own caches. Restart them if a test still shows old addresses."),
        ("IPv4 and IPv6", "network",
         "If a rule has only an IPv4 address and the real domain has IPv6 records, some apps may still connect over IPv6. Add an IPv6 destination (for example ::1) to cover both."),
    ]

    private func commitPort() {
        guard let p = UInt16(portText), p >= 1024 else { return }
        model.updateSettings { $0.resolverPort = p }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(v).font(Theme.mono(12)).foregroundStyle(Theme.text).multilineTextAlignment(.trailing).textSelection(.enabled)
                .lineLimit(2)
                .layoutPriority(1)
        }
    }
}
