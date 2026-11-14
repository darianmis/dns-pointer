import DNSRedirectCore
import SwiftUI

struct WizardView: View {
    @Environment(InstallerModel.self) private var model
    @State private var confirmUninstall = false

    var body: some View {
        HStack(spacing: 0) {
            StepRail()
                .frame(width: 230)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            VStack(spacing: 0) {
                ZStack {
                    content
                        .id(model.page)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                footer
            }
        }
        .background(BackdropView())
        .sheet(isPresented: $confirmUninstall) { UninstallSheet() }
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .welcome: WelcomePage()
        case .check: CheckPage()
        case .options: OptionsPage()
        case .install: ProgressPage()
        case .done: DonePage()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.page == .welcome, model.check?.existingInstall != nil || model.check?.hasManagedDNSChanges == true {
                Button { confirmUninstall = true } label: { Label("Uninstall…", systemImage: "trash") }
                    .buttonStyle(NeonButtonStyle(kind: .ghost))
            }
            Spacer()
            switch model.page {
            case .welcome:
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(NeonButtonStyle(kind: .ghost))
                Button { model.go(.check) } label: { Label("Continue", systemImage: "arrow.right") }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            case .check:
                Button("Back") { model.go(.welcome) }.buttonStyle(NeonButtonStyle(kind: .ghost))
                Button { model.go(.options) } label: { Label("Continue", systemImage: "arrow.right") }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checking || !(model.check?.canInstall ?? false))
            case .options:
                Button("Back") { model.go(.check) }.buttonStyle(NeonButtonStyle(kind: .ghost))
                Button { Task { await model.startInstall() } } label: { Label("Install", systemImage: "arrow.down.circle") }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            case .install:
                if model.failure != nil {
                    Button("Back") { model.go(model.mode == .install ? .options : .welcome) }.buttonStyle(NeonButtonStyle(kind: .ghost))
                    Button { Task { model.mode == .install ? await model.startInstall() : await model.startUninstall() } } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(NeonButtonStyle(kind: .primary))
                } else {
                    Button("Working…") {}.buttonStyle(NeonButtonStyle(kind: .ghost)).disabled(true)
                }
            case .done:
                if model.mode == .install {
                    Button("Show in Finder") { model.revealInstalledApp() }.buttonStyle(NeonButtonStyle(kind: .ghost))
                    Button("Close") { NSApp.terminate(nil) }.buttonStyle(NeonButtonStyle(kind: .secondary))
                    Button { model.launchApp() } label: { Label("Launch App", systemImage: "play.fill") }
                        .buttonStyle(NeonButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Quit Installer") { NSApp.terminate(nil) }
                        .buttonStyle(NeonButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(Theme.background.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

// MARK: - Chrome

struct BackdropView: View {
    var body: some View {
        ZStack {
            Theme.background
            Canvas { context, size in
                let spacing: CGFloat = 28
                var path = Path()
                var x: CGFloat = 0
                while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
                var y: CGFloat = 0
                while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
                context.stroke(path, with: .color(Theme.cyan.opacity(0.035)), lineWidth: 0.5)
            }
            RadialGradient(colors: [Theme.blue.opacity(0.22), .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Theme.cyan.opacity(0.10), .clear], center: .bottomLeading, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

struct StepRail: View {
    @Environment(InstallerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 34, height: 34)
                    .shadow(color: Theme.cyan.opacity(0.5), radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DNS REDIRECT").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.text)
                    Text(model.mode == .install ? "INSTALLER" : "UNINSTALLER")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(2.5)
                        .foregroundStyle(Theme.cyan)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            ForEach(WizardPage.allCases, id: \.self) { page in
                RailItem(page: page, current: model.page, isLast: page == WizardPage.allCases.last)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("v\(model.payload?.version ?? "?")").font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
                Text("\(HostInfo.hardwareArchitecture.rawValue) · macOS \(HostInfo.osVersionString)")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.opacity(0.75))
    }
}

struct RailItem: View {
    let page: WizardPage
    let current: WizardPage
    let isLast: Bool

    private var state: Int { page < current ? 0 : (page == current ? 1 : 2) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(state == 2 ? Theme.panelRaised : Theme.cyan.opacity(state == 1 ? 0.18 : 0.12))
                        .overlay(Circle().strokeBorder(state == 2 ? Theme.strokeStrong : Theme.cyan, lineWidth: state == 1 ? 1.5 : 1))
                        .shadow(color: Theme.cyan.opacity(state == 1 ? 0.7 : 0), radius: 8)
                    Image(systemName: state == 0 ? "checkmark" : page.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(state == 2 ? Theme.textTertiary : Theme.cyan)
                }
                .frame(width: 28, height: 28)
                if !isLast {
                    Rectangle()
                        .fill(state == 0 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.stroke))
                        .frame(width: 2, height: 22)
                }
            }
            Text(page.title)
                .font(.system(size: 13, weight: state == 1 ? .semibold : .regular))
                .foregroundStyle(state == 2 ? Theme.textTertiary : Theme.text)
                .padding(.top, 5)
        }
        .animation(.easeInOut(duration: 0.3), value: current)
    }
}

struct PageTitle: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Theme.cyan)
            Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Pages

struct WelcomePage: View {
    @Environment(InstallerModel.self) private var model
    @State private var spin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 26) {
                ZStack {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [Theme.cyan, Theme.blue.opacity(0.1), Theme.violet.opacity(0.6), Theme.cyan], center: .center), lineWidth: 2)
                        .frame(width: 128, height: 128)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                    Circle().fill(Theme.cyan.opacity(0.08)).frame(width: 112, height: 112)
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 92, height: 92)
                }
                .onAppear { withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true } }
                PageTitle(eyebrow: "Welcome", title: "Install DNS Redirect",
                          subtitle: "Point any domain to an IP address or another site, with a local web redirect for browsers and a live DNS alias resolver.")
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("bolt.horizontal.circle", "Local redirects", "Map domains to IPs or other domains in a clearly marked section of /etc/hosts. Other entries are never touched.")
                feature("arrow.uturn.right.circle", "Browser redirects", "Send http and https visits for a domain to another site, served by DNS Redirect on this Mac only.")
                feature("lock.shield", "Least privilege", "The installer needs no password. The app asks for one only when it changes DNS settings.")
                feature("trash.slash", "Clean uninstall", "Run this installer again to remove the app and every DNS change it made.")
            }
            .glowPanel(padding: 18)
            if let existing = model.check?.existingInstall {
                Banner(kind: .info, message: "DNS Redirect \(model.check?.existingVersion ?? "") is already installed at \(existing.path). Continue to update it. Your rules are kept.")
            }
        }
        .padding(30)
        .task { if model.check == nil { model.check = SystemCheck.run(payload: model.payload) } }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.accentGradient).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct CheckPage: View {
    @Environment(InstallerModel.self) private var model

    private var subtitle: String {
        guard !model.checking, let check = model.check else {
            return "Checking this Mac before anything is installed. Nothing has been changed yet."
        }
        return check.canInstall
            ? "This Mac is ready. DNS Redirect will run natively on \(check.architecture.title)."
            : "DNS Redirect can't be installed on this Mac. See the items marked in red."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(eyebrow: "Step 1 · Compatibility", title: "System Check", subtitle: subtitle)
            VStack(spacing: 0) {
                let items = model.check?.items ?? []
                ForEach(Array(items.prefix(model.revealedChecks).enumerated()), id: \.element.id) { index, item in
                    CheckRow(item: item)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    if index < min(model.revealedChecks, items.count) - 1 { Divider().overlay(Theme.stroke) }
                }
                if model.checking {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").font(Theme.mono(12)).foregroundStyle(Theme.cyan)
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .glowPanel(glow: model.checking, padding: 4)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .task { if !model.snapshotMode { await model.runCheck() } }
    }
}

struct CheckRow: View {
    let item: CheckItem

    private var color: Color {
        switch item.level {
        case .pass: return Theme.green
        case .warning: return Theme.amber
        case .fail: return Theme.red
        case .info: return Theme.cyan
        }
    }

    private var glyph: String {
        switch item.level {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.symbol).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(item.detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    .help(item.detail)
            }
            Spacer(minLength: 8)
            Image(systemName: glyph).foregroundStyle(color).shadow(color: color.opacity(0.6), radius: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct OptionsPage: View {
    @Environment(InstallerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(eyebrow: "Step 2 · Setup", title: "First-Launch Setup",
                      subtitle: "Choose how DNS Redirect starts. You can change all of this later in its Settings.")
            VStack(spacing: 14) {
                option("Open at login", "Start DNS Redirect when you log in so redirects that need it (web redirects, live aliases) keep working.",
                       $model.options.launchAtLogin)
                Divider().overlay(Theme.stroke)
                option("Show in menu bar", "Quick access to profiles, pause and status from the menu bar.", $model.options.showMenuBarExtra)
                Divider().overlay(Theme.stroke)
                option("Apply changes automatically", "Push rule edits to the system right away. You'll be asked for an administrator password when needed.",
                       $model.options.autoApply)
                Divider().overlay(Theme.stroke)
                option("Re-apply rules at launch", "Repair the managed /etc/hosts section if something changed it while the app was closed.",
                       $model.options.applyAtLaunch)
            }
            .glowPanel(padding: 18)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.cyan)
                Text("Install location").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(model.check?.installDirectory.appendingPathComponent(Payload.appName).path ?? "/Applications")
                    .font(Theme.mono(12)).foregroundStyle(Theme.text)
            }
            InfoNote(text: "Installing doesn't need an administrator password and makes no DNS changes. DNS Redirect asks for permission the first time you apply a rule.",
                     symbol: "lock.shield")
        }
        .padding(30)
    }

    private func option(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(NeonToggleStyle())
        .accessibilityLabel(title)
    }
}

struct ProgressPage: View {
    @Environment(InstallerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(eyebrow: model.mode == .install ? "Step 3 · Install" : "Uninstall",
                      title: model.mode == .install ? "Installing DNS Redirect" : "Removing DNS Redirect",
                      subtitle: model.failure != nil ? "Stopped. See the details below."
                        : (model.finished ? "All done." : "This takes a few seconds."))
            HStack(alignment: .top, spacing: 28) {
                ProgressRing(fraction: model.fractionComplete, failed: model.failure != nil, active: model.running)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(model.steps) { step in StepRow(step: step) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glowPanel(glow: model.running, padding: 20)
            if let failure = model.failure {
                Banner(kind: .error, message: failure)
            }
        }
        .padding(30)
    }
}

struct ProgressRing: View {
    let fraction: Double
    let failed: Bool
    let active: Bool
    @State private var sweep = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.panelRaised, lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(failed ? AnyShapeStyle(Theme.red) : AnyShapeStyle(AngularGradient(colors: [Theme.blue, Theme.cyan, Theme.blue], center: .center)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: (failed ? Theme.red : Theme.cyan).opacity(0.6), radius: 8)
                .animation(.easeInOut(duration: 0.4), value: fraction)
            if active {
                Circle()
                    .trim(from: 0, to: 0.08)
                    .stroke(Theme.cyan.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(-10)
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { sweep = true } }
            }
            VStack(spacing: 2) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(failed ? Theme.red : Theme.text)
                    .contentTransition(.numericText())
                    .animation(.easeOut, value: fraction)
                Text(failed ? "FAILED" : (fraction >= 1 ? "COMPLETE" : "WORKING"))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(2)
                    .foregroundStyle(failed ? Theme.red : Theme.cyan)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress \(Int(fraction * 100)) percent")
    }
}

struct StepRow: View {
    let step: StepState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                switch step.status {
                case .pending: Circle().strokeBorder(Theme.strokeStrong, lineWidth: 1.5)
                case .running: ProgressView().controlSize(.small).scaleEffect(0.8)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).shadow(color: Theme.green.opacity(0.6), radius: 4)
                case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(Theme.textTertiary)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 12.5, weight: step.status == .running ? .semibold : .regular))
                    .foregroundStyle(step.status == .pending ? Theme.textTertiary : Theme.text)
                if !step.detail.isEmpty {
                    Text(step.detail).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct DonePage: View {
    @Environment(InstallerModel.self) private var model
    @State private var appear = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Theme.green.opacity(0.08)).frame(width: 150, height: 150).scaleEffect(appear ? 1 : 0.5)
                Circle().strokeBorder(Theme.green.opacity(0.5), lineWidth: 1.5).frame(width: 118, height: 118)
                    .shadow(color: Theme.green.opacity(0.7), radius: appear ? 14 : 0)
                Image(systemName: model.mode == .install ? "checkmark" : "trash")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(Theme.green)
                    .scaleEffect(appear ? 1 : 0.3)
            }
            .opacity(appear ? 1 : 0)
            Text(model.mode == .install ? "DNS Redirect is installed" : "DNS Redirect was removed")
                .font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
            Text(model.mode == .install
                 ? "It's in \(model.check?.installDirectory.path ?? "/Applications") and ready to go. Add your first redirect, and macOS will ask for your password the first time a rule is applied."
                 : (model.removeUserData
                    ? "The app, its DNS changes, HTTPS certificate, login item, rules and settings were removed. Other /etc/hosts entries were left as they were."
                    : "The app, its DNS changes, HTTPS certificate and login item were removed. Your rules are kept (paused) in Application Support in case you reinstall."))
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let failure = model.failure { Banner(kind: .error, message: failure).frame(maxWidth: 460) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.6).delay(0.1)) { appear = true } }
    }
}

struct UninstallSheet: View {
    @Environment(InstallerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(Theme.red)
                Text("Uninstall DNS Redirect").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            }
            Text("This will remove:").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                bullet("The DNS Redirect section of /etc/hosts and its /etc/resolver files (needs your administrator password)")
                bullet("The “DNS Redirect Local CA” HTTPS certificate and its keys, if created")
                bullet("The login item, and DNS Redirect.app (moved to the Trash)")
            }
            Toggle(isOn: $model.removeUserData) {
                Text("Also delete my rules, profiles and activity log").font(.system(size: 12.5)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.checkbox)
            InfoNote(text: "Hosts entries that DNS Redirect didn't create, and all other system settings, are left exactly as they are.")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(NeonButtonStyle(kind: .ghost)).keyboardShortcut(.cancelAction)
                Button("Uninstall") {
                    dismiss()
                    Task { await model.startUninstall() }
                }
                .buttonStyle(NeonButtonStyle(kind: .destructive))
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.background)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.cyan).frame(width: 5, height: 5).padding(.top, 6)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text)
        }
    }
}
