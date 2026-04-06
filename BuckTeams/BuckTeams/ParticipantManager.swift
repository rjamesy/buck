import Foundation

final class ParticipantManager {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()
    private let heartbeatTimeout: TimeInterval = 30
    private let isoFormatter = ISO8601DateFormatter()

    // MARK: - Read / Write

    func read(_ name: Participant.Name) -> Participant {
        let url = TeamsPaths.participantFile(for: name)
        guard let data = try? Data(contentsOf: url),
              let p = try? decoder.decode(Participant.self, from: data) else {
            return Participant.initial(name)
        }
        return p
    }

    func write(_ participant: Participant) {
        let url = TeamsPaths.participantFile(for: participant.name)
        let tmpURL = url.deletingLastPathComponent().appendingPathComponent("\(participant.name.rawValue).tmp")
        guard let data = try? encoder.encode(participant) else { return }
        do {
            try data.write(to: tmpURL, options: .atomic)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmpURL, to: url)
        } catch {
            TeamsLog.log("ParticipantManager: failed to write \(participant.name): \(error)")
        }
    }

    func readAll() -> [Participant] {
        Participant.Name.allCases.map { read($0) }
    }

    // MARK: - Status updates

    func setOnline(_ name: Participant.Name, sessionId: String) {
        var p = read(name)
        p.online = true
        p.mode = .idle
        p.sessionId = sessionId
        p.heartbeat = isoFormatter.string(from: Date())
        write(p)
    }

    func setOffline(_ name: Participant.Name) {
        var p = read(name)
        p.online = false
        p.mode = .silent
        p.sessionId = nil
        write(p)
    }

    func setMode(_ name: Participant.Name, mode: Participant.Mode) {
        var p = read(name)
        p.mode = mode
        p.heartbeat = isoFormatter.string(from: Date())
        write(p)
    }

    func updateHeartbeat(_ name: Participant.Name) {
        var p = read(name)
        p.heartbeat = isoFormatter.string(from: Date())
        write(p)
    }

    func updateLastSeenSeq(_ name: Participant.Name, seq: Int) {
        var p = read(name)
        p.lastSeenSeq = seq
        p.heartbeat = isoFormatter.string(from: Date())
        write(p)
    }

    // MARK: - Heartbeat check

    func checkHeartbeats() {
        let now = Date()
        for name in Participant.Name.allCases {
            if name == .user { continue } // user doesn't need heartbeat
            var p = read(name)
            guard p.online else { continue }
            if let heartbeatDate = isoFormatter.date(from: p.heartbeat),
               now.timeIntervalSince(heartbeatDate) > heartbeatTimeout {
                p.mode = .silent
                write(p)
                TeamsLog.log("ParticipantManager: \(name) marked stale (heartbeat timeout)")
            }
        }
    }

    // MARK: - Wake signals

    @discardableResult
    func touchPing(for name: Participant.Name) -> Bool {
        let pingDir = TeamsPaths.root
            .appendingPathComponent("inbox", isDirectory: true)
            .appendingPathComponent(name.rawValue, isDirectory: true)
        let pingFile = pingDir.appendingPathComponent("ping")

        do {
            try FileManager.default.createDirectory(at: pingDir, withIntermediateDirectories: true)
        } catch {
            TeamsLog.log("touchPing createDirectory FAILED at \(pingDir.path): \(error)")
            return false
        }

        let timestamp = isoFormatter.string(from: Date())
        do {
            try timestamp.write(to: pingFile, atomically: false, encoding: .utf8)
        } catch {
            TeamsLog.log("touchPing write FAILED for \(name.rawValue) at \(pingFile.path): \(error)")
            return false
        }

        guard FileManager.default.fileExists(atPath: pingFile.path) else {
            TeamsLog.log("touchPing wrote but file missing at \(pingFile.path) (resolved: \(pingFile.resolvingSymlinksInPath().path))")
            return false
        }

        return true
    }
}
