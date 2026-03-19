import Foundation
import ApplicationServices

@MainActor
class BuckCoordinator: ObservableObject {
    @Published var statusText: String = "Starting..."
    @Published var menuBarIcon: String = "circle"
    @Published var lastRoundInfo: String?
    @Published var activeCaller: CallerID = .none

    enum CallerID: Equatable {
        case claude, codex, none
    }

    private var fileWatcher: FileWatcher?
    private let writer = ResponseWriter()
    private let sessionManager = SessionManager()

    // Per-channel state
    private struct ChannelState {
        let bridge: ChatGPTBridge
        var isProcessing = false
        var activeRequestId: String?
        var caller: CallerID = .none
    }

    private static let channelSubroles: [String: String] = [
        "a": "AXStandardWindow",   // main ChatGPT window
        "b": "AXSystemDialog",     // companion chat window
    ]

    private var channels: [String: ChannelState] = [:]
    private let channelLock = NSLock()

    private static func mapCaller(_ raw: String?) -> CallerID {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        default: return .none
        }
    }

    /// Derive activeCaller from channel state. Must be called while channelLock is held.
    private func deriveActiveCaller() -> CallerID {
        for key in channels.keys.sorted() {
            if channels[key]!.isProcessing && channels[key]!.caller != .none {
                return channels[key]!.caller
            }
        }
        return .none
    }

    init() {
        // Create a bridge per channel, each targeting a different window subrole
        for (name, subrole) in Self.channelSubroles {
            channels[name] = ChannelState(bridge: ChatGPTBridge(targetSubrole: subrole))
        }
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

        // Cache request for session tracking
        sessionManager.cacheRequest(request)

        // Resolve channel (default "a" for backwards compatibility)
        let channelName = request.channel ?? "a"
        guard channels[channelName] != nil else {
            ChatGPTBridge.log("[req:\(request.id)] Unknown channel: \(channelName)")
            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: .error,
                response: "Unknown channel: \(channelName)",
                round: 1
            )
            try? writer.write(response)
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Handle compact requests — separate flow
        if request.content.hasPrefix("[COMPACT_SESSION]") {
            await handleCompact(request: request, channel: channelName, url: url)
            return
        }

        // Per-channel concurrency check
        channelLock.lock()
        if channels[channelName]!.isProcessing {
            let activeId = channels[channelName]!.activeRequestId ?? "unknown"
            channelLock.unlock()
            ChatGPTBridge.log("[req:\(request.id)] Rejected — channel \(channelName) in flight (active: \(activeId))")
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
        channels[channelName]!.isProcessing = true
        channels[channelName]!.activeRequestId = request.id
        channels[channelName]!.caller = Self.mapCaller(request.caller)
        let derived = deriveActiveCaller()
        channelLock.unlock()
        if activeCaller != derived { activeCaller = derived }

        defer {
            channelLock.lock()
            channels[channelName]!.isProcessing = false
            channels[channelName]!.activeRequestId = nil
            channels[channelName]!.caller = .none
            let derivedAfter = deriveActiveCaller()
            channelLock.unlock()
            if activeCaller != derivedAfter { activeCaller = derivedAfter }
        }

        let bridge = channels[channelName]!.bridge

        do {
            ChatGPTBridge.log("[req:\(request.id)] Processing started (channel \(channelName))")
            statusText = "[\(channelName)] Processing: \(request.id)"
            menuBarIcon = "circle.fill"
            lastRoundInfo = nil

            let prompt = "\(request.promptPrefix)\n\n\(request.content)"

            _ = try bridge.findChatGPT()

            // Send to ChatGPT
            statusText = "[\(channelName)] Sending to ChatGPT..."
            ChatGPTBridge.log("[req:\(request.id)] Sending to ChatGPT (channel \(channelName))...")
            try bridge.sendMessage(prompt)

            // Wait for response
            statusText = "[\(channelName)] Waiting for GPT..."
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

            // Check if session needs compaction before writing response
            let sessionId = request.sessionId ?? "default"
            var finalResponseText = responseText
            if sessionManager.shouldCompact(sessionId: sessionId) {
                finalResponseText += "\n\n[BUCK: Ready for compact]"
                ChatGPTBridge.log("[req:\(request.id)] Appended compact signal for session \(sessionId)")
            }

            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: isApproved ? .approved : .feedback,
                response: finalResponseText,
                round: 1
            )
            try writer.write(response)

            // Record in session history (after file I/O)
            sessionManager.recordResponse(requestId: request.id, responseText: responseText)

            ChatGPTBridge.log("[req:\(request.id)] Response written — \(isApproved ? "approved" : "feedback")")

            statusText = isApproved ? "[\(channelName)] Approved" : "[\(channelName)] Feedback"
            menuBarIcon = "circle"
            lastRoundInfo = "[\(channelName)] \(request.id) (\(isApproved ? "approved" : "feedback"))"

            try? FileManager.default.removeItem(at: url)

        } catch {
            ChatGPTBridge.log("[req:\(request.id)] Error: \(error.localizedDescription)")
            statusText = "[\(channelName)] Error: \(error.localizedDescription)"
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

    // MARK: - Session Compact

    private func handleCompact(request: ReviewRequest, channel channelName: String, url: URL) async {
        channelLock.lock()
        if channels[channelName]!.isProcessing {
            channelLock.unlock()
            ChatGPTBridge.log("[req:\(request.id)] Compact rejected — channel \(channelName) in flight")
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
        channels[channelName]!.isProcessing = true
        channels[channelName]!.activeRequestId = request.id
        channels[channelName]!.caller = Self.mapCaller(request.caller)
        let derived = deriveActiveCaller()
        channelLock.unlock()
        if activeCaller != derived { activeCaller = derived }

        defer {
            channelLock.lock()
            channels[channelName]!.isProcessing = false
            channels[channelName]!.activeRequestId = nil
            channels[channelName]!.caller = .none
            let derivedAfter = deriveActiveCaller()
            channelLock.unlock()
            if activeCaller != derivedAfter { activeCaller = derivedAfter }
        }

        let bridge = channels[channelName]!.bridge
        let sessionId = request.sessionId ?? "default"
        ChatGPTBridge.log("[req:\(request.id)] Compact started for session \(sessionId) (channel \(channelName))")
        statusText = "[\(channelName)] Compacting session..."
        menuBarIcon = "circle.fill"

        let rawSummary = sessionManager.getSummary(forClaudeSession: sessionId)
        let summary = rawSummary.isEmpty ? "(No summary available — this is a fresh compact)" : rawSummary

        do {
            _ = try bridge.findChatGPT()

            // Open a fresh ChatGPT thread
            bridge.startNewChat()

            // Send summary as first message
            let injection = "Here is the context from our previous session. Confirm with UNDERSTOOD.\n\n\(summary)"
            try bridge.sendMessage(injection)

            // Wait for GPT to confirm
            let confirmation = try await bridge.waitForResponse(timeout: 60)

            // Rotate GPT session in database
            sessionManager.handleCompactComplete(sessionId: sessionId)

            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: .approved,
                response: confirmation,
                round: 1
            )
            try writer.write(response)

            ChatGPTBridge.log("[req:\(request.id)] Compact complete for session \(sessionId)")
            statusText = "[\(channelName)] Compacted: \(sessionId)"
            menuBarIcon = "circle"
            lastRoundInfo = "[\(channelName)] Compacted \(sessionId.prefix(8))"

        } catch {
            ChatGPTBridge.log("[req:\(request.id)] Compact error: \(error.localizedDescription)")
            statusText = "[\(channelName)] Compact error"
            menuBarIcon = "xmark.circle"

            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: .error,
                response: "Compact failed: \(error.localizedDescription)",
                round: 1
            )
            try? writer.write(response)
        }

        try? FileManager.default.removeItem(at: url)
    }
}
