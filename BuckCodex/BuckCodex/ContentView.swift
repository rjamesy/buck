import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HSplitView {
            // Sidebar
            SidebarView()
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            // Main chat area
            VStack(spacing: 0) {
                // Toolbar
                ToolbarView()

                Divider()

                // Messages
                ChatArea()

                Divider()

                // Input
                InputBar()
            }
        }
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            Text("Buck Codex")
                .font(.headline)

            Spacer()

            // Model picker
            Picker("Model", selection: $appState.settings.model) {
                Text("gpt-5.4").tag("gpt-5.4")
                Text("gpt-5.4-mini").tag("gpt-5.4-mini")
                Text("o3").tag("o3")
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            // Stop button
            if appState.runner.isRunning {
                Button(action: { appState.cancelRun() }) {
                    Image(systemName: "stop.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)

                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }

            // Token info
            if !appState.runner.currentOutput.isEmpty {
                Text(appState.runner.currentOutput)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Chat Area

struct ChatArea: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let thread = appState.activeThread {
                        ForEach(thread.messages) { message in
                            MessageView(message: message)
                                .id(message.id)
                        }
                    } else {
                        VStack(spacing: 8) {
                            Spacer(minLength: 100)
                            Image(systemName: "terminal")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("Buck Codex")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Type a prompt to start. Uses API key billing.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Streaming indicator
                    if appState.runner.isRunning && !appState.runner.streamingText.isEmpty {
                        MessageView(message: ChatMessage(
                            role: .assistant,
                            content: appState.runner.streamingText + " ...",
                            timestamp: Date()
                        ))
                        .opacity(0.7)
                        .id("streaming")
                    }
                }
                .padding(16)
            }
            .onChange(of: appState.activeThread?.messages.count) {
                if let last = appState.activeThread?.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Input Bar

struct InputBar: View {
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""

    var body: some View {
        HStack(spacing: 8) {
            // Repo indicator
            Button(action: pickRepo) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(repoName)
                        .lineLimit(1)
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)

            TextField("Type a prompt...", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { send() }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(inputText.isEmpty || appState.runner.isRunning || !appState.settings.hasAPIKey)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var repoName: String {
        let path = appState.settings.repoPath
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.sendMessage(text)
        inputText = ""
    }

    private func pickRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url {
                appState.settings.repoPath = url.path
            }
        }
    }
}
