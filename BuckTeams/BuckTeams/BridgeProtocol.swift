import Foundation

/// Common interface for AX bridges (ChatGPT, Cursor, etc.)
protocol BridgeProtocol: AnyObject {
    /// Display name for status and log messages
    var name: String { get }

    /// Locate and connect to the target app. Throws if not running or AX denied.
    func findApp() throws -> Bool

    /// Send a message to the target app's chat input.
    func sendMessage(_ text: String) throws

    /// Poll until the target app produces a response, or timeout.
    /// Throws `BridgeError.timeout` if no response within the deadline.
    func waitForResponse(timeout: TimeInterval) async throws -> String

    /// Open a new chat/thread in the target app.
    func startNewChat()
}

/// Errors shared across all bridges.
enum BridgeError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout: return "Timed out waiting for response"
        }
    }
}

/// Shared log sink for all BuckTeams bridge components. Writes to ~/.buckteams/logs/buckteams-bridges.log.
enum BuckLog {
    static func log(_ msg: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buckteams/logs/buckteams-bridges.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                // Ensure directory exists
                let dir = logFile.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: logFile)
            }
        }
    }
}
