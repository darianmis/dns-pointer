import AppKit
import DNSRedirectCore
import Observation
import SwiftUI

enum WizardPage: Int, CaseIterable, Comparable {
    case welcome, check, options, install, done

    static func < (a: WizardPage, b: WizardPage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .check: return "System Check"
        case .options: return "Setup"
        case .install: return "Install"
        case .done: return "Finish"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "sparkles"
        case .check: return "checklist"
        case .options: return "slider.horizontal.3"
        case .install: return "arrow.down.app"
        case .done: return "checkmark.seal"
        }
    }
}

enum WizardMode: Equatable { case install, uninstall }

@MainActor
@Observable
final class InstallerModel {
    var page: WizardPage = .welcome
    var mode: WizardMode = .install
    var check: SystemCheck?
    var checking = false
    var revealedChecks = 0
    var options = InstallOptions()
    var removeUserData = false
    var steps: [StepState] = []
    var running = false
    var failure: String?
    var finished = false
    /// Set by Debug page snapshots so pages show fixed state.
    var snapshotMode = false

    let payload = Payload.embedded()

    var fractionComplete: Double {
        guard !steps.isEmpty else { return 0 }
        let done = steps.filter { $0.status == .done || $0.status == .skipped }.count
        let running = steps.contains { $0.status == .running } ? 0.5 : 0
        return min(1, (Double(done) + running) / Double(steps.count))
    }

    var installedAppURL: URL? {
        guard let check else { return nil }
        return check.installDirectory.appendingPathComponent(Payload.appName)
    }

    func runCheck() async {
        checking = true
        revealedChecks = 0
        let result = SystemCheck.run(payload: payload)
        check = result
        // Reveal results one by one for a scanning effect.
        for i in 1...max(result.items.count, 1) {
            try? await Task.sleep(for: .milliseconds(170))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { revealedChecks = i }
        }
        checking = false
    }

    func go(_ page: WizardPage) {
        withAnimation(.easeInOut(duration: 0.3)) { self.page = page }
    }

    func startInstall() async {
        guard let check else { return }
        mode = .install
        await run(steps: InstallerEngine.installSteps, directory: check.installDirectory) { engine in
            try await engine.install(options: self.options)
        }
    }

    func startUninstall() async {
        let check = self.check ?? SystemCheck.run(payload: payload)
        self.check = check
        mode = .uninstall
        let locations = Array(Set([check.installDirectory.appendingPathComponent(Payload.appName)] + (check.existingInstall.map { [$0] } ?? [])))
        await run(steps: InstallerEngine.uninstallSteps, directory: check.installDirectory) { engine in
            _ = try await engine.uninstall(removeUserData: self.removeUserData, appLocations: locations)
        }
    }

    private func run(steps: [StepState], directory: URL, _ work: (InstallerEngine) async throws -> Void) async {
        self.steps = steps
        failure = nil
        finished = false
        running = true
        go(.install)
        let engine = InstallerEngine(payload: payload, installDirectory: directory)
        engine.progress = { [weak self] id, status, detail in
            guard let self, let i = self.steps.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.steps[i].status = status
                if !detail.isEmpty { self.steps[i].detail = detail }
            }
        }
        do {
            try await work(engine)
            finished = true
            try? await Task.sleep(for: .milliseconds(500))
            running = false
            go(.done)
        } catch {
            running = false
            withAnimation { failure = error.localizedDescription }
            for i in self.steps.indices where self.steps[i].status == .running { self.steps[i].status = .failed }
        }
    }

    func launchApp() {
        guard let url = installedAppURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    self.failure = "Could not open DNS Redirect: \(error.localizedDescription)"
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func revealInstalledApp() {
        guard let url = installedAppURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
