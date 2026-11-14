#if DEBUG
import AppKit
import SwiftUI

/// `--render-pages <dir>`: writes a PNG of every wizard page (Debug builds only), for visual checks.
@MainActor
enum PageSnapshots {
    static func run(to directory: URL) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = InstallerModel()
        model.snapshotMode = true
        model.check = SystemCheck.run(payload: model.payload)
        model.revealedChecks = model.check?.items.count ?? 0
        func shot(_ name: String) {
            let view = WizardView().environment(model).frame(width: 820, height: 600).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        model.page = .welcome; shot("1-welcome")
        model.page = .check; shot("2-check")
        model.page = .options; shot("3-options")
        model.page = .install
        model.steps = InstallerEngine.installSteps
        for i in 0..<3 { model.steps[i].status = .done; model.steps[i].detail = i == 2 ? "/Applications/DNS Redirect.app" : "ok" }
        model.steps[3].status = .running
        model.running = true
        shot("4-progress")
        model.running = false
        model.failure = "Administrator permission is needed to remove DNS Redirect's entries from /etc/hosts. Nothing was uninstalled."
        model.steps[3].status = .failed
        shot("5-failure")
        model.failure = nil
        model.page = .done; shot("6-done")
        model.mode = .uninstall; model.page = .done; shot("7-uninstalled")
        print("rendered to \(directory.path)")
    }
}
#endif
