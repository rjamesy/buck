import Foundation

// MARK: - Team Message

struct TeamMessage: Codable, Identifiable, Equatable {
    let id: String
    var seq: Int?
    let sessionId: String
    let timestamp: String
    let from: Participant.Name
    let to: String // "all" or participant name
    let type: MessageType
    let content: String
    let priority: Priority
    let source: Source
    let replyTo: Int?

    enum MessageType: String, Codable {
        case chat, question, response, decision, system
    }

    enum Priority: String, Codable {
        case normal, high
    }

    enum Source: String, Codable {
        case ui, agent, bridge
    }

    enum CodingKeys: String, CodingKey {
        case id, seq, timestamp, from, to, type, content, priority, source
        case sessionId = "session_id"
        case replyTo = "reply_to"
    }

    static func == (lhs: TeamMessage, rhs: TeamMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Participant

struct Participant: Codable, Identifiable {
    enum Name: String, Codable, CaseIterable, Identifiable {
        case user, claude, codex, gpt
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .user: return "User"
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .gpt: return "GPT"
            }
        }
    }

    enum Mode: String, Codable {
        case idle         // green
        case participating // yellow
        case thinking     // orange
        case sending      // blue
        case waiting      // purple
        case reading      // red
        case silent       // grey
    }

    var id: String { name.rawValue }
    let name: Name
    var online: Bool
    var mode: Mode
    var sessionId: String?
    var lastSeenSeq: Int
    var heartbeat: String

    enum CodingKeys: String, CodingKey {
        case name, online, mode, heartbeat
        case sessionId = "session_id"
        case lastSeenSeq = "last_seen_seq"
    }

    static func initial(_ name: Name) -> Participant {
        Participant(
            name: name,
            online: name == .user,
            mode: .silent,
            sessionId: nil,
            lastSeenSeq: 0,
            heartbeat: ISO8601DateFormatter().string(from: Date())
        )
    }
}

// MARK: - Session

struct TeamsSession: Codable {
    let sessionId: String
    var active: Bool
    let createdAt: String
    var endedAt: String?
    let systemPrompt: String
    var currentSeq: Int
    var participants: [String]

    enum CodingKeys: String, CodingKey {
        case active, participants
        case sessionId = "session_id"
        case createdAt = "created_at"
        case endedAt = "ended_at"
        case systemPrompt = "system_prompt"
        case currentSeq = "current_seq"
    }
}

// MARK: - Decision Proposal

struct DecisionProposal {
    let contentHash: String
    let content: String
    let proposerSeq: Int
    let proposer: Participant.Name
    var agreements: Set<String> // participant names who agreed
    let createdAtSeq: Int
}

// MARK: - Staging Message (what agents write)

struct StagingMessage: Codable {
    let id: String
    let from: Participant.Name
    let to: String
    let type: TeamMessage.MessageType
    let content: String
    let priority: TeamMessage.Priority
    let source: TeamMessage.Source
    let replyTo: Int?
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case id, from, to, type, content, priority, source
        case replyTo = "reply_to"
        case sessionId = "session_id"
    }
}

// MARK: - Paths

enum TeamsPaths {
    static let root: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".buckteams")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var chatLog: URL { root.appendingPathComponent("chat.jsonl") }
    static var chatLock: URL { root.appendingPathComponent("chat.jsonl.lock") }
    static var decisionsFile: URL { root.appendingPathComponent("decisions.md") }
    static var sessionFile: URL { root.appendingPathComponent("session.json") }
    static var staging: URL {
        let url = root.appendingPathComponent("staging")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var participants: URL {
        let url = root.appendingPathComponent("participants")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var logs: URL {
        let url = root.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func inbox(for name: Participant.Name) -> URL {
        let url = root.appendingPathComponent("inbox/\(name.rawValue)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func participantFile(for name: Participant.Name) -> URL {
        participants.appendingPathComponent("\(name.rawValue).json")
    }

    static func pingFile(for name: Participant.Name) -> URL {
        inbox(for: name).appendingPathComponent("ping")
    }
}
