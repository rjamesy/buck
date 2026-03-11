import Foundation

struct ReviewRequest: Codable {
    let id: String
    let timestamp: String?
    let type: String?
    let promptPrefix: String
    let content: String
    let maxRounds: Int?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, type, content
        case promptPrefix = "prompt_prefix"
        case maxRounds = "max_rounds"
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
