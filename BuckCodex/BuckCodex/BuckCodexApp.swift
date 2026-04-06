import SwiftUI

@main
struct BuckCodexApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 650)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: CodexSettings = .default
    @Published var threads: [ChatThread] = []
    @Published var activeThreadIndex: Int? = nil
    @Published var runner = OpenAIRunner()

    var activeThread: ChatThread? {
        guard let idx = activeThreadIndex, idx < threads.count else { return nil }
        return threads[idx]
    }

    func newThread() {
        let thread = ChatThread()
        threads.append(thread)
        activeThreadIndex = threads.count - 1
    }

    func sendMessage(_ text: String) {
        guard !text.isEmpty, !runner.isRunning else { return }

        // Create thread if needed
        if activeThreadIndex == nil {
            newThread()
        }

        guard let idx = activeThreadIndex else { return }

        // Set thread title from first prompt
        if threads[idx].messages.isEmpty {
            threads[idx].title = String(text.prefix(40))
        }

        // Add user message
        let userMsg = ChatMessage(role: .user, content: text, timestamp: Date())
        threads[idx].messages.append(userMsg)

        let messageHandler: (ChatMessage) -> Void = { [weak self] message in
            Task { @MainActor in
                guard let self, let idx = self.activeThreadIndex else { return }
                self.threads[idx].messages.append(message)
            }
        }

        // Smoke test on first send, then run
        if !runner.smokeTestPassed {
            Task {
                let (ok, msg) = await runner.smokeTest(settings: settings)
                if !ok {
                    messageHandler(ChatMessage(role: .error, content: "Smoke test failed: \(msg)", timestamp: Date()))
                    return
                }
                messageHandler(ChatMessage(role: .system, content: "API connected. Smoke: \(msg)", timestamp: Date()))
                runner.run(prompt: text, settings: settings, onMessage: messageHandler)
            }
        } else {
            // Run via OpenAI API
            runner.run(prompt: text, settings: settings, onMessage: messageHandler)
        }
    }

    func cancelRun() {
        runner.cancel()
    }
}
