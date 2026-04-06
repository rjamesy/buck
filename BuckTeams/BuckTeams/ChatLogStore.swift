import Foundation

final class ChatLogStore {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    private let maxLogSize: UInt64 = 10 * 1024 * 1024 // 10MB

    // MARK: - Append (coordinator only)

    /// Append a message to chat.jsonl under flock. Assigns seq from session.
    func append(_ message: TeamMessage) throws {
        let data = try encoder.encode(message)
        guard var line = String(data: data, encoding: .utf8) else {
            throw TeamsError.encodingFailed
        }
        line += "\n"

        let path = TeamsPaths.chatLog.path
        let lockPath = TeamsPaths.chatLock.path

        // Create files if they don't exist
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }

        // flock-based append
        let lockFd = open(lockPath, O_RDWR)
        guard lockFd >= 0 else { throw TeamsError.lockFailed }
        defer { close(lockFd) }

        var attempts = 0
        var delay: useconds_t = 100_000 // 100ms
        while flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
            attempts += 1
            if attempts >= 3 {
                TeamsLog.log("ChatLogStore: flock failed after 3 attempts")
                throw TeamsError.lockFailed
            }
            usleep(delay)
            delay *= 2
        }
        defer { flock(lockFd, LOCK_UN) }

        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw TeamsError.writeFailed }
        defer { close(fd) }

        line.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }

    // MARK: - Read

    /// Read all messages from chat.jsonl
    func readAll() -> [TeamMessage] {
        guard let data = try? Data(contentsOf: TeamsPaths.chatLog) else { return [] }
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        return parseLines(content)
    }

    /// Read messages since a given seq number
    func readSince(seq: Int) -> [TeamMessage] {
        return readAll().filter { ($0.seq ?? 0) > seq }
    }

    /// Read messages for a specific session
    func readSession(_ sessionId: String) -> [TeamMessage] {
        return readAll().filter { $0.sessionId == sessionId }
    }

    // MARK: - Rotation

    /// Check if log needs rotation and rotate if so. Returns system message if rotated.
    /// Must hold flock during rotation to prevent writes during rename.
    func rotateIfNeeded(sessionId: String, currentSeq: Int) -> TeamMessage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: TeamsPaths.chatLog.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else {
            return nil
        }

        let lockPath = TeamsPaths.chatLock.path
        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }
        let lockFd = open(lockPath, O_RDWR)
        guard lockFd >= 0 else { return nil }
        guard flock(lockFd, LOCK_EX) == 0 else { close(lockFd); return nil }
        defer { flock(lockFd, LOCK_UN); close(lockFd) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let archiveName = "chat.\(timestamp.replacingOccurrences(of: ":", with: "-")).jsonl"
        let archiveURL = TeamsPaths.root.appendingPathComponent(archiveName)

        do {
            try FileManager.default.moveItem(at: TeamsPaths.chatLog, to: archiveURL)
            FileManager.default.createFile(atPath: TeamsPaths.chatLog.path, contents: nil)

            // Clean old archives (keep last 2)
            cleanOldArchives()

            TeamsLog.log("ChatLogStore: rotated to \(archiveName)")

            return TeamMessage(
                id: "msg_\(UUID().uuidString)",
                seq: currentSeq,
                sessionId: sessionId,
                timestamp: timestamp,
                from: .user, // system messages use a special "from"
                to: "all",
                type: .system,
                content: "Log rotated. New file: \(TeamsPaths.chatLog.path). Archive: \(archiveName)",
                priority: .normal,
                source: .ui,
                replyTo: nil
            )
        } catch {
            TeamsLog.log("ChatLogStore: rotation failed: \(error)")
            return nil
        }
    }

    private func cleanOldArchives() {
        let root = TeamsPaths.root
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let archives = contents
            .filter { $0.lastPathComponent.hasPrefix("chat.") && $0.pathExtension == "jsonl" && $0.lastPathComponent != "chat.jsonl" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return dateA > dateB
            }

        // Keep last 2
        for archive in archives.dropFirst(2) {
            try? FileManager.default.removeItem(at: archive)
            TeamsLog.log("ChatLogStore: deleted old archive \(archive.lastPathComponent)")
        }
    }

    // MARK: - Parse

    private func parseLines(_ content: String) -> [TeamMessage] {
        var messages: [TeamMessage] = []
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let msg = try decoder.decode(TeamMessage.self, from: data)
                messages.append(msg)
            } catch {
                TeamsLog.log("ChatLogStore: skipping malformed line: \(error)")
            }
        }
        return messages
    }
}

// MARK: - Errors

enum TeamsError: LocalizedError {
    case encodingFailed
    case lockFailed
    case writeFailed
    case noActiveSession
    case sessionAlreadyActive
    case participantNotFound
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode message"
        case .lockFailed: return "Could not acquire file lock"
        case .writeFailed: return "Could not write to chat log"
        case .noActiveSession: return "No active Teams session"
        case .sessionAlreadyActive: return "A session is already active"
        case .participantNotFound: return "Participant not found"
        case .rateLimited: return "Rate limited — max 1 message per 2 seconds"
        }
    }
}

// MARK: - Logging

enum TeamsLog {
    static func log(_ msg: String) {
        let logFile = TeamsPaths.logs.appendingPathComponent("buckteams.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
        NSLog("[BuckTeams] %@", msg)
    }
}
