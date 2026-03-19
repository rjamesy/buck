import Foundation
import ApplicationServices
import AppKit

@MainActor
class RogersCoordinator: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var pollIntervalSeconds: Double = 10
    @Published var isCompacting: Bool = false
    @Published var compactStatus: String = ""
    @Published var activeTurnCount: Int = 0
    @Published var statusMessage: String = ""
    @Published var axPermissionGranted: Bool = false

    private let reader = ThreadReader()
    private let store = SessionStore()
    private let summarizer = OllamaSummarizer()
    private var pollTimer: Timer?
    private var lastVisibleCount: Int = 0
    private var currentSessionId: String?
    private var lastSidebarNames: [String] = []

    init() {
        checkAccessibility()
        loadPollInterval()
        startPolling()  // Always poll — poll() auto-retries AX permission
        sessions = store.getAllSessions()
    }

    private func checkAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        axPermissionGranted = AXIsProcessTrustedWithOptions(options)
        if !axPermissionGranted {
            statusMessage = "Needs Accessibility permission"
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func retryAccessibility() {
        axPermissionGranted = AXIsProcessTrusted()
        if axPermissionGranted {
            statusMessage = ""
            startPolling()
        } else {
            statusMessage = "Needs Accessibility permission"
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.poll()
            }
        }
    }

    func updatePollInterval(_ interval: Double) {
        pollIntervalSeconds = interval
        UserDefaults.standard.set(interval, forKey: "rogers_poll_interval")
        startPolling()
    }

    private func loadPollInterval() {
        let saved = UserDefaults.standard.double(forKey: "rogers_poll_interval")
        if saved > 0 {
            pollIntervalSeconds = saved
        }
    }

    func poll() {
        guard axPermissionGranted else {
            retryAccessibility()
            return
        }

        guard reader.isChatGPTRunning() else {
            statusMessage = "ChatGPT not running"
            if currentSessionId != nil {
                store.clearActiveFlags()
                currentSessionId = nil
                activeTurnCount = 0
                refreshSessions()
            }
            return
        }

        guard reader.findChatGPT() else {
            statusMessage = "No AX access"
            return
        }

        statusMessage = ""

        // Read visible messages for fingerprinting
        let visibleCount = reader.countVisibleMessages()
        let visibleMessages = reader.readVisibleMessages()

        if visibleMessages.isEmpty {
            statusMessage = "No active thread"
            if currentSessionId != nil {
                store.clearActiveFlags()
                currentSessionId = nil
                activeTurnCount = 0
                refreshSessions()
            }
            return
        }

        let hashes = visibleMessages.map { $0.contentHash }

        // Try fingerprint match first
        if let matchedId = store.findSessionByFingerprint(hashes: hashes) {
            // Known session
            if currentSessionId != matchedId {
                currentSessionId = matchedId
                store.setActiveSession(id: matchedId)
            }

            // Ingest any new visible messages
            let newCount = store.ingestMessages(sessionId: matchedId, messages: visibleMessages)
            if newCount > 0 {
                ThreadReader.log("Ingested \(newCount) messages for session \(matchedId.prefix(8))")
            }

            // Try to update title from sidebar or toolbar
            updateSessionTitle(sessionId: matchedId)

        } else {
            // New session — determine title
            let title = resolveNewSessionTitle(visibleMessages: visibleMessages)
            let gptName = reader.readThreadTitle()?.gptName ?? ""

            let newId = store.createSession(threadTitle: title, gptName: gptName)
            currentSessionId = newId
            store.setActiveSession(id: newId)

            let newCount = store.ingestMessages(sessionId: newId, messages: visibleMessages)
            ThreadReader.log("New session \(newId.prefix(8)) — \"\(title)\" (\(newCount) messages)")
        }

        // Update sidebar snapshot
        let currentSidebar = reader.readSidebarNames()
        lastSidebarNames = currentSidebar

        lastVisibleCount = visibleCount

        // Refresh published state
        refreshSessions()
        if let sid = currentSessionId {
            activeTurnCount = store.getMessageCount(sessionId: sid)
        }
    }

    /// Try to update a session's title. Only resolves if sidebar_name is empty.
    /// Always allows toolbar upgrade (custom GPT titles are more specific).
    private func updateSessionTitle(sessionId: String) {
        // Toolbar custom GPT title always wins (more specific than sidebar)
        if let titleInfo = reader.readThreadTitle() {
            store.updateSidebarName(id: sessionId, sidebarName: titleInfo.title)
            return
        }

        // If session already has a non-empty sidebar_name → skip re-resolution
        let existing = store.getSummary(sessionId: sessionId)
        // Check the actual title via sessions list
        if let session = sessions.first(where: { $0.id == sessionId }),
           !session.threadTitle.isEmpty,
           !session.threadTitle.hasPrefix("Session "),
           session.threadTitle.count > 5 {
            return  // Already has a good title
        }

        // No title yet — try sidebar snapshot diff
        let currentSidebar = reader.readSidebarNames().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let previousSet = Set(lastSidebarNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let allKnownTitles = Set(store.getAllSessionTitles().values)
        let newNames = currentSidebar.filter { !previousSet.contains($0) && !allKnownTitles.contains($0) }

        if newNames.count == 1 {
            store.updateSidebarName(id: sessionId, sidebarName: newNames[0])
            ThreadReader.log("Title updated from sidebar: \(newNames[0])")
        }
        _ = existing  // suppress unused warning
    }

    /// Determine the title for a new session. Debounces sidebar read.
    private func resolveNewSessionTitle(visibleMessages: [ThreadMessage]) -> String {
        // Toolbar custom GPT title
        if let titleInfo = reader.readThreadTitle() {
            return titleInfo.title
        }

        // Diff sidebar against previous snapshot — detect new entries
        let currentSidebar = reader.readSidebarNames().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let previousSet = Set(lastSidebarNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let knownTitles = Set(store.getAllSessionTitles().values)

        // Check if first item is truly new (not reordered from elsewhere in the list)
        if let first = currentSidebar.first,
           !previousSet.contains(first),
           !knownTitles.contains(first) {
            return first
        }

        // Check for any new sidebar entries not matching existing sessions
        let newNames = currentSidebar.filter { !previousSet.contains($0) && !knownTitles.contains($0) }
        if let firstName = newNames.first {
            return firstName
        }

        // Fallback: use first user message content (truncated, stable per session)
        if let firstUser = visibleMessages.first(where: { $0.role == "user" }) {
            let truncated = String(firstUser.content.prefix(60))
            return truncated.count < firstUser.content.count ? truncated + "..." : truncated
        }

        return "Session \(ISO8601DateFormatter().string(from: Date()).prefix(16))"
    }

    private func refreshSessions() {
        sessions = store.getAllSessions()
    }

    // MARK: - Compact

    func compact(sessionId: String) async {
        guard !isCompacting else { return }

        // Check AX lock
        if ThreadReader.isAXLocked() {
            compactStatus = "Buck is active, try later"
            ThreadReader.log("Compact aborted: AX lock active")
            return
        }

        isCompacting = true
        compactStatus = "Reading full thread..."
        ThreadReader.log("Compact started for session \(sessionId.prefix(8))")

        // 1. Read ALL messages (scroll top → bottom)
        guard reader.findChatGPT() else {
            compactStatus = "ChatGPT not available"
            isCompacting = false
            return
        }

        let allMessages = reader.readAllMessages()
        if allMessages.isEmpty {
            compactStatus = "No messages to compact"
            isCompacting = false
            return
        }

        // Ingest into DB
        let _ = store.ingestMessages(sessionId: sessionId, messages: allMessages)

        // 2. Generate summary
        compactStatus = "Generating summary..."
        let dbMessages = store.getAllMessages(sessionId: sessionId)

        guard await summarizer.isAvailable() else {
            compactStatus = "Ollama not available"
            isCompacting = false
            ThreadReader.log("Compact aborted: Ollama unavailable")
            return
        }

        guard let summary = await summarizer.summarizeFull(messages: dbMessages) else {
            compactStatus = "Summary generation failed"
            isCompacting = false
            return
        }

        // Store summary
        store.updateSummary(sessionId: sessionId, summary: summary)

        // 3. Check AX lock again before write operations
        if ThreadReader.isAXLocked() {
            compactStatus = "Buck became active, aborting"
            isCompacting = false
            return
        }

        // 4. Open new thread
        compactStatus = "Opening new thread..."
        reader.startNewChat()
        Thread.sleep(forTimeInterval: 1.0)

        // 5. Inject summary
        compactStatus = "Injecting summary..."
        let injection = "Here is the context from our previous session. Confirm with UNDERSTOOD.\n\n\(summary)"
        guard reader.sendMessage(injection) else {
            compactStatus = "Failed to send summary"
            isCompacting = false
            return
        }

        // 6. Wait for GPT response
        compactStatus = "Waiting for confirmation..."
        let confirmation = reader.waitForResponse(timeout: 60)

        guard confirmation != nil else {
            compactStatus = "GPT did not confirm — old data preserved"
            isCompacting = false
            return
        }

        // 7. Wait for new thread to settle, then read its info
        Thread.sleep(forTimeInterval: 1.0)

        // Read sidebar to find the new thread's title
        let sidebarNames = reader.readSidebarNames()
        let knownTitles = Set(store.getAllSessionTitles().values)
        let newSidebarNames = sidebarNames.filter { !knownTitles.contains($0) }
        let newTitle = newSidebarNames.first ?? "Compacted Session"
        let newGptName = reader.readThreadTitle()?.gptName ?? ""

        // Create new session entry
        let newSessionId = store.createSession(threadTitle: newTitle, gptName: newGptName)

        // 8. Verify: read back messages from new thread
        let newMessages = reader.readVisibleMessages()
        let hasInjectedContent = newMessages.contains { $0.content.contains("previous session") || $0.content.contains(String(summary.prefix(50))) }

        if hasInjectedContent || !newMessages.isEmpty {
            // Verification passed — mark old session as compacted
            compactStatus = "Cleaning up..."
            store.markCompacted(id: sessionId, intoSessionId: newSessionId)
            store.setActiveSession(id: newSessionId)
            currentSessionId = newSessionId

            // Ingest the new thread's messages
            if !newMessages.isEmpty {
                let _ = store.ingestMessages(sessionId: newSessionId, messages: newMessages)
            }

            ThreadReader.log("Compact complete: \(sessionId.prefix(8)) → \(newSessionId.prefix(8))")
            compactStatus = "Done"
        } else {
            // Verification failed — keep old data
            compactStatus = "Verification failed — old data preserved"
            ThreadReader.log("Compact verification failed for \(sessionId.prefix(8))")
            store.deleteSession(id: newSessionId)
        }

        refreshSessions()
        isCompacting = false

        // Clear status after a delay
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !isCompacting {
                compactStatus = ""
            }
        }
    }

    // MARK: - Delete

    func deleteSession(id: String) {
        store.deleteSession(id: id)
        if currentSessionId == id {
            currentSessionId = nil
            lastSidebarNames = []
            activeTurnCount = 0
        }
        refreshSessions()
        ThreadReader.log("Session deleted: \(id.prefix(8))")
    }

    func deleteAllSessions() {
        let allSessions = store.getAllSessions()
        for session in allSessions {
            store.deleteSession(id: session.id)
        }
        currentSessionId = nil
        lastSidebarNames = []
        activeTurnCount = 0
        refreshSessions()
        ThreadReader.log("All sessions deleted (\(allSessions.count) sessions)")
    }
}
