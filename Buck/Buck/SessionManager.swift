import Foundation

/// Manages chat session history, summarization, and latency monitoring.
/// Called explicitly by BuckCoordinator — cacheRequest on inbox, recordResponse on outbox.
/// Does NOT interact with ChatGPT directly — all compact requests go through BuckCoordinator.
@MainActor
class SessionManager {
    let store = ChatHistoryStore()
    private let summarizer = OllamaSummarizer()

    /// Cached request content keyed by request ID — set when inbox file appears
    private var pendingRequests: [String: (content: String, sessionId: String, receivedAt: Date)] = [:]

    /// Track total operations for periodic cleanup
    private var operationCount = 0

    /// Latency threshold in ms — if rolling avg exceeds this, signal compact
    private let latencyThresholdMs = 15_000
    /// Minimum turns before considering compact
    private let minTurnsForCompact = 10

    init() {
        store.cleanupOldSessions()
        NSLog("[Buck] SessionManager initialized")
    }

    // MARK: - Request Caching (called by BuckCoordinator)

    /// Cache a request's content when it arrives in the inbox.
    /// Called by BuckCoordinator after parsing the request, before processing.
    func cacheRequest(_ request: ReviewRequest) {
        let sessionId = request.sessionId ?? "default"
        pendingRequests[request.id] = (
            content: request.content,
            sessionId: sessionId,
            receivedAt: Date()
        )

        // Ensure sessions exist
        _ = store.getOrCreateClaudeSession(id: sessionId)
        _ = store.getCurrentGPTSession(forClaudeSession: sessionId)

        NSLog("[Buck] SessionManager: cached request %@ for session %@", request.id, sessionId)
    }

    // MARK: - Response Recording (called after outbox write)

    /// Record a completed request-response pair.
    /// Called by BuckCoordinator after writing the response to outbox.
    func recordResponse(requestId: String, responseText: String) {
        guard let cached = pendingRequests.removeValue(forKey: requestId) else {
            NSLog("[Buck] SessionManager: no cached request for %@, skipping recording", requestId)
            return
        }

        // Skip compact requests
        if cached.content.hasPrefix("[COMPACT_SESSION]") {
            return
        }

        let sessionId = cached.sessionId
        let latencyMs = Int(Date().timeIntervalSince(cached.receivedAt) * 1000)

        let gptSessionId = store.getCurrentGPTSession(forClaudeSession: sessionId)
        let turnCount = store.getGPTTurnCount(gptSessionId: gptSessionId) + 1

        // Record user message
        store.recordMessage(
            gptSessionId: gptSessionId,
            turnNumber: turnCount,
            role: "user",
            content: cached.content
        )

        // Record assistant message with latency
        store.recordMessage(
            gptSessionId: gptSessionId,
            turnNumber: turnCount,
            role: "assistant",
            content: responseText,
            latencyMs: latencyMs
        )

        // Update counts
        store.incrementGPTTurnCount(gptSessionId: gptSessionId)
        store.incrementTurns(forClaudeSession: sessionId)

        NSLog("[Buck] SessionManager: recorded turn %d for session %@, latency=%dms", turnCount, sessionId, latencyMs)

        // Async summarization — fire and forget
        Task {
            await updateSummary(sessionId: sessionId, gptSessionId: gptSessionId)
        }

        // Periodic cleanup
        operationCount += 1
        if operationCount % 100 == 0 {
            store.cleanupOldSessions()
        }
    }

    // MARK: - Latency Check

    /// Check if GPT is slowing down for a given session.
    /// Returns true if the session should be compacted.
    func shouldCompact(sessionId: String) -> Bool {
        let gptSessionId = store.getCurrentGPTSession(forClaudeSession: sessionId)
        let turnCount = store.getGPTTurnCount(gptSessionId: gptSessionId)

        guard turnCount >= minTurnsForCompact else { return false }

        let latencies = store.getRecentLatencies(gptSessionId: gptSessionId, limit: 5)
        guard latencies.count >= 3 else { return false }

        let avg = latencies.reduce(0, +) / latencies.count
        let shouldCompact = avg > latencyThresholdMs

        if shouldCompact {
            NSLog("[Buck] SessionManager: latency degraded for session %@ — avg=%dms threshold=%dms turns=%d",
                  sessionId, avg, latencyThresholdMs, turnCount)
        }

        return shouldCompact
    }

    // MARK: - Summary Access

    /// Get the current summary for a claude session
    func getSummary(forClaudeSession sessionId: String) -> String {
        return store.getSummary(forClaudeSession: sessionId)
    }

    // MARK: - Compact Support

    /// Called after a successful compact: rotate GPT session
    func handleCompactComplete(sessionId: String) {
        _ = store.rotateGPTSession(forClaudeSession: sessionId)
        NSLog("[Buck] SessionManager: rotated GPT session for %@", sessionId)
    }

    // MARK: - Summarization

    private func updateSummary(sessionId: String, gptSessionId: String) async {
        let existingSummary = store.getSummary(forClaudeSession: sessionId)
        let recentMessages = store.getRecentMessages(gptSessionId: gptSessionId, limit: 2)

        guard !recentMessages.isEmpty else { return }

        if let newSummary = await summarizer.summarize(
            existingSummary: existingSummary,
            newMessages: recentMessages
        ) {
            store.updateSummary(forClaudeSession: sessionId, summary: newSummary)
        }
    }
}
