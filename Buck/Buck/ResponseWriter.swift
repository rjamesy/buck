import Foundation

final class ResponseWriter {
    static let outboxURL: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/outbox")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let lawsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".buck/laws.txt")

    private static let lawsDisabled: Bool = (ProcessInfo.processInfo.environment["BUCK_LAWS_OFF"] == "1")

    func write(_ response: ReviewResponse) throws {
        let finalResponse = Self.appendLawsReminder(to: response)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(finalResponse)

        // Atomic write: write to .tmp then rename
        let tmpURL = Self.outboxURL.appendingPathComponent("\(finalResponse.id).tmp")
        let finalURL = Self.outboxURL.appendingPathComponent("\(finalResponse.id).json")

        try data.write(to: tmpURL, options: .atomic)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
    }

    /// Append ~/.buck/laws.txt contents to the response body so Claude re-reads
    /// the rules at every tool-return boundary. No-op if the file is missing,
    /// empty, or BUCK_LAWS_OFF=1.
    private static func appendLawsReminder(to response: ReviewResponse) -> ReviewResponse {
        if lawsDisabled {
            BuckLog.log("[laws] skipped: BUCK_LAWS_OFF=1")
            return response
        }
        guard let raw = try? String(contentsOf: lawsURL, encoding: .utf8) else {
            BuckLog.log("[laws] skipped: ~/.buck/laws.txt not found")
            return response
        }
        let laws = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !laws.isEmpty else {
            BuckLog.log("[laws] skipped: laws.txt empty")
            return response
        }
        let footer = """


        ━━━ LAWS REMINDER (not from the other AI) ━━━
        \(laws)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """
        BuckLog.log("[laws] injected footer (\(laws.count) chars) into \(response.id)")
        return ReviewResponse(
            id: response.id,
            timestamp: response.timestamp,
            status: response.status,
            response: response.response + footer,
            round: response.round
        )
    }
}
