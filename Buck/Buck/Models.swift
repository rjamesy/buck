import Foundation

struct ReviewRequest: Codable {
    let id: String
    let timestamp: String?
    let type: String?
    let promptPrefix: String
    let content: String
    let maxRounds: Int?
    let sessionId: String?
    let channel: String?
    let caller: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, type, content, channel, caller
        case promptPrefix = "prompt_prefix"
        case maxRounds = "max_rounds"
        case sessionId = "session_id"
    }
}

struct ReviewResponse: Codable {
    let id: String
    let timestamp: String
    let status: ResponseStatus
    let response: String
    let round: Int

    enum ResponseStatus: String, Codable {
        case feedback
        case approved
        case error
    }
}
