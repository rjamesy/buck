import Foundation

/// Async summarizer using local Ollama (qwen2.5:3b-instruct).
/// Runs after outbox file I/O — never blocks the Claude↔GPT loop.
final class OllamaSummarizer {
    private let baseURL = "http://localhost:11434/api/generate"
    private let model = "qwen2.5:3b-instruct"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    /// Summarize conversation history incrementally.
    /// Returns updated summary or nil on failure (never throws — fire-and-forget).
    func summarize(existingSummary: String, newMessages: [(role: String, content: String)]) async -> String? {
        guard !newMessages.isEmpty else { return nil }

        let messagesText = newMessages.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n")

        let prompt = """
        You are summarizing a conversation between a coding AI (Claude) and a review AI (ChatGPT).
        Preserve: key decisions, code changes discussed, files modified, outstanding issues, current state.
        Be concise — max 500 words.

        EXISTING SUMMARY:
        \(existingSummary.isEmpty ? "(none — this is the start of the conversation)" : existingSummary)

        NEW MESSAGES:
        \(messagesText)

        Updated summary:
        """

        let requestBody: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "num_predict": 800
            ]
        ]

        guard let url = URL(string: baseURL),
              let body = try? JSONSerialization.data(withJSONObject: requestBody) else {
            NSLog("[Buck] OllamaSummarizer: failed to build request")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                NSLog("[Buck] OllamaSummarizer: non-200 response")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                NSLog("[Buck] OllamaSummarizer: failed to parse response")
                return nil
            }

            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                NSLog("[Buck] OllamaSummarizer: empty response")
                return nil
            }

            NSLog("[Buck] OllamaSummarizer: summary updated, len=%d", trimmed.count)
            return trimmed

        } catch {
            NSLog("[Buck] OllamaSummarizer: request failed — %@", error.localizedDescription)
            return nil
        }
    }

    /// Check if Ollama is running and the model is available
    func isAvailable() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return false
            }
            return models.contains { ($0["name"] as? String)?.hasPrefix("qwen2.5:3b") == true }
        } catch {
            return false
        }
    }
}
