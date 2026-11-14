import AppKit
import SwiftUI

/// Cyberpunk-minimal palette. Every color adapts so the optional "Match System" appearance works.
enum Theme {
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let background = adaptive(dark: rgb(0.031, 0.035, 0.047), light: rgb(0.945, 0.953, 0.965))
    static let sidebar = adaptive(dark: rgb(0.043, 0.048, 0.062), light: rgb(0.925, 0.933, 0.947))
    static let panel = adaptive(dark: rgb(0.067, 0.075, 0.094), light: rgb(1, 1, 1))
    static let panelRaised = adaptive(dark: rgb(0.094, 0.105, 0.13), light: rgb(0.965, 0.97, 0.98))
    static let stroke = adaptive(dark: rgb(1, 1, 1, 0.07), light: rgb(0, 0, 0, 0.08))
    static let strokeStrong = adaptive(dark: rgb(1, 1, 1, 0.13), light: rgb(0, 0, 0, 0.14))

    static let cyan = adaptive(dark: rgb(0.0, 0.9, 1.0), light: rgb(0.0, 0.52, 0.68))
    static let blue = adaptive(dark: rgb(0.2, 0.5, 1.0), light: rgb(0.1, 0.36, 0.9))
    static let green = adaptive(dark: rgb(0.22, 0.95, 0.62), light: rgb(0.05, 0.6, 0.35))
    static let amber = adaptive(dark: rgb(1.0, 0.76, 0.24), light: rgb(0.78, 0.5, 0.0))
    static let red = adaptive(dark: rgb(1.0, 0.36, 0.42), light: rgb(0.82, 0.16, 0.24))
    static let violet = adaptive(dark: rgb(0.66, 0.5, 1.0), light: rgb(0.45, 0.3, 0.85))

    static let text = adaptive(dark: rgb(0.93, 0.95, 0.98), light: rgb(0.07, 0.08, 0.1))
    static let textSecondary = adaptive(dark: rgb(0.62, 0.66, 0.74), light: rgb(0.36, 0.39, 0.45))
    static let textTertiary = adaptive(dark: rgb(0.4, 0.43, 0.5), light: rgb(0.55, 0.58, 0.63))

    static let accentGradient = LinearGradient(colors: [blue, cyan], startPoint: .leading, endPoint: .trailing)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let corner: CGFloat = 14
}

// MARK: - Panels

struct GlowPanel: ViewModifier {
    var glow = false
    var padding: CGFloat = 16
    var tint: Color = Theme.cyan

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [tint.opacity(glow ? 0.55 : 0.18), Theme.stroke, Theme.stroke],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            // Only attach a shadow when it's visible: a shadow on a container is re-rendered
            // whenever anything inside it changes, which is expensive for large panels.
            .modifier(OptionalGlow(color: tint, active: glow))
    }
}

private struct OptionalGlow: ViewModifier {
    let color: Color
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.shadow(color: color.opacity(0.22), radius: 14)
        } else {
            content
        }
    }
}

extension View {
    func glowPanel(glow: Bool = false, padding: CGFloat = 16, tint: Color = Theme.cyan) -> some View {
        modifier(GlowPanel(glow: glow, padding: padding, tint: tint))
    }
}

// MARK: - Buttons

struct NeonButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, ghost }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        NeonButton(configuration: configuration, kind: kind, compact: compact)
    }

    private struct NeonButton: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 9 : 14)
                .padding(.vertical, compact ? 5 : 8)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: glowColor.opacity(hovering && isEnabled ? 0.5 : (kind == .primary ? 0.28 : 0)), radius: hovering ? 12 : 8)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }

        private var glowColor: Color { kind == .destructive ? Theme.red : Theme.cyan }

        private var foreground: Color {
            switch kind {
            case .primary: return Color.black.opacity(0.88)
            case .destructive: return Theme.red
            case .secondary, .ghost: return hovering ? Theme.cyan : Theme.text
            }
        }

        @ViewBuilder private var background: some View {
            switch kind {
            case .primary: Theme.accentGradient.brightness(hovering ? 0.08 : 0)
            case .secondary: Theme.panelRaised
            case .destructive: Theme.red.opacity(hovering ? 0.16 : 0.09)
            case .ghost: Color.clear
            }
        }

        private var border: Color {
            switch kind {
            case .primary: return Color.white.opacity(0.25)
            case .secondary: return hovering ? Theme.cyan.opacity(0.6) : Theme.strokeStrong
            case .destructive: return Theme.red.opacity(0.45)
            case .ghost: return hovering ? Theme.strokeStrong : .clear
            }
        }
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var tint: Color = Theme.textSecondary
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Theme.cyan : tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Theme.cyan.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Toggle

struct NeonToggleStyle: ToggleStyle {
    var size: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelRaised))
                    .overlay(Capsule().strokeBorder(configuration.isOn ? Color.white.opacity(0.2) : Theme.strokeStrong, lineWidth: 1))
                    .frame(width: 34 * size, height: 19 * size)
                    .shadow(color: Theme.cyan.opacity(configuration.isOn ? 0.45 : 0), radius: 6)
                Circle()
                    .fill(configuration.isOn ? Color.white : Theme.textSecondary)
                    .frame(width: 14 * size, height: 14 * size)
                    .padding(2.5 * size)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

struct Tag: View {
    let text: String
    var color: Color = Theme.blue

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - Misc

struct SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.cyan)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? Theme.cyan : Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.mono(12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Theme.cyan.opacity(0.6) : Theme.stroke, lineWidth: 1))
        .shadow(color: Theme.cyan.opacity(focused ? 0.2 : 0), radius: 8)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct NeonTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = true
    var invalid = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(13) : .system(size: 13))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(borderColor, lineWidth: 1))
            .shadow(color: (invalid ? Theme.red : Theme.cyan).opacity(focused ? 0.18 : 0), radius: 8)
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    private var borderColor: Color {
        if invalid { return Theme.red.opacity(0.7) }
        return focused ? Theme.cyan.opacity(0.6) : Theme.stroke
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = Theme.cyan
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.12)))
                .shadow(color: tint.opacity(0.35), radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .glowPanel(padding: 12, tint: tint)
        .help(detail.map { "\(title): \(value). \($0)" } ?? "\(title): \(value)")
    }
}

struct Banner: View {
    enum Kind { case info, warning, error, working }
    let kind: Kind
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if kind == .working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(NeonButtonStyle(kind: .secondary, compact: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11).fill(color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    private var color: Color {
        switch kind {
        case .info, .working: return Theme.cyan
        case .warning: return Theme.amber
        case .error: return Theme.red
        }
    }

    private var symbol: String {
        switch kind {
        case .info, .working: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct InfoNote: View {
    let text: String
    var symbol = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.cyan.opacity(0.8))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}
