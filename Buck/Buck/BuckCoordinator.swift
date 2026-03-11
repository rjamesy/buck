import Foundation
import ApplicationServices

@MainActor
class BuckCoordinator: ObservableObject {
    @Published var statusText: String = "Starting..."
    @Published var menuBarIcon: String = "circle"
    @Published var lastRoundInfo: String?

    private var fileWatcher: FileWatcher?
    private let bridge = ChatGPTBridge()
    private let writer = ResponseWriter()
    private let processingLock = NSLock()
    private var isProcessing = false
    private var activeRequestId: String?

    init() {
        checkAccessibility()
        startWatching()
    }

    private func checkAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            statusText = "Needs Accessibility permission"
            menuBarIcon = "xmark.circle"
        }
    }

    private func startWatching() {
        fileWatcher = FileWatcher { [weak self] url in
            guard let self else { return }
            Task { @MainActor in
                await self.handleInboxFile(url)
            }
        }
        statusText = "Watching inbox"
        menuBarIcon = "circle"
    }

    private func handleInboxFile(_ url: URL) async {
        // Parse request first (before lock) so we can write error responses
        let data: Data
        let request: ReviewRequest
        do {
            data = try Data(contentsOf: url)
            request = try JSONDecoder().decode(ReviewRequest.self, from: data)
        } catch {
            ChatGPTBridge.log("Failed to parse inbox file: \(url.lastPathComponent) — \(error)")
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Concurrency check
        processingLock.lock()
        if isProcessing {
            processingLock.unlock()
            ChatGPTBridge.log("[req:\(request.id)] Rejected — another message is in flight (active: \(activeRequestId ?? "unknown"))")
            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: .error,
                response: "Another message is in flight",
                round: 1
            )
            try? writer.write(response)
            try? FileManager.default.removeItem(at: url)
            return
        }
        isProcessing = true
        activeRequestId = request.id
        processingLock.unlock()

        defer {
            processingLock.lock()
            isProcessing = false
            activeRequestId = nil
            processingLock.unlock()
        }

        do {
            ChatGPTBridge.log("[req:\(request.id)] Processing started")
            statusText = "Processing: \(request.id)"
            menuBarIcon = "circle.fill"
            lastRoundInfo = nil

            let prompt = "\(request.promptPrefix)\n\n\(request.content)"

            _ = try bridge.findChatGPT()

            // Send to ChatGPT
            statusText = "Sending to ChatGPT..."
            ChatGPTBridge.log("[req:\(request.id)] Sending to ChatGPT...")
            try bridge.sendMessage(prompt)

            // Wait for response (single window — no resend on timeout)
            statusText = "Waiting for GPT..."
            ChatGPTBridge.log("[req:\(request.id)] Waiting for response")
            let responseText: String
            do {
                responseText = try await bridge.waitForResponse(timeout: 120)
            } catch BuckError.timeout {
                ChatGPTBridge.log("[req:\(request.id)] Timed out waiting for response")
                throw BuckError.timeout
            }

            // Determine if approved
            let lines = responseText.components(separatedBy: .newlines)
            let isApproved = lines.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.uppercased() == "APPROVED"
            }

            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: isApproved ? .approved : .feedback,
                response: responseText,
                round: 1
            )
            try writer.write(response)
            ChatGPTBridge.log("[req:\(request.id)] Response written — \(isApproved ? "approved" : "feedback")")

            statusText = isApproved ? "Approved: \(request.id)" : "Feedback: \(request.id)"
            menuBarIcon = "circle"
            lastRoundInfo = "Last: \(request.id) (\(isApproved ? "approved" : "feedback"))"

            try? FileManager.default.removeItem(at: url)

        } catch {
            ChatGPTBridge.log("[req:\(request.id)] Error: \(error.localizedDescription)")
            statusText = "Error: \(error.localizedDescription)"
            menuBarIcon = "xmark.circle"

            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: .error,
                response: error.localizedDescription,
                round: 1
            )
            try? writer.write(response)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
