import SwiftUI

struct DecisionsView: View {
    @EnvironmentObject var coordinator: TeamsCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Decisions")
                    .font(.headline)
                Spacer()
                Button("Copy") { copyDecisions() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Clear") {
                    coordinator.resetSession()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("Export .md") { exportDecisions() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content
            ScrollView {
                if coordinator.decisionsText.isEmpty {
                    Text("No decisions yet.\n\nDecisions are recorded when ≥2 participants agree or the user confirms.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    Text(coordinator.decisionsText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func copyDecisions() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(coordinator.decisionsText, forType: .string)
    }

    private func exportDecisions() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "buck-teams-decisions.md"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            try? coordinator.decisionsText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
