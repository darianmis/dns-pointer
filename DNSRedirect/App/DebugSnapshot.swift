#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `-DNSRedirectSnapshotPath /path/prefix` writes PNGs of the app's own windows
/// after launch (no Screen Recording permission needed, since it renders in-process).
/// Optional `-DNSRedirectSnapshotPage rules|lookup|activity|system` is consumed by RootView.
enum DebugSnapshot {
    static var page: String? { UserDefaults.standard.string(forKey: "DNSRedirectSnapshotPage") }

    @MainActor
    static func scheduleIfRequested() {
        guard let prefix = UserDefaults.standard.string(forKey: "DNSRedirectSnapshotPath") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            // Off-screen renders of each page (ImageRenderer works without any permissions).
            let model = AppModel.shared
            let pages: [(String, AnyView)] = [
                ("dashboard", AnyView(DashboardView(profileID: nil))),
                ("system", AnyView(SystemView())),
                ("activity", AnyView(ActivityLogView())),
                ("editor", AnyView(RuleEditorSheet(request: .add(profileID: nil)))),
                ("rows", AnyView(VStack(spacing: 0) {
                    TableHeader()
                    ForEach(model.configuration.profiles.flatMap { p in p.rules.map { (p, $0) } }, id: \.1.id) { pair in
                        RuleRow(row: RuleRowModel(rule: pair.1, profile: pair.0, status: model.status(for: pair.1)),
                                showProfile: true, selected: false, onSelect: { _ in }, onDelete: {})
                    }
                    Spacer()
                }.glowPanel(padding: 0).padding(24))),
            ]
            for (name, page) in pages {
                let renderer = ImageRenderer(content: page
                    .environment(model)
                    .environment(\.colorScheme, .dark)
                    .frame(width: name == "editor" ? 580 : 1180, height: name == "editor" ? 640 : 1300)
                    .background(Theme.background))
                renderer.scale = 2
                var cg: CGImage?
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { cg = renderer.cgImage }
                if let image = cg,
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
                }
            }
            var dump = ""
            func walk(_ element: Any, depth: Int) {
                guard depth < 40, let e = element as? NSAccessibilityElementProtocol & NSObjectProtocol else { return }
                let o = e as AnyObject
                let role = (o.accessibilityRole?() ?? nil)?.rawValue ?? "?"
                let label = (o.accessibilityLabel?() ?? nil) ?? ""
                let value = (o.accessibilityValue?() ?? nil).map { "\($0)" } ?? ""
                let frame = e.accessibilityFrame()
                dump += String(repeating: "  ", count: depth) + "\(role) [\(label)] [\(value.prefix(40))] \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\n"
                for child in (o.accessibilityChildren?() ?? nil) ?? [] { walk(child, depth: depth + 1) }
            }
            for window in NSApp.windows where window.isVisible {
                dump += "WINDOW \(window.title) \(window.frame) appearance=\(window.effectiveAppearance.name.rawValue)\n"
                if let v = window.contentView { walk(v, depth: 1) }
            }
            func views(_ v: NSView, _ d: Int) {
                guard d < 30 else { return }
                if let t = v as? NSTableView { dump += String(repeating: "  ", count: d) + "TABLE rows=\(t.numberOfRows)\n" }
                dump += String(repeating: "  ", count: d) + "\(type(of: v)) \(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height)) hidden=\(v.isHidden) alpha=\(v.alphaValue)\n"
                for c in v.subviews { views(c, d + 1) }
            }
            for window in NSApp.windows where window.isVisible {
                dump += "VIEWS \(window.title)\n"
                if let v = window.contentView?.superview { views(v, 1) }
            }
            try? dump.write(toFile: "\(prefix)-ax.txt", atomically: true, encoding: .utf8)
            for (i, window) in NSApp.windows.enumerated() where window.isVisible && window.contentView != nil {
                guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { continue }
                let scale = window.backingScaleFactor
                let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
                guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                guard let image = ctx.makeImage() else { continue }
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                }
            }
        }
    }
}
#endif
