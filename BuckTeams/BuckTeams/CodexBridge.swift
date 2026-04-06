import Foundation

/// Bridge that calls the OpenAI Responses API directly (no desktop app needed).
final class CodexBridge: BridgeProtocol {
    let name = "Codex"

    private var apiKey: String = ""
    private var model: String = "gpt-5.3-codex"
    private var pendingMessage: String = ""
    private var lastResponseId: String?

    // MARK: - Config

    private struct CodexConfig: Codable {
        let apiKey: String?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case model
        }
    }

    init(model override: String? = nil) {
        loadConfig()
        if let m = override { model = m }
    }

    private func loadConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buckteams/codex-config.json")

        if let data = try? Data(contentsOf: configPath),
           let config = try? JSONDecoder().decode(CodexConfig.self, from: data) {
            if let key = config.apiKey, !key.isEmpty {
                apiKey = key
            }
            if let m = config.model, !m.isEmpty {
                model = m
            }
            BuckLog.log("[CodexBridge] Config loaded (model: \(model))")
        } else {
            BuckLog.log("[CodexBridge] No config at \(configPath.path), will try env var")
        }

        // Fallback to environment variable
        if apiKey.isEmpty,
           let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !envKey.isEmpty {
            apiKey = envKey
            BuckLog.log("[CodexBridge] Using OPENAI_API_KEY from environment")
        }
    }

    // MARK: - BridgeProtocol

    func findApp() throws -> Bool {
        if apiKey.isEmpty {
            throw CodexBridgeError.noAPIKey
        }
        return true
    }

    func sendMessage(_ text: String) throws {
        pendingMessage = text
    }

    func waitForResponse(timeout: TimeInterval) async throws -> String {
        guard !pendingMessage.isEmpty else {
            throw CodexBridgeError.noMessage
        }
        let prompt = pendingMessage
        pendingMessage = ""

        BuckLog.log("[CodexBridge] Calling API (model: \(model), prompt length: \(prompt.count))")

        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var body: [String: Any] = ["model": model, "input": prompt]
        if let prevId = lastResponseId {
            body["previous_response_id"] = prevId
            BuckLog.log("[CodexBridge] Continuing conversation (previous: \(prevId))")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw BridgeError.timeout
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawBody = String(data: data, encoding: .utf8)

        if statusCode >= 400 {
            if let errResp = try? JSONDecoder().decode(CodexAPIResponse.self, from: data),
               let err = errResp.error {
                throw CodexBridgeError.apiError(classifyError(statusCode: statusCode, error: err))
            }
            throw CodexBridgeError.apiError("HTTP \(statusCode): \(rawBody ?? "Unknown error")")
        }

        let apiResponse = try JSONDecoder().decode(CodexAPIResponse.self, from: data)

        if let err = apiResponse.error {
            throw CodexBridgeError.apiError(classifyError(statusCode: statusCode, error: err))
        }

        // Store response ID for conversation continuity
        lastResponseId = apiResponse.id

        let text = extractText(from: apiResponse)

        BuckLog.log("[CodexBridge] Response received (\(text.count) chars, id: \(apiResponse.id ?? "nil"))")
        return text
    }

    func startNewChat() {
        lastResponseId = nil
        BuckLog.log("[CodexBridge] New chat — cleared conversation state")
    }

    // MARK: - Response Parsing

    private func extractText(from response: CodexAPIResponse) -> String {
        guard let output = response.output else { return "" }
        return output
            .filter { $0.role == "assistant" && $0.type == "message" }
            .compactMap { item -> String? in
                item.content?
                    .filter { $0.type == "output_text" }
                    .compactMap { $0.text }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    private func classifyError(statusCode: Int, error: CodexAPIErrorDetail) -> String {
        let type = error.type ?? ""
        let message = error.message ?? "Unknown error"

        if statusCode == 401 || type.contains("auth") || type.contains("invalid_api_key") {
            return "Auth error: \(message). Check api_key in ~/.buckteams/codex-config.json"
        } else if statusCode == 429 || type.contains("rate_limit") || type.contains("insufficient_quota") {
            return "Rate limit: \(message)"
        } else if statusCode == 402 || type.contains("billing") {
            return "Billing error: \(message)"
        }
        return "API error [\(type)]: \(message)"
    }
}

// MARK: - Errors

enum CodexBridgeError: LocalizedError {
    case noAPIKey
    case noMessage
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No OpenAI API key. Set api_key in ~/.buckteams/codex-config.json or OPENAI_API_KEY env var."
        case .noMessage:
            return "No message to send (sendMessage not called)"
        case .apiError(let detail):
            return detail
        }
    }
}

// MARK: - API Response Models (scoped to avoid collision with BuckCodex)

private struct CodexAPIResponse: Codable {
    let id: String?
    let output: [CodexOutputItem]?
    let error: CodexAPIErrorDetail?
}

private struct CodexOutputItem: Codable {
    let type: String?
    let role: String?
    let content: [CodexOutputContent]?
}

private struct CodexOutputContent: Codable {
    let type: String?
    let text: String?
}

private struct CodexAPIErrorDetail: Codable {
    let type: String?
    let message: String?
}
