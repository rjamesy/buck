import Foundation
import SwiftUI
import ApplicationServices

@MainActor
final class TeamsCoordinator: ObservableObject {
    // MARK: - Published state (UI binds to these)
    @Published var messages: [TeamMessage] = []
    @Published var participants: [Participant] = Participant.Name.allCases.map { Participant.initial($0) }
    @Published var decisionsText: String = ""
    @Published var sessionActive: Bool = false
    @Published var currentSession: TeamsSession?
    @Published var systemPrompt: String = SessionManager.defaultSystemPrompt
    @Published var debugInfo: DebugInfo = DebugInfo()
    @Published var participantEnabled: [Participant.Name: Bool] = [
        .user: true, .claude: true, .codex: true, .gpt: true
    ]

    struct DebugInfo {
        var messageCounts: [String: Int] = [:]
        var lastGPTLatency: TimeInterval = 0
        var errors: [String] = []
        var currentSeq: Int = 0
    }

    // MARK: - Dependencies
    private let chatLog = ChatLogStore()
    private let participantManager = ParticipantManager()
    private let sessionManager = SessionManager()
    private let decisionStore = DecisionStore()
    private let bridges: [String: any BridgeProtocol] = [
        "gpt": CodexBridge(model: "gpt-5.4-mini"),
        "codex": CodexBridge(),
        "cursor": CursorBridge()
    ]

    // MARK: - Internal state
    private var routedMessageIds: Set<String> = []
    private var lastRateLimit: [String: Date] = [:]
    private var stagingWatcher: StagingWatcher?
    private var heartbeatTimer: Timer?
    private var pollTimer: Timer?
    private var bridgeQueues: [String: [TeamMessage]] = ["gpt": [], "codex": [], "cursor": []]
    private var bridgeProcessing: [String: Bool] = ["gpt": false, "codex": false, "cursor": false]
    private var bridgeDisabled: [String: Bool] = ["gpt": false, "codex": false, "cursor": false]

    // MARK: - Init

    init() {
        TeamsLog.log("TeamsPaths.root: \(TeamsPaths.root.path) (resolved: \(TeamsPaths.root.resolvingSymlinksInPath().path))")
        refreshParticipants()
        refreshDecisions()

        // Always start staging watcher and session poll (even without active session)
        // This allows external session creation via CLI
        startStagingWatcher()
        startTimers()

        if let session = sessionManager.readSession(), session.active {
            currentSession = session
            sessionActive = true
            systemPrompt = session.systemPrompt
            loadMessages(session.sessionId)
            participantManager.setOnline(.user, sessionId: session.sessionId)
            refreshParticipants()
            TeamsLog.log("Resumed active session: \(session.sessionId)")
        }
    }

    // MARK: - Session lifecycle

    func startSession() {
        do {
            let session = try sessionManager.createSession(systemPrompt: systemPrompt)
            currentSession = session
            sessionActive = true
            messages = []
            routedMessageIds = []
            debugInfo = DebugInfo()

            // Set user online
            participantManager.setOnline(.user, sessionId: session.sessionId)
            refreshParticipants()

            // Post system message
            let sysMsg = createMessage(
                from: .user, to: "all", type: .system,
                content: "Teams session started. System prompt has been set.",
                source: .ui
            )
            appendAndRoute(sysMsg)

            // Inject system prompt into bridges silently (not shown in chat)
            let gptPrompt = createMessage(
                from: .user, to: "gpt", type: .system,
                content: "SYSTEM: You are GPT. Your name in this chat is GPT. Only respond as GPT. Never impersonate or respond on behalf of Claude, Codex, or User. If a message is addressed to another participant, do not answer it.\n\n\(systemPrompt)",
                source: .ui
            )
            enqueueBridgeMessage(gptPrompt, bridgeKey: "gpt")

            let codexPrompt = createMessage(
                from: .user, to: "codex", type: .system,
                content: "SYSTEM: You are Codex. Your name in this chat is Codex. Only respond as Codex. Never impersonate or respond on behalf of Claude, GPT, or User. If a message is addressed to another participant, do not answer it.\n\n\(systemPrompt)",
                source: .ui
            )
            enqueueBridgeMessage(codexPrompt, bridgeKey: "codex")

            // Start watchers
            startStagingWatcher()
            startTimers()

            TeamsLog.log("Session started: \(session.sessionId)")
        } catch {
            debugInfo.errors.append("Start failed: \(error.localizedDescription)")
            TeamsLog.log("Failed to start session: \(error)")
        }
    }

    func stopSession() {
        guard sessionActive else { return }

        let endMsg = createMessage(
            from: .user, to: "all", type: .system,
            content: "Teams session ended.",
            source: .ui
        )
        appendAndRoute(endMsg)

        // Set all offline
        for name in Participant.Name.allCases {
            participantManager.setOffline(name)
        }

        // Clear all bridge queues to stop in-flight message loops
        bridgeQueues = ["gpt": [], "codex": [], "cursor": []]
        bridgeProcessing = ["gpt": false, "codex": false, "cursor": false]

        try? sessionManager.endSession()
        sessionActive = false
        currentSession = nil
        stopTimers()
        stagingWatcher = nil
        refreshParticipants()
        TeamsLog.log("Session stopped")
    }

    func resetSession() {
        stopSession()
        sessionManager.cleanAll()
        decisionStore.clearDecisions()
        messages = []
        decisionsText = ""
        routedMessageIds = []
        lastRateLimit = [:]
        bridgeQueues = ["gpt": [], "codex": [], "cursor": []]
        bridgeProcessing = ["gpt": false, "codex": false, "cursor": false]
        bridgeDisabled = ["gpt": false, "codex": false, "cursor": false]
        debugInfo = DebugInfo()
        refreshParticipants()
        TeamsLog.log("Session reset")
    }

    // MARK: - User input

    func sendUserMessage(_ text: String) {
        guard sessionActive, !text.isEmpty else { return }

        let msg = createMessage(
            from: .user, to: "all", type: .chat,
            content: text, priority: .high, source: .ui
        )
        appendAndRoute(msg)
    }

    // MARK: - Message creation & routing

    private func createMessage(
        from: Participant.Name,
        to: String,
        type: TeamMessage.MessageType,
        content: String,
        priority: TeamMessage.Priority = .normal,
        source: TeamMessage.Source = .ui,
        replyTo: Int? = nil
    ) -> TeamMessage {
        let seq = (try? sessionManager.nextSeq()) ?? 0
        return TeamMessage(
            id: "msg_\(UUID().uuidString)",
            seq: seq,
            sessionId: currentSession?.sessionId ?? "",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            from: from,
            to: to,
            type: type,
            content: content,
            priority: priority,
            source: source,
            replyTo: replyTo
        )
    }

    func appendAndRoute(_ message: TeamMessage) {
        guard !routedMessageIds.contains(message.id) else { return }
        routedMessageIds.insert(message.id)

        // Append to chat log
        do {
            try chatLog.append(message)
        } catch {
            TeamsLog.log("Failed to append: \(error)")
            debugInfo.errors.append("Write failed: \(error.localizedDescription)")
        }

        // Update UI
        messages.append(message)
        debugInfo.currentSeq = message.seq ?? debugInfo.currentSeq
        debugInfo.messageCounts[message.from.rawValue, default: 0] += 1

        // Route to recipients
        routeMessage(message)

        // Check for decisions
        if message.type == .decision {
            let consensus = decisionStore.processDecision(
                content: message.content, from: message.from, atSeq: message.seq ?? 0
            )
            if consensus {
                refreshDecisions()
                let confirmMsg = createMessage(
                    from: .user, to: "all", type: .system,
                    content: "Decision recorded: \(message.content.prefix(80))...",
                    source: .ui
                )
                appendAndRoute(confirmMsg)
            }
        }
        decisionStore.expireOldProposals(currentSeq: message.seq ?? 0)

        // Check log rotation
        if let rotationMsg = chatLog.rotateIfNeeded(
            sessionId: currentSession?.sessionId ?? "",
            currentSeq: message.seq ?? 0
        ) {
            appendAndRoute(rotationMsg)
        }
    }

    private var lastPingTime: [Participant.Name: Date] = [:]

    private func routeMessage(_ message: TeamMessage) {
        // Never route bridge responses to other bridges — prevents GPT↔Codex ping-pong loops.
        // Bridge responses only go to UI (automatic via @Published) and file IPC agents (Claude).
        let fromBridge = message.source == .bridge

        let targets: [Participant.Name]

        if message.to == "all" {
            targets = Participant.Name.allCases.filter { $0 != message.from }
        } else if let name = Participant.Name(rawValue: message.to) {
            targets = [name]
        } else {
            return
        }

        // Update sender's heartbeat if agent is active but not explicitly updating
        if message.from != .user {
            participantManager.updateHeartbeat(message.from)
        }

        for target in targets {
            guard participantEnabled[target] == true else { continue }

            switch target {
            case .gpt:
                if !fromBridge { enqueueBridgeMessage(message, bridgeKey: "gpt") }
            case .codex:
                if !fromBridge { enqueueBridgeMessage(message, bridgeKey: "codex") }
            case .claude:
                // Claude uses file IPC — always ping
                if participantManager.touchPing(for: target) {
                    let pingPath = TeamsPaths.root
                        .appendingPathComponent("inbox", isDirectory: true)
                        .appendingPathComponent(target.rawValue, isDirectory: true)
                        .appendingPathComponent("ping")
                    TeamsLog.log("Touched ping for \(target.rawValue) at \(pingPath.resolvingSymlinksInPath().path)")
                }
            case .user:
                break // already updated via @Published messages
            }
        }
    }

    // MARK: - Bridge Dispatch

    private func participantNameForBridge(_ key: String) -> Participant.Name? {
        switch key {
        case "gpt": return .gpt
        case "codex": return .codex
        default: return nil
        }
    }

    private func enqueueBridgeMessage(_ message: TeamMessage, bridgeKey: String) {
        guard sessionActive else { return }
        if bridgeDisabled[bridgeKey] == true {
            TeamsLog.log("\(bridgeKey) bridge disabled, skipping message")
            return
        }
        bridgeQueues[bridgeKey, default: []].append(message)
        processBridgeQueue(bridgeKey: bridgeKey)
    }

    private func processBridgeQueue(bridgeKey: String) {
        guard bridgeProcessing[bridgeKey] != true,
              let message = bridgeQueues[bridgeKey]?.first else { return }
        bridgeProcessing[bridgeKey] = true
        bridgeQueues[bridgeKey]?.removeFirst()

        if let name = participantNameForBridge(bridgeKey) {
            participantManager.setMode(name, mode: .sending)
            refreshParticipants()
        }

        Task { @MainActor in
            await sendToBridge(message, bridgeKey: bridgeKey)
            bridgeProcessing[bridgeKey] = false
            if let name = participantNameForBridge(bridgeKey) {
                participantManager.setMode(name, mode: .idle)
                refreshParticipants()
            }
            processBridgeQueue(bridgeKey: bridgeKey)
        }
    }

    private func sendToBridge(_ message: TeamMessage, bridgeKey: String) async {
        guard sessionActive else { return }
        guard let bridge = bridges[bridgeKey] else {
            TeamsLog.log("Unknown bridge key: \(bridgeKey)")
            return
        }

        let prefix = "\(message.from.displayName.uppercased()): "
        let fullText = prefix + message.content
        let participantName = participantNameForBridge(bridgeKey)

        do {
            _ = try bridge.findApp()

            if let name = participantName {
                participantManager.setMode(name, mode: .sending)
            }
            let startTime = Date()
            try bridge.sendMessage(fullText)

            if let name = participantName {
                participantManager.setMode(name, mode: .reading)
                refreshParticipants()
            }
            let responseText = try await bridge.waitForResponse(timeout: 120)
            let latency = Date().timeIntervalSince(startTime)

            if bridgeKey == "gpt" {
                await MainActor.run { debugInfo.lastGPTLatency = latency }
            }

            // Empty response = model had nothing to add — skip silently
            if responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TeamsLog.log("\(bridge.name) returned empty response — skipping")
                return
            }

            // Parse response: GPTResponseParser for ChatGPT, plain text for others
            let parsed: [GPTResponseParser.ParsedMessage]
            if bridgeKey == "gpt" {
                parsed = GPTResponseParser.parse(
                    response: responseText,
                    sessionId: currentSession?.sessionId ?? "",
                    replyToSeq: message.seq
                )
            } else {
                parsed = [GPTResponseParser.ParsedMessage(
                    to: "all", type: .chat, content: responseText, isDecision: false
                )]
            }

            let fromName = participantName ?? .gpt
            for p in parsed {
                let msg = createMessage(
                    from: fromName, to: p.to, type: p.type,
                    content: p.content, source: .bridge, replyTo: message.seq
                )
                appendAndRoute(msg)
            }

        } catch {
            TeamsLog.log("\(bridge.name) bridge error: \(error)")

            // Retry once
            do {
                _ = try bridge.findApp()
                try bridge.sendMessage(fullText)
                let responseText = try await bridge.waitForResponse(timeout: 120)

                let parsed: [GPTResponseParser.ParsedMessage]
                if bridgeKey == "gpt" {
                    parsed = GPTResponseParser.parse(
                        response: responseText,
                        sessionId: currentSession?.sessionId ?? "",
                        replyToSeq: message.seq
                    )
                } else {
                    parsed = [GPTResponseParser.ParsedMessage(
                        to: "all", type: .chat, content: responseText, isDecision: false
                    )]
                }

                let fromName = participantName ?? .gpt
                for p in parsed {
                    let msg = createMessage(
                        from: fromName, to: p.to, type: p.type,
                        content: p.content, source: .bridge, replyTo: message.seq
                    )
                    appendAndRoute(msg)
                }
            } catch {
                let errMsg = createMessage(
                    from: .user, to: "all", type: .system,
                    content: "\(bridge.name) bridge error: \(error.localizedDescription)",
                    source: .bridge
                )
                appendAndRoute(errMsg)
                if let name = participantName {
                    participantManager.setMode(name, mode: .silent)
                }

                if case BuckError.accessibilityDenied = error {
                    bridgeDisabled[bridgeKey] = true
                    bridgeQueues[bridgeKey]?.removeAll()
                    TeamsLog.log("\(bridge.name) disabled — AX permission denied.")
                }

                debugInfo.errors.append("\(bridge.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Staging watcher (agent messages)

    private func startStagingWatcher() {
        stagingWatcher = StagingWatcher { [weak self] staging in
            guard let self else { return }
            Task { @MainActor in
                self.handleStagingMessage(staging)
            }
        }
    }

    private func handleStagingMessage(_ staging: StagingMessage) {
        // Auto-detect externally created sessions
        if !sessionActive {
            if let session = sessionManager.readSession(), session.active {
                currentSession = session
                sessionActive = true
                systemPrompt = session.systemPrompt
                loadMessages(session.sessionId)
                participantManager.setOnline(.user, sessionId: session.sessionId)
                refreshParticipants()
                TeamsLog.log("Auto-detected external session: \(session.sessionId)")
            } else {
                TeamsLog.log("No active session, ignoring staging message")
                return
            }
        }

        guard staging.sessionId == currentSession?.sessionId else {
            TeamsLog.log("Ignoring staging message from wrong session: \(staging.sessionId)")
            return
        }

        // Rate limiting
        let now = Date()
        let key = staging.from.rawValue
        if let last = lastRateLimit[key], now.timeIntervalSince(last) < 2.0 {
            TeamsLog.log("Rate limited: \(key)")
            return
        }
        lastRateLimit[key] = now

        // Mark agent as participating
        participantManager.setMode(staging.from, mode: .participating)
        refreshParticipants()

        let msg = createMessage(
            from: staging.from,
            to: staging.to,
            type: staging.type,
            content: staging.content,
            priority: staging.priority,
            source: staging.source,
            replyTo: staging.replyTo
        )
        appendAndRoute(msg)
    }

    // MARK: - Timers

    private var sessionCheckTimer: Timer?

    private func startTimers() {
        // Heartbeat check every 10s
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.participantManager.checkHeartbeats()
                self?.refreshParticipants()
            }
        }

        // Poll for new staging messages every 2s (fallback)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stagingWatcher?.checkForNewFiles()
            }
        }

        // Session state check every 3s (detect external session changes)
        sessionCheckTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkExternalSessionState()
            }
        }
    }

    private func stopTimers() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        sessionCheckTimer?.invalidate()
        sessionCheckTimer = nil
    }

    private func checkExternalSessionState() {
        if let session = sessionManager.readSession() {
            if session.active && !sessionActive {
                // External session started
                currentSession = session
                sessionActive = true
                systemPrompt = session.systemPrompt
                loadMessages(session.sessionId)
                participantManager.setOnline(.user, sessionId: session.sessionId)
                refreshParticipants()
                refreshDecisions()
                TeamsLog.log("Detected external session start: \(session.sessionId)")
            } else if !session.active && sessionActive {
                // External session ended
                sessionActive = false
                currentSession = nil
                refreshParticipants()
                TeamsLog.log("Detected external session end")
            }
        }

        // Refresh participants and decisions if active
        if sessionActive {
            refreshParticipants()
            refreshDecisions()
        }
    }

    // MARK: - Refresh

    func refreshParticipants() {
        participants = participantManager.readAll()
    }

    func refreshDecisions() {
        decisionsText = decisionStore.readDecisions()
    }

    private func loadMessages(_ sessionId: String) {
        messages = chatLog.readSession(sessionId)
        for msg in messages {
            routedMessageIds.insert(msg.id)
        }
        if let lastSeq = messages.last?.seq {
            debugInfo.currentSeq = lastSeq
        }
    }
}
