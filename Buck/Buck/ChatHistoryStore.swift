import Foundation
import SQLite3

/// SQLite-backed store for chat session history.
/// Uses macOS C SQLite library — no SPM dependencies.
final class ChatHistoryStore {
    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.buck.historystore", qos: .utility)

    init() {
        let buckDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck")
        try? FileManager.default.createDirectory(at: buckDir, withIntermediateDirectories: true)
        dbPath = buckDir.appendingPathComponent("history.db").path
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
            NSLog("[Buck] Failed to open history database at %@", dbPath)
            db = nil
        }
        // Enable WAL mode for better concurrent read/write performance
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA foreign_keys=ON")
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS claude_sessions (
                id TEXT PRIMARY KEY,
                started_at TEXT NOT NULL,
                last_active_at TEXT NOT NULL,
                summary TEXT DEFAULT '',
                total_turns INTEGER DEFAULT 0,
                is_active INTEGER DEFAULT 1
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS gpt_sessions (
                id TEXT PRIMARY KEY,
                claude_session_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                turn_count INTEGER DEFAULT 0,
                is_current INTEGER DEFAULT 1,
                FOREIGN KEY (claude_session_id) REFERENCES claude_sessions(id)
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                gpt_session_id TEXT NOT NULL,
                turn_number INTEGER NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
                content TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                latency_ms INTEGER,
                FOREIGN KEY (gpt_session_id) REFERENCES gpt_sessions(id)
            )
        """)

        // Indexes for common queries
        exec("CREATE INDEX IF NOT EXISTS idx_gpt_sessions_claude ON gpt_sessions(claude_session_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_messages_gpt_session ON messages(gpt_session_id)")
    }

    // MARK: - Claude Sessions

    /// Get or create a claude_session by ID. Returns the session ID.
    func getOrCreateClaudeSession(id: String) -> String {
        var result = id
        queue.sync {
            let now = Self.isoTimestamp()

            // Check if exists
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM claude_sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    // Exists — update last_active_at
                    sqlite3_finalize(stmt)
                    exec("UPDATE claude_sessions SET last_active_at = '\(now)', is_active = 1 WHERE id = '\(escapeSql(id))'")
                    return
                }
            }
            sqlite3_finalize(stmt)

            // Create new
            var insertStmt: OpaquePointer?
            let sql = "INSERT INTO claude_sessions (id, started_at, last_active_at, summary, total_turns, is_active) VALUES (?, ?, ?, '', 0, 1)"
            if sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insertStmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 2, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 3, (now as NSString).utf8String, -1, nil)
                sqlite3_step(insertStmt)
            }
            sqlite3_finalize(insertStmt)
            result = id
        }
        return result
    }

    /// Get summary for a claude session
    func getSummary(forClaudeSession sessionId: String) -> String {
        var summary = ""
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT summary FROM claude_sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
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

    /// Update summary for a claude session
    func updateSummary(forClaudeSession sessionId: String, summary: String) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE claude_sessions SET summary = ?, last_active_at = ? WHERE id = ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (summary as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (Self.isoTimestamp() as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (sessionId as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Increment total_turns for a claude session
    func incrementTurns(forClaudeSession sessionId: String) {
        queue.sync {
            exec("UPDATE claude_sessions SET total_turns = total_turns + 1, last_active_at = '\(Self.isoTimestamp())' WHERE id = '\(escapeSql(sessionId))'")
        }
    }

    /// Get total turns for a claude session
    func getTotalTurns(forClaudeSession sessionId: String) -> Int {
        var turns = 0
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT total_turns FROM claude_sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    turns = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
        }
        return turns
    }

    // MARK: - GPT Sessions

    /// Get or create the current gpt_session for a claude session
    func getCurrentGPTSession(forClaudeSession claudeSessionId: String) -> String {
        var gptSessionId = ""
        queue.sync {
            // Find current
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM gpt_sessions WHERE claude_session_id = ? AND is_current = 1", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (claudeSessionId as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        gptSessionId = String(cString: cStr)
                    }
                }
            }
            sqlite3_finalize(stmt)

            if !gptSessionId.isEmpty { return }

            // Create new
            gptSessionId = UUID().uuidString.lowercased()
            let now = Self.isoTimestamp()
            var insertStmt: OpaquePointer?
            let sql = "INSERT INTO gpt_sessions (id, claude_session_id, started_at, turn_count, is_current) VALUES (?, ?, ?, 0, 1)"
            if sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insertStmt, 1, (gptSessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 2, (claudeSessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 3, (now as NSString).utf8String, -1, nil)
                sqlite3_step(insertStmt)
            }
            sqlite3_finalize(insertStmt)
        }
        return gptSessionId
    }

    /// Archive the current gpt_session and create a new one (for compaction)
    func rotateGPTSession(forClaudeSession claudeSessionId: String) -> String {
        var newId = ""
        queue.sync {
            let now = Self.isoTimestamp()
            // Archive current
            exec("UPDATE gpt_sessions SET is_current = 0, ended_at = '\(now)' WHERE claude_session_id = '\(escapeSql(claudeSessionId))' AND is_current = 1")

            // Create new
            newId = UUID().uuidString.lowercased()
            var stmt: OpaquePointer?
            let sql = "INSERT INTO gpt_sessions (id, claude_session_id, started_at, turn_count, is_current) VALUES (?, ?, ?, 0, 1)"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (newId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (claudeSessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        return newId
    }

    /// Increment turn count for a gpt session
    func incrementGPTTurnCount(gptSessionId: String) {
        queue.sync {
            exec("UPDATE gpt_sessions SET turn_count = turn_count + 1 WHERE id = '\(escapeSql(gptSessionId))'")
        }
    }

    /// Get turn count for a gpt session
    func getGPTTurnCount(gptSessionId: String) -> Int {
        var count = 0
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT turn_count FROM gpt_sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (gptSessionId as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
        }
        return count
    }

    // MARK: - Messages

    /// Record a message (user or assistant)
    func recordMessage(gptSessionId: String, turnNumber: Int, role: String, content: String, latencyMs: Int? = nil) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO messages (gpt_session_id, turn_number, role, content, timestamp, latency_ms) VALUES (?, ?, ?, ?, ?, ?)"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (gptSessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(turnNumber))
                sqlite3_bind_text(stmt, 3, (role as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (content as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (Self.isoTimestamp() as NSString).utf8String, -1, nil)
                if let latency = latencyMs {
                    sqlite3_bind_int(stmt, 6, Int32(latency))
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Get recent assistant latencies for a gpt session (last N)
    func getRecentLatencies(gptSessionId: String, limit: Int = 5) -> [Int] {
        var latencies: [Int] = []
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT latency_ms FROM messages WHERE gpt_session_id = ? AND role = 'assistant' AND latency_ms IS NOT NULL ORDER BY id DESC LIMIT ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (gptSessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    latencies.append(Int(sqlite3_column_int(stmt, 0)))
                }
            }
            sqlite3_finalize(stmt)
        }
        return latencies.reversed() // oldest first
    }

    /// Get the last N messages for a gpt session (for summarization)
    func getRecentMessages(gptSessionId: String, limit: Int = 2) -> [(role: String, content: String)] {
        var messages: [(String, String)] = []
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT role, content FROM messages WHERE gpt_session_id = ? ORDER BY id DESC LIMIT ?"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (gptSessionId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let role = String(cString: sqlite3_column_text(stmt, 0))
                    let content = String(cString: sqlite3_column_text(stmt, 1))
                    messages.append((role, content))
                }
            }
            sqlite3_finalize(stmt)
        }
        return messages.reversed() // oldest first
    }

    // MARK: - Cleanup

    /// Clean up old inactive sessions (>7 days). Call on startup and periodically.
    func cleanupOldSessions() {
        queue.sync {
            let cutoffDate = Date().addingTimeInterval(-7 * 24 * 3600)
            let cutoff = Self.isoTimestamp(cutoffDate)

            // Mark sessions inactive if no activity for 24h
            let inactiveCutoff = Self.isoTimestamp(Date().addingTimeInterval(-24 * 3600))
            exec("UPDATE claude_sessions SET is_active = 0 WHERE last_active_at < '\(inactiveCutoff)' AND is_active = 1")

            // Delete old inactive sessions and their data
            exec("""
                DELETE FROM messages WHERE gpt_session_id IN (
                    SELECT gs.id FROM gpt_sessions gs
                    JOIN claude_sessions cs ON gs.claude_session_id = cs.id
                    WHERE cs.is_active = 0 AND cs.last_active_at < '\(cutoff)'
                )
            """)
            exec("""
                DELETE FROM gpt_sessions WHERE claude_session_id IN (
                    SELECT id FROM claude_sessions WHERE is_active = 0 AND last_active_at < '\(cutoff)'
                )
            """)
            exec("DELETE FROM claude_sessions WHERE is_active = 0 AND last_active_at < '\(cutoff)'")

            NSLog("[Buck] Session cleanup complete")
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db = db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                NSLog("[Buck] SQL error: %@ — %@", sql.prefix(100).description, String(cString: errMsg))
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
