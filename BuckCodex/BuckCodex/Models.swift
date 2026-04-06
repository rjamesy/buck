import Foundation

// MARK: - OpenAI Responses API Models

/// Response from POST /v1/responses
struct OpenAIResponse: Codable {
    let id: String?
    let object: String?
    let model: String?
    let output: [OutputItem]?
    let usage: APIUsage?
    let error: APIError?
}

struct OutputItem: Codable {
    let type: String?
    let id: String?
    let role: String?
    let content: [OutputContent]?
}

struct OutputContent: Codable {
    let type: String?
    let text: String?
}

struct APIUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
}

struct APIError: Codable {
    let type: String?
    let message: String?
}

// MARK: - App Models

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date
    var tokenInfo: String?

    enum Role: String {
        case user
        case assistant
        case system
        case error
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

struct ChatThread: Identifiable {
    let id = UUID()
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date

    init(title: String = "New Thread") {
        self.title = title
        self.messages = []
        self.createdAt = Date()
    }
}

// MARK: - Settings

struct CodexSettings {
    var apiKey: String
    var model: String
    var repoPath: String

    static var `default`: CodexSettings {
        CodexSettings(
            apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "",
            model: "gpt-5.4-mini",
            repoPath: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }
    var provider: String { "openai_api" }
    var baseURL: String { "https://api.openai.com/v1" }
}
