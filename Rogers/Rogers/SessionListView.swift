import SwiftUI

struct SessionListView: View {
    @ObservedObject var coordinator: RogersCoordinator
    @Environment(\.openWindow) var openWindow

    private let intervalOptions: [Double] = [5, 10, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rogers")
                .font(.headline)

            HStack {
                Text("Polling: every")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $coordinator.pollIntervalSeconds) {
                    ForEach(intervalOptions, id: \.self) { val in
                        Text("\(Int(val))s").tag(val)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 60)
                .onChange(of: coordinator.pollIntervalSeconds) { _, newValue in
                    coordinator.updatePollInterval(newValue)
                }
            }

            if !coordinator.axPermissionGranted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility permission required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Button("Open Settings") {
                            coordinator.openAccessibilitySettings()
                        }
                        .font(.caption2)
                        Button("Retry") {
                            coordinator.retryAccessibility()
                        }
                        .font(.caption2)
                    }
                }
            } else if !coordinator.statusMessage.isEmpty {
                Text(coordinator.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button("View Sessions") {
                openWindow(id: "sessions")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 200)
    }
}
