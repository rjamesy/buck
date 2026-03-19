import Foundation

struct BuckSpeakRequest: Codable {
    let id: String
    let arguments: [String]
    let stdinText: String?
}

struct BuckSpeakResponse: Codable {
    let status: String
    let mode: String
    let spoken_text: String?
    let heard_text: String?
    let speech_started_ms: Int?
    let speech_ended_ms: Int?
    let duration_ms: Int
    let error: String?
    let requested_voice: String?
    let resolved_voice: String?
    let resolved_voice_id: String?
}

enum BuckSpeakIPC {
    static let rootURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".buckspeak", isDirectory: true)
    static let inboxURL = rootURL.appendingPathComponent("inbox", isDirectory: true)
    static let outboxURL = rootURL.appendingPathComponent("outbox", isDirectory: true)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
    }

    static func requestURL(for id: String) -> URL {
        inboxURL.appendingPathComponent("\(id).json")
    }

    static func responseURL(for id: String) -> URL {
        outboxURL.appendingPathComponent("\(id).json")
    }

    static func pendingRequestURLs() throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .sorted {
                let lhs = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                let rhs = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                return lhs < rhs
            }
    }

    static func readRequest(at url: URL) throws -> BuckSpeakRequest {
        let data = try Data(contentsOf: url)
        return try decoder.decode(BuckSpeakRequest.self, from: data)
    }

    static func writeResponse(_ response: BuckSpeakResponse, id: String) throws {
        let finalURL = responseURL(for: id)
        let tempURL = finalURL.appendingPathExtension("tmp")
        let data = try encoder.encode(response)
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }
}
