import Foundation

/// Async summarizer using local Ollama (qwen2.5:3b-instruct).
/// Used during compact to summarize full session history.
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

    /// Summarize a full session's messages for injection into a new thread.
    /// Returns summary text or nil on failure (never throws).
    func summarizeFull(messages: [(role: String, content: String)]) async -> String? {
        guard !messages.isEmpty else { return nil }

        let messagesText = messages
            .filter { $0.role != "unknown" }
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n\n")

        let prompt = """
        You are summarizing a conversation between a user and ChatGPT.
        Preserve: key decisions, code changes discussed, files modified, outstanding issues, current state, action items.
        Be concise — max 500 words. Structure with bullet points.

        FULL CONVERSATION:
        \(messagesText)

        Summary:
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
            NSLog("[Rogers] OllamaSummarizer: failed to build request")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                NSLog("[Rogers] OllamaSummarizer: non-200 response")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                NSLog("[Rogers] OllamaSummarizer: failed to parse response")
                return nil
            }

            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                NSLog("[Rogers] OllamaSummarizer: empty response")
                return nil
            }

            NSLog("[Rogers] OllamaSummarizer: summary generated, len=%d", trimmed.count)
            return trimmed

        } catch {
            NSLog("[Rogers] OllamaSummarizer: request failed — %@", error.localizedDescription)
            return nil
        }
    }

    /// Check if Ollama is running and the model is available.
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
