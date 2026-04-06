import Foundation

final class SessionManager {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()
    private let seqLock = NSLock()

    static let defaultSystemPrompt = """
    You are an AI participating in a group chat session with other AIs and a human user. \
    Purpose: collaborative problem-solving. Rules: be concise, stay on topic, respect user priority. \
    Challenge ideas constructively. Goals: reach agreed decisions. The user is king — their instructions \
    override all. Agreed decisions go into the Decisions panel.

    Message format: Messages are prefixed with the sender's name (e.g., CLAUDE:, CODEX:, USER:).
    To address someone directly, use: {NAME} QUESTION: or {NAME} RESPONSE:
    To address everyone: ALL QUESTION: or ALL RESPONSE:
    To propose a decision: DECISION: {text}
    """

    // MARK: - Create

    func createSession(systemPrompt: String? = nil) throws -> TeamsSession {
        if let existing = readSession(), existing.active {
            throw TeamsError.sessionAlreadyActive
        }

        let session = TeamsSession(
            sessionId: UUID().uuidString,
            active: true,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            endedAt: nil,
            systemPrompt: systemPrompt ?? Self.defaultSystemPrompt,
            currentSeq: 0,
            participants: []
        )
        try writeSession(session)
        TeamsLog.log("Session created: \(session.sessionId)")
        return session
    }

    // MARK: - Read / Write

    func readSession() -> TeamsSession? {
        guard let data = try? Data(contentsOf: TeamsPaths.sessionFile) else { return nil }
        return try? decoder.decode(TeamsSession.self, from: data)
    }

    func writeSession(_ session: TeamsSession) throws {
        let data = try encoder.encode(session)
        let tmpURL = TeamsPaths.root.appendingPathComponent("session.tmp")
        try data.write(to: tmpURL, options: .atomic)
        try? FileManager.default.removeItem(at: TeamsPaths.sessionFile)
        try FileManager.default.moveItem(at: tmpURL, to: TeamsPaths.sessionFile)
    }

    // MARK: - Seq

    func nextSeq() throws -> Int {
        seqLock.lock()
        defer { seqLock.unlock() }
        guard var session = readSession(), session.active else {
            throw TeamsError.noActiveSession
        }
        session.currentSeq += 1
        try writeSession(session)
        return session.currentSeq
    }

    // MARK: - Participants

    func addParticipant(_ name: Participant.Name) throws {
        guard var session = readSession(), session.active else {
            throw TeamsError.noActiveSession
        }
        if !session.participants.contains(name.rawValue) {
            session.participants.append(name.rawValue)
            try writeSession(session)
        }
    }

    func removeParticipant(_ name: Participant.Name) throws {
        guard var session = readSession(), session.active else { return }
        session.participants.removeAll { $0 == name.rawValue }
        try writeSession(session)
    }

    // MARK: - End

    func endSession() throws {
        guard var session = readSession(), session.active else { return }
        session.active = false
        session.endedAt = ISO8601DateFormatter().string(from: Date())
        try writeSession(session)
        TeamsLog.log("Session ended: \(session.sessionId)")
    }

    // MARK: - Clean

    func cleanAll() {
        try? FileManager.default.removeItem(at: TeamsPaths.sessionFile)
        try? FileManager.default.removeItem(at: TeamsPaths.chatLog)
        try? FileManager.default.removeItem(at: TeamsPaths.decisionsFile)

        // Clean staging
        if let files = try? FileManager.default.contentsOfDirectory(at: TeamsPaths.staging, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }

        // Reset participants
        for name in Participant.Name.allCases {
            let p = Participant.initial(name)
            let data = try? encoder.encode(p)
            try? data?.write(to: TeamsPaths.participantFile(for: name))
        }

        // Clear pings
        for name in Participant.Name.allCases {
            try? FileManager.default.removeItem(at: TeamsPaths.pingFile(for: name))
        }

        TeamsLog.log("Session cleaned")
    }
}
