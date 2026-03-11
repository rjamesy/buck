import SwiftUI
import ApplicationServices

@main
struct BuckApp: App {
    @StateObject private var coordinator = BuckCoordinator()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("Buck")
                    .font(.headline)
                Divider()
                Text(coordinator.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let lastRound = coordinator.lastRoundInfo {
                    Text(lastRound)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                Button("Open Inbox") {
                    NSWorkspace.shared.open(FileWatcher.inboxURL)
                }
                Button("Open Outbox") {
                    NSWorkspace.shared.open(ResponseWriter.outboxURL)
                }

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
            .frame(width: 220)
        } label: {
            Image(systemName: coordinator.menuBarIcon)
        }
    }
}
