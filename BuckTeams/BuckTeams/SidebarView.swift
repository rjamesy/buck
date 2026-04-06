import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var coordinator: TeamsCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Participants
            ParticipantsPanel()

            Divider()

            // Row 2: Debug
            DebugPanelView()

            Divider()

            // Row 3: System Prompt
            SystemPromptView()

            Spacer()

            Divider()

            // Row 4: Controls
            ControlsView()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Participants Panel

struct ParticipantsPanel: View {
    @EnvironmentObject var coordinator: TeamsCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 2)

            ForEach(coordinator.participants) { participant in
                ParticipantCardView(
                    participant: participant,
                    isEnabled: coordinator.participantEnabled[participant.name] ?? true,
                    onToggle: { enabled in
                        coordinator.participantEnabled[participant.name] = enabled
                    }
                )
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Participant Card

struct ParticipantCardView: View {
    let participant: Participant
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colorForMode(participant.mode))
                .frame(width: 10, height: 10)

            Text(participant.name.displayName)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(participant.online ? .primary : .secondary)

            Spacer()

            if participant.mode != .silent && participant.online {
                Text(participant.mode.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .scaleEffect(0.7)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func colorForMode(_ mode: Participant.Mode) -> Color {
        switch mode {
        case .idle: return .green
        case .participating: return .yellow
        case .thinking: return .orange
        case .sending: return .blue
        case .waiting: return .purple
        case .reading: return .red
        case .silent: return .gray
        }
    }
}

// MARK: - Debug Panel

struct DebugPanelView: View {
    @EnvironmentObject var coordinator: TeamsCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Seq: \(coordinator.debugInfo.currentSeq)")
            Text("GPT latency: \(String(format: "%.1fs", coordinator.debugInfo.lastGPTLatency))")
            ForEach(Array(coordinator.debugInfo.messageCounts.sorted(by: { $0.key < $1.key })), id: \.key) { name, count in
                Text("\(name): \(count) msgs")
            }
            if let lastError = coordinator.debugInfo.errors.last {
                Text(lastError)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - System Prompt

struct SystemPromptView: View {
    @EnvironmentObject var coordinator: TeamsCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("System Prompt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Load") { loadPrompt() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                Button("Save") { savePrompt() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            .padding(.horizontal, 12)

            TextEditor(text: $coordinator.systemPrompt)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 150)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
    }

    private func loadPrompt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                coordinator.systemPrompt = text
            }
        }
    }

    private func savePrompt() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "system-prompt.txt"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            try? coordinator.systemPrompt.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Controls

struct ControlsView: View {
    @EnvironmentObject var coordinator: TeamsCoordinator

    var body: some View {
        VStack(spacing: 6) {
            if !coordinator.sessionActive {
                Button("Start Session") {
                    coordinator.startSession()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Stop Session") {
                    coordinator.stopSession()
                }
                .buttonStyle(.bordered)
            }

            Button("Reset") {
                coordinator.resetSession()
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
        .padding(12)
    }
}
