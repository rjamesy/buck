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
        let bridge: any BridgeProtocol
        var isProcessing = false
        var activeRequestId: String?
        var caller: CallerID = .none
    }

    private var channels: [String: ChannelState] = [:]
    private let channelLock = NSLock()

    // Cross-channel ChatGPT app lock. Channels "a" and "b" both bind ChatGPTBridge
    // to the same ChatGPT.app process and share its window-global send/stop button
    // signals (used by waitForResponse since fd31ba8). Without this lock, two
    // concurrent callers on different channels race on the same button cycle and
    // pick up each other's responses.
    //
    // LOCK ORDER (must be uniform across handleInboxFile, handleCompact, forward):
    //   1. chatgptAppLock.tryLock()  — acquired FIRST  for ChatGPT-targeting channels
    //   2. channelLock.lock()        — acquired SECOND for per-channel state
    // Releases run in reverse order naturally via Swift LIFO defer.
    private let chatgptAppLock = NSLock()
    private static let chatgptChannels: Set<String> = ["a", "b"]

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
        // ChatGPT channels (different window subroles)
        channels["a"] = ChannelState(bridge: ChatGPTBridge(targetSubrole: "AXStandardWindow"))
        channels["b"] = ChannelState(bridge: ChatGPTBridge(targetSubrole: "AXSystemDialog"))
        // Cursor channel
        channels["cursor"] = ChannelState(bridge: CursorBridge())
        // Codex channel (direct OpenAI API — no desktop app needed)
        channels["codex"] = ChannelState(bridge: CodexBridge())
        // Twilio SMS channel (notifications — no desktop app needed)
        let twilio = TwilioBridge()
        channels["twilio"] = ChannelState(bridge: twilio)
        // Wire the ask-timeout fallback: if the user doesn't reply by SMS, forward
        // the question to the ChatGPT channel so Claude still gets an answer.
        twilio.onAskTimeout = { [weak self] question in
            guard let self else {
                throw TwilioBridgeError.apiError("Coordinator deallocated before fallback")
            }
            let prompt = "[SMS TIMEOUT FALLBACK] The user did not reply to this question by SMS in time. Please answer it directly:\n\n\(question)"
            return try await self.forward(to: "a", prompt: prompt, timeout: 120)
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
            BuckLog.log("Failed to parse inbox file: \(url.lastPathComponent) — \(error)")
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Cache request for session tracking
        sessionManager.cacheRequest(request)

        // Resolve channel (default "a" for backwards compatibility)
        let channelName = request.channel ?? "a"
        guard channels[channelName] != nil else {
            BuckLog.log("[req:\(request.id)] Unknown channel: \(channelName)")
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

        // Cross-channel ChatGPT app lock — see chatgptAppLock declaration for rationale.
        let needsAppLock = Self.chatgptChannels.contains(channelName)
        if needsAppLock && !chatgptAppLock.try() {
            BuckLog.log("[req:\(request.id)] Rejected — ChatGPT app busy on another channel")
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
        defer { if needsAppLock { chatgptAppLock.unlock() } }

        // Handle compact requests — separate flow.
        // appLockAlreadyHeld:true so handleCompact doesn't double-acquire (NSLock is not recursive).
        if request.content.hasPrefix("[COMPACT_SESSION]") {
            await handleCompact(request: request, channel: channelName, url: url, appLockAlreadyHeld: needsAppLock)
            return
        }

        // Per-channel concurrency check
        channelLock.lock()
        if channels[channelName]!.isProcessing {
            let activeId = channels[channelName]!.activeRequestId ?? "unknown"
            channelLock.unlock()
            BuckLog.log("[req:\(request.id)] Rejected — channel \(channelName) in flight (active: \(activeId))")
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
            BuckLog.log("[req:\(request.id)] Processing started (channel \(channelName))")
            statusText = "[\(channelName)] Processing: \(request.id)"
            menuBarIcon = "circle.fill"
            lastRoundInfo = nil

            let prompt = "\(request.promptPrefix)\n\n\(request.content)"

            _ = try bridge.findApp()

            statusText = "[\(channelName)] Sending to \(bridge.name)..."
            BuckLog.log("[req:\(request.id)] Sending to \(bridge.name) (channel \(channelName))...")
            try bridge.sendMessage(prompt)

            statusText = "[\(channelName)] Waiting for \(bridge.name)..."
            BuckLog.log("[req:\(request.id)] Waiting for response")
            let responseText: String
            do {
                responseText = try await bridge.waitForResponse(timeout: 600)
            } catch BridgeError.timeout {
                BuckLog.log("[req:\(request.id)] Timed out waiting for response")
                throw BridgeError.timeout
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
                BuckLog.log("[req:\(request.id)] Appended compact signal for session \(sessionId)")
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

            BuckLog.log("[req:\(request.id)] Response written — \(isApproved ? "approved" : "feedback")")

            statusText = isApproved ? "[\(channelName)] Approved" : "[\(channelName)] Feedback"
            menuBarIcon = "circle"
            lastRoundInfo = "[\(channelName)] \(request.id) (\(isApproved ? "approved" : "feedback"))"

            try? FileManager.default.removeItem(at: url)

        } catch {
            BuckLog.log("[req:\(request.id)] Error: \(error.localizedDescription)")
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

    private func handleCompact(request: ReviewRequest, channel channelName: String, url: URL, appLockAlreadyHeld: Bool = false) async {
        // Cross-channel ChatGPT app lock (skip if caller already holds it).
        // See chatgptAppLock declaration for rationale and uniform lock order.
        let needsAppLock = Self.chatgptChannels.contains(channelName) && !appLockAlreadyHeld
        if needsAppLock && !chatgptAppLock.try() {
            BuckLog.log("[req:\(request.id)] Compact rejected — ChatGPT app busy on another channel")
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
        defer { if needsAppLock { chatgptAppLock.unlock() } }

        channelLock.lock()
        if channels[channelName]!.isProcessing {
            channelLock.unlock()
            BuckLog.log("[req:\(request.id)] Compact rejected — channel \(channelName) in flight")
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
        BuckLog.log("[req:\(request.id)] Compact started for session \(sessionId) (channel \(channelName))")
        statusText = "[\(channelName)] Compacting session..."
        menuBarIcon = "circle.fill"

        let rawSummary = sessionManager.getSummary(forClaudeSession: sessionId)
        let summary = rawSummary.isEmpty ? "(No summary available — this is a fresh compact)" : rawSummary

        do {
            _ = try bridge.findApp()

            bridge.startNewChat()

            let injection = "Here is the context from our previous session. Confirm with UNDERSTOOD.\n\n\(summary)"
            try bridge.sendMessage(injection)

            let confirmation = try await bridge.waitForResponse(timeout: 60)
            sessionManager.handleCompactComplete(sessionId: sessionId)

            let response = ReviewResponse(
                id: request.id,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: .approved,
                response: confirmation,
                round: 1
            )
            try writer.write(response)

            BuckLog.log("[req:\(request.id)] Compact complete for session \(sessionId)")
            statusText = "[\(channelName)] Compacted: \(sessionId)"
            menuBarIcon = "circle"
            lastRoundInfo = "[\(channelName)] Compacted \(sessionId.prefix(8))"

        } catch {
            BuckLog.log("[req:\(request.id)] Compact error: \(error.localizedDescription)")
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

    // MARK: - Bridge-to-bridge forwarding
    //
    // Used by bridges that need to hand off work to another channel (currently:
    // TwilioBridge's SMS-timeout → ChatGPT fallback). Acquires the target
    // channel's lock, runs the full findApp/send/wait cycle, releases the lock.
    // Callers must NOT already hold the target channel's lock — that would
    // deadlock. Cross-channel calls are fine (twilio → a).
    func forward(to channelName: String, prompt: String, timeout: TimeInterval) async throws -> String {
        // Cross-channel ChatGPT app lock — acquired BEFORE channelLock to honour
        // uniform lock order (see chatgptAppLock declaration).
        let needsAppLock = Self.chatgptChannels.contains(channelName)
        if needsAppLock && !chatgptAppLock.try() {
            throw TwilioBridgeError.apiError("Forward target channel \(channelName) is busy (ChatGPT app held by another channel)")
        }
        defer { if needsAppLock { chatgptAppLock.unlock() } }

        channelLock.lock()
        guard channels[channelName] != nil else {
            channelLock.unlock()
            throw TwilioBridgeError.apiError("Unknown forward channel: \(channelName)")
        }
        if channels[channelName]!.isProcessing {
            channelLock.unlock()
            throw TwilioBridgeError.apiError("Forward target channel \(channelName) is busy")
        }
        channels[channelName]!.isProcessing = true
        channels[channelName]!.activeRequestId = "fwd_\(UUID().uuidString.prefix(8))"
        let bridge = channels[channelName]!.bridge
        channelLock.unlock()

        defer {
            channelLock.lock()
            channels[channelName]!.isProcessing = false
            channels[channelName]!.activeRequestId = nil
            channels[channelName]!.caller = .none
            channelLock.unlock()
        }

        BuckLog.log("[Forward] → channel \(channelName) (\(bridge.name))")
        _ = try bridge.findApp()
        try bridge.sendMessage(prompt)
        let result = try await bridge.waitForResponse(timeout: timeout)
        BuckLog.log("[Forward] ← channel \(channelName) responded (\(result.count) chars)")
        return result
    }
}
