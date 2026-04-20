import Foundation

/// Bridge that sends SMS via the Twilio REST API (no desktop app needed).
///
/// Two modes, selected by a `[BUCK-MODE:<mode>[:<timeout>]]` prefix on the
/// outgoing prompt:
///   • `info` — send SMS, return "sent" immediately.
///   • `ask[:N]` — send SMS, then poll Twilio's Messages API for an inbound
///     reply from `to_number`. Default wait is 600s (10 min); `:N` overrides.
///     Throws `BridgeError.timeout` if no reply arrives in time.
///
/// The coordinator's `timeout:` parameter is advisory only; this bridge uses
/// the encoded ask timeout (or 600s default) because the coordinator's default
/// is 120s and SMS replies routinely take longer. On ask timeout, an optional
/// `onAskTimeout` closure (wired by the coordinator) forwards the question to
/// the ChatGPT channel as a fallback.
///
/// Safety limits (Phase 4): each send is gated by a rolling 60-minute cap
/// (default 20/hr) and a minimum send interval (default 2 s). Timestamps are
/// persisted to ~/.buck/twilio-rate.json so limits survive Buck restarts.
/// Message bodies longer than `max_message_length` (default 480) are truncated
/// with a trailing ellipsis.
final class TwilioBridge: BridgeProtocol {
    let name = "Twilio"

    private var accountSid: String = ""
    private var authToken: String = ""
    private var fromNumber: String = ""
    private var toNumber: String = ""
    private var pendingMessage: String = ""

    // Safety limits (Phase 4). Configurable via optional keys in twilio-config.json.
    private var maxMessageLength: Int = 480         // 3 SMS segments (160 GSM-7 each)
    private var maxPerHour: Int = 20                // rolling 60-min cap
    private var minIntervalSec: Double = 2.0        // min gap between sends

    /// Optional fallback invoked when an `ask` poll loop hits its timeout.
    /// The coordinator wires this to forward the question to the ChatGPT
    /// channel so Claude still gets an answer when the user doesn't reply.
    /// If nil, ask-mode timeouts simply throw `BridgeError.timeout`.
    var onAskTimeout: ((String) async throws -> String)?

    // MARK: - Config

    private struct TwilioConfig: Codable {
        let accountSid: String?
        let authToken: String?
        let fromNumber: String?
        let toNumber: String?
        let maxMessageLength: Int?
        let maxPerHour: Int?
        let minIntervalSec: Double?

        enum CodingKeys: String, CodingKey {
            case accountSid = "account_sid"
            case authToken = "auth_token"
            case fromNumber = "from_number"
            case toNumber = "to_number"
            case maxMessageLength = "max_message_length"
            case maxPerHour = "max_per_hour"
            case minIntervalSec = "min_interval_sec"
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
            if let v = config.maxMessageLength, v > 0 { maxMessageLength = v }
            if let v = config.maxPerHour, v > 0 { maxPerHour = v }
            if let v = config.minIntervalSec, v >= 0 { minIntervalSec = v }
            BuckLog.log("[TwilioBridge] Config loaded (from: \(fromNumber) to: \(toNumber); limits: \(maxMessageLength) chars, \(maxPerHour)/hr, \(minIntervalSec)s gap)")
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

        let parsed = parseMode(from: raw)

        // Rate-limit check (cheap, local). Throws if over cap or under min interval.
        try checkRateLimit()

        // Length safety — truncate oversize bodies with an ellipsis rather than reject.
        let body = truncateIfNeeded(parsed.body)

        // Capture the send time BEFORE POSTing, with a small buffer, so we only
        // pick up inbound messages that arrive after this outbound SMS.
        let sinceDate = Date().addingTimeInterval(-2)

        BuckLog.log("[TwilioBridge] Sending SMS to \(toNumber) (\(body.count) chars, mode=\(parsed.mode))")
        try await postMessage(body: body)
        BuckLog.log("[TwilioBridge] SMS accepted by Twilio")
        recordSend()   // record only on successful POST

        if parsed.mode == "info" {
            return "sent"
        }

        let waitSec = parsed.timeoutSec ?? 600
        BuckLog.log("[TwilioBridge] Polling for reply from \(toNumber) (timeout \(waitSec)s)")
        do {
            return try await pollForReply(since: sinceDate, timeout: TimeInterval(waitSec))
        } catch BridgeError.timeout {
            guard let fallback = onAskTimeout else { throw BridgeError.timeout }
            BuckLog.log("[TwilioBridge] ask timeout — invoking ChatGPT fallback")
            let fallbackAnswer = try await fallback(parsed.body)
            return "[via=chatgpt_fallback] " + fallbackAnswer
        }
    }

    func startNewChat() {
        // No-op — notifications are not conversations.
    }

    // MARK: - Helpers

    /// Parse a leading `[BUCK-MODE:info]` / `[BUCK-MODE:ask]` / `[BUCK-MODE:ask:<N>]`
    /// tag and return the mode, optional timeout override in seconds, and the stripped
    /// body. Default mode is "info" when no tag is present.
    private func parseMode(from text: String) -> (mode: String, timeoutSec: Int?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Find a [BUCK-MODE:...] prefix
        guard trimmed.hasPrefix("[BUCK-MODE:"), let close = trimmed.firstIndex(of: "]") else {
            return ("info", nil, trimmed)
        }
        let tag = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "[BUCK-MODE:".count)..<close])
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        let mode = parts.first ?? "info"
        let timeoutSec: Int? = (parts.count > 1) ? Int(parts[1]) : nil
        let bodyStart = trimmed.index(after: close)
        let body = String(trimmed[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (mode == "ask" ? "ask" : "info", timeoutSec, body)
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

    // MARK: - Inbound reply polling

    private struct MessagesPage: Codable {
        let messages: [InboundMessage]
    }

    private struct InboundMessage: Codable {
        let body: String?
        let dateSent: String?
        let direction: String?
        let from: String?

        enum CodingKeys: String, CodingKey {
            case body, direction, from
            case dateSent = "date_sent"
        }
    }

    private static let twilioDateParser: DateFormatter = {
        let f = DateFormatter()
        // Twilio returns RFC 2822: "Mon, 20 Apr 2026 06:51:35 +0000"
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func pollForReply(since: Date, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var tick = 0

        while Date() < deadline {
            tick += 1
            if let reply = try await fetchLatestReply(since: since) {
                BuckLog.log("[TwilioBridge] Got reply after \(tick) polls: \(reply.prefix(80))")
                return reply
            }
            BuckLog.log("[TwilioBridge] poll tick \(tick) — no reply yet")
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        BuckLog.log("[TwilioBridge] No reply within \(Int(timeout))s")
        throw BridgeError.timeout
    }

    private func fetchLatestReply(since: Date) async throws -> String? {
        var components = URLComponents(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/Messages.json")!
        components.queryItems = [
            URLQueryItem(name: "From", value: toNumber),
            URLQueryItem(name: "PageSize", value: "20")
        ]
        guard let url = components.url else {
            throw TwilioBridgeError.apiError("Could not build Twilio URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let basic = "\(accountSid):\(authToken)".data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            // Treat a single poll timeout as transient — the outer loop retries.
            BuckLog.log("[TwilioBridge] poll HTTP timeout, will retry")
            return nil
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            throw TwilioBridgeError.apiError("HTTP \(status) from Twilio poll: \(rawBody)")
        }

        let page = try JSONDecoder().decode(MessagesPage.self, from: data)

        // Twilio returns messages newest-first; find the newest inbound one after sinceDate.
        for msg in page.messages {
            guard msg.direction == "inbound",
                  msg.from == toNumber,
                  let ds = msg.dateSent,
                  let sent = Self.twilioDateParser.date(from: ds),
                  sent > since,
                  let body = msg.body else {
                continue
            }
            return body
        }
        return nil
    }

    // MARK: - Safety: length + rate limit

    private func truncateIfNeeded(_ body: String) -> String {
        guard body.count > maxMessageLength else { return body }
        // Reserve 3 chars for the ellipsis.
        let kept = body.prefix(max(0, maxMessageLength - 3))
        let truncated = String(kept) + "..."
        BuckLog.log("[TwilioBridge] Message truncated from \(body.count) → \(truncated.count) chars (cap \(maxMessageLength))")
        return truncated
    }

    private static let ratePath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/twilio-rate.json")
    }()

    private struct RateState: Codable {
        var sends: [String]   // ISO8601 timestamps
    }

    private func loadRateState() -> RateState {
        guard let data = try? Data(contentsOf: Self.ratePath),
              let state = try? JSONDecoder().decode(RateState.self, from: data) else {
            return RateState(sends: [])
        }
        return state
    }

    private func writeRateState(_ state: RateState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let tmp = Self.ratePath.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.removeItem(at: Self.ratePath)
            try FileManager.default.moveItem(at: tmp, to: Self.ratePath)
        } catch {
            BuckLog.log("[TwilioBridge] rate state write failed: \(error.localizedDescription)")
        }
    }

    private func checkRateLimit() throws {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let horizon = now.addingTimeInterval(-3600)

        let state = loadRateState()
        let recentDates = state.sends.compactMap { iso.date(from: $0) }.filter { $0 > horizon }

        // Minimum interval between sends.
        if let last = recentDates.max() {
            let gap = now.timeIntervalSince(last)
            if gap < minIntervalSec {
                let wait = Int((minIntervalSec - gap).rounded(.up))
                throw TwilioBridgeError.rateLimited("Min interval \(minIntervalSec)s not met — wait \(wait)s and retry")
            }
        }

        // Rolling-hour cap.
        if recentDates.count >= maxPerHour {
            let oldest = recentDates.min()!
            let expiresIn = max(0, Int(oldest.addingTimeInterval(3600).timeIntervalSince(now).rounded(.up)))
            let minutes = (expiresIn + 59) / 60
            throw TwilioBridgeError.rateLimited("Rate limit: \(maxPerHour)/hour reached — oldest slot frees in ~\(minutes)m")
        }
    }

    private func recordSend() {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let horizon = now.addingTimeInterval(-3600)

        var state = loadRateState()
        // Prune anything older than the horizon so the file doesn't grow without bound.
        let pruned = state.sends.compactMap { iso.date(from: $0) }.filter { $0 > horizon }
        state.sends = pruned.map { iso.string(from: $0) } + [iso.string(from: now)]
        writeRateState(state)
    }
}

// MARK: - Errors

enum TwilioBridgeError: LocalizedError {
    case missingConfig
    case noMessage
    case apiError(String)
    case rateLimited(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Twilio config missing. Set account_sid, auth_token, from_number, to_number in ~/.buck/twilio-config.json."
        case .noMessage:
            return "No message to send (sendMessage not called)"
        case .apiError(let detail):
            return detail
        case .rateLimited(let detail):
            return detail
        }
    }
}
