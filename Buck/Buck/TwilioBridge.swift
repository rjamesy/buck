import Foundation

/// Bridge that sends SMS via the Twilio REST API (no desktop app needed).
///
/// Phase 1: info-push only. `waitForResponse` returns "sent" immediately after
/// the outgoing SMS is accepted by Twilio. Phase 2 will add `ask` mode with
/// inbound polling; Phase 3 will add a ChatGPT fallback on timeout.
final class TwilioBridge: BridgeProtocol {
    let name = "Twilio"

    private var accountSid: String = ""
    private var authToken: String = ""
    private var fromNumber: String = ""
    private var toNumber: String = ""
    private var pendingMessage: String = ""

    // MARK: - Config

    private struct TwilioConfig: Codable {
        let accountSid: String?
        let authToken: String?
        let fromNumber: String?
        let toNumber: String?

        enum CodingKeys: String, CodingKey {
            case accountSid = "account_sid"
            case authToken = "auth_token"
            case fromNumber = "from_number"
            case toNumber = "to_number"
        }
    }

    init() {
        loadConfig()
    }

    private func loadConfig() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/twilio-config.json")

        if let data = try? Data(contentsOf: configPath),
           let config = try? JSONDecoder().decode(TwilioConfig.self, from: data) {
            accountSid = config.accountSid ?? ""
            authToken = config.authToken ?? ""
            fromNumber = config.fromNumber ?? ""
            toNumber = config.toNumber ?? ""
            BuckLog.log("[TwilioBridge] Config loaded (from: \(fromNumber) to: \(toNumber))")
        } else {
            BuckLog.log("[TwilioBridge] No config at \(configPath.path), will try env vars")
        }

        let env = ProcessInfo.processInfo.environment
        if accountSid.isEmpty, let v = env["TWILIO_ACCOUNT_SID"], !v.isEmpty { accountSid = v }
        if authToken.isEmpty, let v = env["TWILIO_AUTH_TOKEN"], !v.isEmpty { authToken = v }
        if fromNumber.isEmpty, let v = env["TWILIO_FROM"], !v.isEmpty { fromNumber = v }
        if toNumber.isEmpty, let v = env["TWILIO_TO"], !v.isEmpty { toNumber = v }
    }

    // MARK: - BridgeProtocol

    func findApp() throws -> Bool {
        if accountSid.isEmpty || authToken.isEmpty || fromNumber.isEmpty || toNumber.isEmpty {
            throw TwilioBridgeError.missingConfig
        }
        return true
    }

    func sendMessage(_ text: String) throws {
        pendingMessage = text
    }

    func waitForResponse(timeout: TimeInterval) async throws -> String {
        guard !pendingMessage.isEmpty else {
            throw TwilioBridgeError.noMessage
        }
        let raw = pendingMessage
        pendingMessage = ""

        let (_, body) = parseMode(from: raw)

        BuckLog.log("[TwilioBridge] Sending SMS to \(toNumber) (\(body.count) chars)")
        try await postMessage(body: body)
        BuckLog.log("[TwilioBridge] SMS accepted by Twilio")
        return "sent"
    }

    func startNewChat() {
        // No-op — notifications are not conversations.
    }

    // MARK: - Helpers

    /// Strip a leading `[BUCK-MODE:info]` / `[BUCK-MODE:ask]` tag (optionally preceded by
    /// whitespace from the coordinator's `prefix\n\ncontent` concatenation) and return
    /// (mode, body). Default mode is "info" when no tag is present.
    private func parseMode(from text: String) -> (mode: String, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[BUCK-MODE:info]") {
            let body = String(trimmed.dropFirst("[BUCK-MODE:info]".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ("info", body)
        }
        if trimmed.hasPrefix("[BUCK-MODE:ask]") {
            let body = String(trimmed.dropFirst("[BUCK-MODE:ask]".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ("ask", body)
        }
        return ("info", trimmed)
    }

    private func postMessage(body: String) async throws {
        let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/Messages.json")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let basic = "\(accountSid):\(authToken)".data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let form = [
            "From": fromNumber,
            "To": toNumber,
            "Body": body
        ]
        request.httpBody = formEncode(form).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw BridgeError.timeout
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            BuckLog.log("[TwilioBridge] HTTP \(status) \(rawBody)")
            throw TwilioBridgeError.apiError("HTTP \(status): \(rawBody)")
        }
    }

    private func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Errors

enum TwilioBridgeError: LocalizedError {
    case missingConfig
    case noMessage
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Twilio config missing. Set account_sid, auth_token, from_number, to_number in ~/.buck/twilio-config.json."
        case .noMessage:
            return "No message to send (sendMessage not called)"
        case .apiError(let detail):
            return detail
        }
    }
}
