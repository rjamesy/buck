import SwiftUI

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            Image(systemName: iconForRole)
                .font(.system(size: 14))
                .foregroundColor(colorForRole)
                .frame(width: 24, height: 24)
                .background(colorForRole.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                // Role label
                Text(labelForRole)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(colorForRole)

                // Content
                Text(message.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                // Token info
                if let info = message.tokenInfo {
                    Text(info)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(10)
        .background(backgroundForRole)
        .cornerRadius(8)
    }

    private var iconForRole: String {
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "terminal"
        case .system: return "gearshape"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var labelForRole: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Codex"
        case .system: return "System"
        case .error: return "Error"
        }
    }

    private var colorForRole: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .green
        case .system: return .gray
        case .error: return .red
        }
    }

    private var backgroundForRole: Color {
        switch message.role {
        case .user: return Color.blue.opacity(0.06)
        case .assistant: return Color.green.opacity(0.06)
        case .system: return Color.gray.opacity(0.06)
        case .error: return Color.red.opacity(0.08)
        }
    }
}
