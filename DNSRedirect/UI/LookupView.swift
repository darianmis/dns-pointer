import DNSRedirectCore
import SwiftUI

struct LookupView: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "DNS Lookup",
                       subtitle: "Compare what this Mac resolves with what DNS servers say and with what your rules intend.") { EmptyView() }

            HStack(spacing: 10) {
                NeonTextField(placeholder: "hostname, e.g. example.com", text: $host) { run() }
                Button {
                    run()
                } label: {
                    if running {
                        ProgressView().controlSize(.small).frame(width: 70)
                    } else {
                        Label("Look Up", systemImage: "scope").frame(width: 70)
                    }
                }
                .buttonStyle(NeonButtonStyle(kind: .primary))
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || running)
            }
            .glowPanel(glow: true, padding: 14)

            if !model.configuration.allRules.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Your rules:").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        ForEach(Array(Set(model.configuration.allRules.map(\.source))).sorted().prefix(12), id: \.self) { s in
                            Button(s) { host = s; run() }
                                .buttonStyle(NeonButtonStyle(kind: .secondary, compact: true))
                                .font(Theme.mono(11))
                        }
                    }
                }
            }

            if model.lookups.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "scope").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.accentGradient)
                    Text("Enter a hostname to inspect its resolution.")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(model.lookups) { LookupCard(result: $0) }
                    }
                }
            }
        }
        .padding(24)
    }

    private func run() {
        let h = host
        guard !h.trimmingCharacters(in: .whitespaces).isEmpty, !running else { return }
        running = true
        Task {
            await model.lookup(h)
            running = false
        }
    }
}

struct LookupCard: View {
    let result: LookupResult

    private var verdictColor: Color {
        switch result.verdictOK {
        case true?: return Theme.green
        case false?: return Theme.red
        case nil: return result.rule == nil ? Theme.cyan : Theme.amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(result.hostname).font(Theme.mono(16, weight: .semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
                Spacer()
                Text(result.date.formatted(date: .omitted, time: .standard)).font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.verdictOK == true ? "checkmark.shield.fill" : (result.verdictOK == false ? "xmark.shield.fill" : "info.circle.fill"))
                    .foregroundStyle(verdictColor)
                    .shadow(color: verdictColor.opacity(0.6), radius: 5)
                Text(result.verdict).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
            }
            HStack(alignment: .top, spacing: 12) {
                column(title: "This Mac (system resolver)",
                       subtitle: "Includes /etc/hosts and /etc/resolver · \(Int(result.systemDuration * 1000)) ms",
                       result: result.system, highlight: Set(result.intended))
                column(title: "Upstream DNS (direct query)",
                       subtitle: result.upstreamServers.isEmpty ? "No DNS servers configured" : result.upstreamServers.joined(separator: ", "),
                       result: result.upstream, highlight: [])
                VStack(alignment: .leading, spacing: 6) {
                    header("Intended by DNS Redirect", result.rule.map { "\($0.source) → \($0.destination)" } ?? "No matching rule")
                    if result.intended.isEmpty {
                        Text("—").font(Theme.mono(12)).foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(result.intended, id: \.self) { ip in
                            Text(ip.description).font(Theme.mono(12)).foregroundStyle(Theme.cyan).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glowPanel(padding: 12)
            }
            if result.verdictOK == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(RuleTester.cachingHints, id: \.self) { hint in
                        HStack(alignment: .top, spacing: 6) {
                            Text("›").font(Theme.mono(11)).foregroundStyle(Theme.cyan)
                            Text(hint).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .glowPanel(glow: result.verdictOK == true, tint: verdictColor)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(1).foregroundStyle(Theme.textTertiary)
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(2)
        }
    }

    private func column(title: String, subtitle: String, result: Result<[IPAddress], Error>, highlight: Set<IPAddress>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title, subtitle)
            switch result {
            case .success(let ips) where ips.isEmpty:
                Text("No addresses").font(Theme.mono(12)).foregroundStyle(Theme.textTertiary)
            case .success(let ips):
                ForEach(ips, id: \.self) { ip in
                    HStack(spacing: 5) {
                        Text(ip.description).font(Theme.mono(12))
                            .foregroundStyle(highlight.contains(ip) ? Theme.green : Theme.text)
                            .textSelection(.enabled)
                        Text(ip.family == .v4 ? "A" : "AAAA").font(Theme.mono(9)).foregroundStyle(Theme.textTertiary)
                    }
                }
            case .failure(let error):
                Text(error.localizedDescription).font(.system(size: 11.5)).foregroundStyle(Theme.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowPanel(padding: 12)
    }
}
