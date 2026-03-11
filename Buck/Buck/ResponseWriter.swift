import Foundation

final class ResponseWriter {
    static let outboxURL: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/outbox")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func write(_ response: ReviewResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)

        // Atomic write: write to .tmp then rename
        let tmpURL = Self.outboxURL.appendingPathComponent("\(response.id).tmp")
        let finalURL = Self.outboxURL.appendingPathComponent("\(response.id).json")

        try data.write(to: tmpURL, options: .atomic)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
    }
}
