import SwiftUI

struct SessionsWindowView: View {
    @ObservedObject var coordinator: RogersCoordinator
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Compact status bar
            if coordinator.isCompacting {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(coordinator.compactStatus)
                        .font(.caption)
                        .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
            }

            // Session list
            if coordinator.sessions.isEmpty {
                Spacer()
                Text("No tracked sessions")
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(coordinator.sessions) { session in
                        HStack(spacing: 8) {
                            // Active indicator
                            Circle()
                                .fill(session.isActive ? .green : .clear)
                                .frame(width: 6, height: 6)

                            // Title
                            Text(session.threadTitle)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // Turn count
                            Text("\(session.turnCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()

                            // Compact button
                            Button {
                                Task {
                                    await coordinator.compact(sessionId: session.id)
                                }
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .disabled(coordinator.isCompacting)
                            .help("Compact: summarize and start new thread")

                            // Delete button
                            Button {
                                coordinator.deleteSession(id: session.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete session data")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Footer
            Divider()
            HStack {
                Button("Delete All") {
                    showDeleteAllConfirmation = true
                }
                .foregroundColor(.red)
                .disabled(coordinator.sessions.isEmpty)

                Spacer()

                Text("\(coordinator.sessions.count) sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 400, idealWidth: 500, minHeight: 250, idealHeight: 400)
        .alert("Delete All Sessions?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                coordinator.deleteAllSessions()
            }
        } message: {
            Text("This will permanently delete all tracked session data from Rogers. ChatGPT conversations are not affected.")
        }
    }
}
