import Foundation

@MainActor
final class OpenAIRunner: ObservableObject {
    @Published var isRunning = false
    @Published var currentOutput = ""
    @Published var streamingText = ""

    private(set) var smokeTestPassed = false
    private var currentTask: Task<Void, Never>?
    private var diagnosticsLogged = false

    // MARK: - Diagnostics

    private func logDiagnostics(settings: CodexSettings) {
        guard !diagnosticsLogged else { return }
        diagnosticsLogged = true
        print("[BuckCodex] ── Startup Diagnostics ──")
        print("[BuckCodex] Provider: \(settings.provider)")
        print("[BuckCodex] Base URL: \(settings.baseURL)")
        print("[BuckCodex] Endpoint: /v1/responses")
        print("[BuckCodex] Model: \(settings.model)")
        print("[BuckCodex] OPENAI_API_KEY present: \(settings.hasAPIKey)")
        print("[BuckCodex] Mode: Direct Responses API (no Codex path)")
        print("[BuckCodex] ────────────────────────")
    }

    // MARK: - Smoke Test

    /// Validate API connectivity. Sends "Say hello in five words." and checks for success.
    func smokeTest(settings: CodexSettings) async -> (success: Bool, message: String) {
        print("[BuckCodex] Running smoke test...")
        do {
            let result = try await callResponsesAPI(
                prompt: "Say hello in five words.",
                apiKey: settings.apiKey,
                model: settings.model
            )
            if let error = result.error {
                let msg = classifyError(statusCode: nil, error: error, rawBody: nil)
                print("[BuckCodex] Smoke test FAILED: \(msg)")
                return (false, msg)
            }
            let text = extractText(from: result)
            print("[BuckCodex] Smoke test PASSED: \(text)")
            smokeTestPassed = true
            return (true, text)
        } catch {
            let msg = "Network error: \(error.localizedDescription)"
            print("[BuckCodex] Smoke test FAILED: \(msg)")
            return (false, msg)
        }
    }

    // MARK: - Run

    func run(
        prompt: String,
        settings: CodexSettings,
        onMessage: @escaping (ChatMessage) -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        streamingText = ""
        currentOutput = ""

        logDiagnostics(settings: settings)

        currentTask = Task { [weak self] in
            guard let self else { return }

            self.streamingText = "Waiting for response..."

            do {
                let result = try await self.callResponsesAPI(
                    prompt: prompt,
                    apiKey: settings.apiKey,
                    model: settings.model
                )
                self.streamingText = ""

                if let error = result.error {
                    let msg = self.classifyError(statusCode: nil, error: error, rawBody: nil)
                    onMessage(ChatMessage(role: .error, content: msg, timestamp: Date()))
                } else {
                    let text = self.extractText(from: result)
                    if !text.isEmpty {
                        onMessage(ChatMessage(role: .assistant, content: text, timestamp: Date()))
                    }
                    if let usage = result.usage {
                        self.currentOutput = "Tokens: \(usage.totalTokens ?? 0) (in: \(usage.inputTokens ?? 0), out: \(usage.outputTokens ?? 0))"
                    }
                }
                self.isRunning = false

            } catch is CancellationError {
                self.streamingText = ""
                self.isRunning = false
            } catch {
                self.streamingText = ""
                onMessage(ChatMessage(role: .error, content: "Request failed: \(error.localizedDescription)", timestamp: Date()))
                self.isRunning = false
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        streamingText = ""
    }

    // MARK: - API

    private func callResponsesAPI(
        prompt: String,
        apiKey: String,
        model: String
    ) async throws -> OpenAIResponse {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["model": model, "input": prompt]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawBody = String(data: data, encoding: .utf8)
        let decoder = JSONDecoder()

        if statusCode >= 400 {
            if let errResp = try? decoder.decode(OpenAIResponse.self, from: data),
               let err = errResp.error {
                let msg = classifyError(statusCode: statusCode, error: err, rawBody: rawBody)
                return OpenAIResponse(id: nil, object: nil, model: nil, output: nil, usage: nil,
                                      error: APIError(type: err.type, message: msg))
            }
            return OpenAIResponse(id: nil, object: nil, model: nil, output: nil, usage: nil,
                                  error: APIError(type: "http_\(statusCode)",
                                                  message: "HTTP \(statusCode): \(rawBody ?? "Unknown error")"))
        }

        return try decoder.decode(OpenAIResponse.self, from: data)
    }

    // MARK: - Helpers

    private func extractText(from response: OpenAIResponse) -> String {
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

    private func classifyError(statusCode: Int?, error: APIError, rawBody: String?) -> String {
        let type = error.type ?? ""
        let message = error.message ?? "Unknown error"
        var classified: String

        if statusCode == 401 || type.contains("auth") || type.contains("invalid_api_key") {
            classified = "Auth error: \(message)"
        } else if statusCode == 429 || type.contains("rate_limit") || type.contains("insufficient_quota") {
            classified = "Rate limit / quota: \(message)"
        } else if statusCode == 402 || type.contains("billing") {
            classified = "Billing error: \(message)"
        } else {
            classified = "API error [\(type)]: \(message)"
        }

        if let raw = rawBody, !raw.isEmpty {
            classified += "\n\nRaw response:\n\(raw)"
        }
        return classified
    }
}
