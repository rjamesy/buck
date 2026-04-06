import SwiftUI

struct ChatView: View {
    @EnvironmentObject var coordinator: TeamsCoordinator
    @State private var userInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Chat header (compact)
            HStack {
                Text("Chat")
                    .font(.headline)
                Spacer()
                Button("Copy All") { copyChat() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Clear") { coordinator.resetSession() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Export .md") { exportChat() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: coordinator.messages.count) {
                    if let last = coordinator.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if userInput.isEmpty {
                        Text("Type a message (USER: priority)...")
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $userInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 90)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }

                VStack(spacing: 4) {
                    Button("Send") { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(userInput.isEmpty || !coordinator.sessionActive)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    private func send() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        coordinator.sendUserMessage(text)
        userInput = ""
    }

    private func copyChat() {
        let text = coordinator.messages.map { msg in
            "\(msg.from.displayName): \(msg.content)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportChat() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "buck-teams-chat.md"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let text = "# Buck Teams Chat Export\n\n" + coordinator.messages.map { msg in
                "**\(msg.from.displayName)** (\(msg.timestamp)):\n\(msg.content)\n"
            }.joined(separator: "\n---\n\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubbleView: View {
    let message: TeamMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Sender indicator
            Circle()
                .fill(colorForParticipant(message.from))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(message.from.displayName)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(colorForParticipant(message.from))

                    if message.to != "all" {
                        Text("→ \(message.to)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if message.type == .decision {
                        Text("DECISION")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Color.yellow.opacity(0.3))
                            .cornerRadius(3)
                    }

                    if message.priority == .high {
                        Text("!")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                }

                Text(message.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundForMessage())
        .cornerRadius(6)
    }

    private func colorForParticipant(_ name: Participant.Name) -> Color {
        switch name {
        case .user: return .blue
        case .claude: return .orange
        case .codex: return .green
        case .gpt: return .purple
        }
    }

    private func backgroundForMessage() -> Color {
        if message.type == .system {
            return Color.gray.opacity(0.1)
        }
        return colorForParticipant(message.from).opacity(0.08)
    }
}
