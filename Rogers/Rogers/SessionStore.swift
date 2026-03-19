import Foundation
import SQLite3

final class SessionStore {
    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.rogers.sessionstore", qos: .utility)

    init() {
        let rogersDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rogers")
        try? FileManager.default.createDirectory(at: rogersDir, withIntermediateDirectories: true)
        dbPath = rogersDir.appendingPathComponent("history.db").path
        openDatabase()
        createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            NSLog("[Rogers] Failed to open database at %@", dbPath)
            db = nil
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA foreign_keys=ON")
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                thread_title TEXT NOT NULL,
                gpt_name TEXT DEFAULT '',
                first_seen_at TEXT NOT NULL,
                last_polled_at TEXT NOT NULL,
                turn_count INTEGER DEFAULT 0,
                is_active INTEGER DEFAULT 0,
                is_compacted INTEGER DEFAULT 0,
                compacted_into_session_id TEXT DEFAULT NULL,
                compaction_verified_at TEXT DEFAULT NULL,
                sidebar_name TEXT DEFAULT '',
                summary TEXT DEFAULT ''
            )
        """)

        // Migration: add sidebar_name if missing (for existing DBs)
        exec("ALTER TABLE sessions ADD COLUMN sidebar_name TEXT DEFAULT ''")
        // Ignore error if column already exists

        exec("""
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                turn_number INTEGER NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'unknown')),
                content TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            )
        """)

        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_message_dedup ON messages(session_id, content_hash)")
        exec("CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_messages_order ON messages(session_id, turn_number)")

        exec("""
            CREATE TABLE IF NOT EXISTS session_fingerprints (
                session_id TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                position TEXT NOT NULL CHECK(position IN ('head', 'tail')),
                PRIMARY KEY (session_id, content_hash),
                FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            )
        """)
    }

    // MARK: - Sessions

    func createSession(threadTitle: String, gptName: String) -> String {
        let id = UUID().uuidString.lowercased()
        queue.sync {
            let now = Self.isoTimestamp()
            var stmt: OpaquePointer?
            let sql = """
                INSERT INTO sessions (id, thread_title, gpt_name, first_seen_at, last_polled_at, turn_count, is_active)
                VALUES (?, ?, ?, ?, ?, 0, 1)
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (threadTitle as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (gptName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (now as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        return id
    }

    func getAllSessions() -> [SessionInfo] {
        var sessions: [SessionInfo] = []
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT id, thread_title, gpt_name, turn_count, is_active, is_compacted, last_polled_at FROM sessions WHERE is_compacted = 0 ORDER BY last_polled_at DESC"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let title = String(cString: sqlite3_column_text(stmt, 1))
                    let gptName = String(cString: sqlite3_column_text(stmt, 2))
                    let turnCount = Int(sqlite3_column_int(stmt, 3))
                    let isActive = sqlite3_column_int(stmt, 4) == 1
                    let isCompacted = sqlite3_column_int(stmt, 5) == 1
                    let lastPolledStr = String(cString: sqlite3_column_text(stmt, 6))
                    let lastPolled = ISO8601DateFormatter().date(from: lastPolledStr) ?? Date()
                    sessions.append(SessionInfo(
                        id: id, threadTitle: title, gptName: gptName,
                        turnCount: turnCount, isActive: isActive,
                        isCompacted: isCompacted, lastPolledAt: lastPolled
                    ))
                }
            }
            sqlite3_finalize(stmt)
        }
        return sessions
    }

    func getActiveSession() -> SessionInfo? {
        return getAllSessions().first { $0.isActive }
    }

    func setActiveSession(id: String) {
        queue.sync {
            let now = Self.isoTimestamp()
            exec("UPDATE sessions SET is_active = 0 WHERE is_active = 1")
            exec("UPDATE sessions SET is_active = 1, last_polled_at = '\(escapeSql(now))' WHERE id = '\(escapeSql(id))'")
        }
    }

    func clearActiveFlags() {
        queue.sync {
            exec("UPDATE sessions SET is_active = 0 WHERE is_active = 1")
        }
    }

    func updateSessionTitle(id: String, title: String, gptName: String) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE sessions SET thread_title = ?, gpt_name = ?, last_polled_at = ? WHERE id = ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (gptName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (Self.isoTimestamp() as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func updateSidebarName(id: String, sidebarName: String) {
        // Never overwrite a non-empty title with empty
        guard !sidebarName.isEmpty else { return }
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE sessions SET sidebar_name = ?, thread_title = ?, last_polled_at = ? WHERE id = ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sidebarName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (sidebarName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (Self.isoTimestamp() as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func getAllSessionTitles() -> [String: String] {
        var titles: [String: String] = [:]  // id → thread_title
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, thread_title FROM sessions WHERE is_compacted = 0", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let title = String(cString: sqlite3_column_text(stmt, 1))
                    titles[id] = title
                }
            }
            sqlite3_finalize(stmt)
        }
        return titles
    }

    func updateLastPolled(id: String) {
        queue.sync {
            exec("UPDATE sessions SET last_polled_at = '\(Self.isoTimestamp())' WHERE id = '\(escapeSql(id))'")
        }
    }

    func deleteSession(id: String) {
        queue.sync {
            exec("DELETE FROM session_fingerprints WHERE session_id = '\(escapeSql(id))'")
            exec("DELETE FROM messages WHERE session_id = '\(escapeSql(id))'")
            exec("DELETE FROM sessions WHERE id = '\(escapeSql(id))'")
        }
    }

    func markCompacted(id: String, intoSessionId: String) {
        queue.sync {
            let now = Self.isoTimestamp()
            var stmt: OpaquePointer?
            let sql = "UPDATE sessions SET is_compacted = 1, compacted_into_session_id = ?, compaction_verified_at = ?, is_active = 0 WHERE id = ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (intoSessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Messages

    /// Ingest messages, deduped by content hash. Returns count of newly inserted messages.
    func ingestMessages(sessionId: String, messages: [ThreadMessage]) -> Int {
        var newCount = 0
        queue.sync {
            let now = Self.isoTimestamp()

            // Get current max turn number
            var maxTurn = 0
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT MAX(turn_number) FROM messages WHERE session_id = ?", -1, &countStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(countStmt, 1, (sessionId as NSString).utf8String, -1, nil)
                if sqlite3_step(countStmt) == SQLITE_ROW {
                    maxTurn = Int(sqlite3_column_int(countStmt, 0))
                }
            }
            sqlite3_finalize(countStmt)

            for msg in messages {
                var stmt: OpaquePointer?
                let sql = "INSERT OR IGNORE INTO messages (session_id, turn_number, role, content, content_hash, timestamp) VALUES (?, ?, ?, ?, ?, ?)"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    maxTurn += 1
                    sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(stmt, 2, Int32(maxTurn))
                    sqlite3_bind_text(stmt, 3, (msg.role as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (msg.content as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 5, (msg.contentHash as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 6, (now as NSString).utf8String, -1, nil)
                    let result = sqlite3_step(stmt)
                    if result == SQLITE_DONE && sqlite3_changes(db) > 0 {
                        newCount += 1
                    } else {
                        maxTurn -= 1  // Hash already existed, don't advance turn number
                    }
                }
                sqlite3_finalize(stmt)
            }

            // Update turn count
            if newCount > 0 {
                exec("UPDATE sessions SET turn_count = (SELECT COUNT(*) FROM messages WHERE session_id = '\(escapeSql(sessionId))'), last_polled_at = '\(now)' WHERE id = '\(escapeSql(sessionId))'")
            }
        }

        // Update fingerprints outside the main queue sync
        if newCount > 0 {
            updateFingerprints(sessionId: sessionId)
        }

        return newCount
    }

    func getAllMessages(sessionId: String) -> [(role: String, content: String)] {
        var messages: [(String, String)] = []
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT role, content FROM messages WHERE session_id = ? ORDER BY turn_number ASC"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let role = String(cString: sqlite3_column_text(stmt, 0))
                    let content = String(cString: sqlite3_column_text(stmt, 1))
                    messages.append((role, content))
                }
            }
            sqlite3_finalize(stmt)
        }
        return messages
    }

    func getMessageCount(sessionId: String) -> Int {
        var count = 0
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages WHERE session_id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
        }
        return count
    }

    // MARK: - Summary

    func updateSummary(sessionId: String, summary: String) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE sessions SET summary = ? WHERE id = ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (summary as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func getSummary(sessionId: String) -> String {
        var summary = ""
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT summary FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        summary = String(cString: cStr)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return summary
    }

    // MARK: - Fingerprinting

    /// Find a session matching the given content hashes. Returns session ID if any hash matches.
    func findSessionByFingerprint(hashes: [String]) -> String? {
        guard !hashes.isEmpty else { return nil }
        var bestSessionId: String?
        var bestMatchCount = 0
        queue.sync {
            // First: check fingerprint table
            var stmt: OpaquePointer?
            let placeholders = hashes.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT session_id, COUNT(*) as matches FROM session_fingerprints WHERE content_hash IN (\(placeholders)) AND session_id IN (SELECT id FROM sessions WHERE is_compacted = 0) GROUP BY session_id ORDER BY matches DESC LIMIT 1"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (i, hash) in hashes.enumerated() {
                    sqlite3_bind_text(stmt, Int32(i + 1), (hash as NSString).utf8String, -1, nil)
                }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let sessionId = String(cString: sqlite3_column_text(stmt, 0))
                    let count = Int(sqlite3_column_int(stmt, 1))
                    if count >= 1 {
                        bestSessionId = sessionId
                        bestMatchCount = count
                    }
                }
            }
            sqlite3_finalize(stmt)

            // Fallback: check messages table directly (catches newly created sessions before fingerprint update)
            if bestSessionId == nil {
                let msgSql = "SELECT session_id, COUNT(*) as matches FROM messages WHERE content_hash IN (\(placeholders)) AND session_id IN (SELECT id FROM sessions WHERE is_compacted = 0) GROUP BY session_id ORDER BY matches DESC LIMIT 1"
                var msgStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, msgSql, -1, &msgStmt, nil) == SQLITE_OK {
                    for (i, hash) in hashes.enumerated() {
                        sqlite3_bind_text(msgStmt, Int32(i + 1), (hash as NSString).utf8String, -1, nil)
                    }
                    if sqlite3_step(msgStmt) == SQLITE_ROW {
                        let sessionId = String(cString: sqlite3_column_text(msgStmt, 0))
                        let count = Int(sqlite3_column_int(msgStmt, 1))
                        if count >= 1 {
                            bestSessionId = sessionId
                            bestMatchCount = count
                        }
                    }
                }
                sqlite3_finalize(msgStmt)
            }
        }
        if let id = bestSessionId {
            NSLog("[Rogers] Matched session %@ with %d hash overlaps", id.prefix(8).description, bestMatchCount)
        }
        return bestSessionId
    }

    /// Update fingerprints for a session: keep first 10 (head) + last 10 (tail) message hashes.
    private func updateFingerprints(sessionId: String) {
        queue.sync {
            // Clear existing
            exec("DELETE FROM session_fingerprints WHERE session_id = '\(escapeSql(sessionId))'")

            // Get first 10 hashes
            var stmt: OpaquePointer?
            var sql = "SELECT content_hash FROM messages WHERE session_id = ? ORDER BY turn_number ASC LIMIT 10"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let hash = String(cString: sqlite3_column_text(stmt, 0))
                    insertFingerprint(sessionId: sessionId, hash: hash, position: "head")
                }
            }
            sqlite3_finalize(stmt)

            // Get last 10 hashes
            sql = "SELECT content_hash FROM messages WHERE session_id = ? ORDER BY turn_number DESC LIMIT 10"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let hash = String(cString: sqlite3_column_text(stmt, 0))
                    insertFingerprint(sessionId: sessionId, hash: hash, position: "tail")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    private func insertFingerprint(sessionId: String, hash: String, position: String) {
        // Called within queue.sync — no additional synchronization needed
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO session_fingerprints (session_id, content_hash, position) VALUES (?, ?, ?)"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (hash as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (position as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db = db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                NSLog("[Rogers] SQL error: %@ — %@", sql.prefix(100).description, String(cString: errMsg))
                sqlite3_free(errMsg)
            }
        }
    }

    private func escapeSql(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    private static func isoTimestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
