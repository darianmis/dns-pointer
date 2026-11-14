import SwiftUI

// MARK: - Status badge

extension RuleStatus {
    var color: Color {
        switch self {
        case .active(let note): return note == nil ? Theme.green : Theme.amber
        case .pending, .evaluating: return Theme.amber
        case .disabled: return Theme.textTertiary
        case .inactive: return Theme.violet
        case .error: return Theme.red
        }
    }
}

struct StatusBadge: View {
    let status: RuleStatus

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                // Static halo for active rules. No looping animation, so an idle app stays at ~0% CPU.
                if status.isActive {
                    Circle()
                        .fill(status.color.opacity(0.3))
                        .frame(width: 13, height: 13)
                }
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 13, height: 13)
            Text(status.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status.color)
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(status.color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(status.color.opacity(0.3), lineWidth: 1))
        .help(status.detail ?? status.label)
    }
}

