import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // New Thread button
            Button(action: { appState.newThread() }) {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("New Thread")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(12)

            Divider()

            // Thread list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.threads.enumerated()), id: \.element.id) { index, thread in
                        ThreadRow(
                            thread: thread,
                            isActive: appState.activeThreadIndex == index,
                            onSelect: { appState.activeThreadIndex = index }
                        )
                    }
                }
                .padding(8)
            }

            Divider()

            // Settings
            VStack(alignment: .leading, spacing: 8) {
                // API key status
                HStack(spacing: 4) {
                    Image(systemName: appState.settings.hasAPIKey ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(appState.settings.hasAPIKey ? .green : .red)
                        .font(.caption)
                    Text(appState.settings.hasAPIKey ? "API Key Set" : "No API Key")
                        .font(.caption)
                }

                // Model
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(appState.settings.model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Repo
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(URL(fileURLWithPath: appState.settings.repoPath).lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ThreadRow: View {
    let thread: ChatThread
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: "bubble.left")
                    .font(.caption)
                    .foregroundColor(isActive ? .white : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.caption)
                        .fontWeight(isActive ? .semibold : .regular)
                        .foregroundColor(isActive ? .white : .primary)
                        .lineLimit(1)

                    Text("\(thread.messages.count) messages")
                        .font(.caption2)
                        .foregroundColor(isActive ? .white.opacity(0.7) : .secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
