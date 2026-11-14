import DNSRedirectCore
import SwiftUI

struct ActivityLogView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var level: ActivityEntry.Level?
    @State private var category: ActivityEntry.Category?
    @State private var confirmClear = false

    private var entries: [ActivityEntry] {
        let q = search.lowercased()
        return model.log.filter { e in
            (level == nil || e.level == level) && (category == nil || e.category == category)
                && (q.isEmpty || e.message.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Activity Log", subtitle: "Rule changes, system updates, tests, and errors, newest first.") {
                Button("Clear Log…") { confirmClear = true }
                    .buttonStyle(NeonButtonStyle(kind: .ghost))
                    .disabled(model.log.isEmpty)
            }
            HStack(spacing: 10) {
                SearchField(placeholder: "Filter messages…", text: $search).frame(maxWidth: 320)
                Picker("Level", selection: $level) {
                    Text("All levels").tag(ActivityEntry.Level?.none)
                    ForEach(ActivityEntry.Level.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                .labelsHidden().frame(width: 120)
                Picker("Category", selection: $category) {
                    Text("All categories").tag(ActivityEntry.Category?.none)
                    ForEach(ActivityEntry.Category.allCases, id: \.self) { Text(label(for: $0)).tag(Optional($0)) }
                }
                .labelsHidden().frame(width: 150)
                Spacer()
                Text("\(entries.count) entries").font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
            }

            Group {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "list.bullet.rectangle.portrait").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.accentGradient)
                        Text(model.log.isEmpty ? "Nothing logged yet." : "No entries match.").foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                LogRow(entry: entry, categoryLabel: label(for: entry.category))
                                Divider().overlay(Theme.stroke)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .glowPanel(padding: 0)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))

            InfoNote(text: "DNS Redirect logs only its own actions and checks. It does not see DNS queries made by other apps. The one exception is the local resolver, which counts the queries it answers for live-alias domains (shown under System).")
        }
        .padding(24)
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearLog() }
        }
    }

    private func label(for c: ActivityEntry.Category) -> String {
        switch c {
        case .rules: return "Rules"
        case .system: return "System"
        case .resolver: return "Resolver"
        case .test: return "Tests"
        case .lookup: return "Lookups"
        case .profiles: return "Profiles"
        case .importExport: return "Import/Export"
        }
    }
}

struct LogRow: View {
    let entry: ActivityEntry
    let categoryLabel: String

    private var color: Color {
        switch entry.level {
        case .info: return Theme.cyan
        case .success: return Theme.green
        case .warning: return Theme.amber
        case .error: return Theme.red
        }
    }

    private var symbol: String {
        switch entry.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 130, alignment: .leading)
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 12))
            Tag(text: categoryLabel.uppercased(), color: color).frame(width: 110, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
