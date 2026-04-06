import Foundation

enum GPTResponseParser {
    /// Valid prefixes that GPT may use in its responses
    private static let validPrefixes = [
        "CLAUDE QUESTION:", "CLAUDE RESPONSE:", "CLAUDE:",
        "CODEX QUESTION:", "CODEX RESPONSE:", "CODEX:",
        "USER QUESTION:", "USER RESPONSE:", "USER:",
        "ALL QUESTION:", "ALL RESPONSE:", "ALL:",
        "DECISION:", "SYSTEM:",
        "GPT QUESTION:", "GPT RESPONSE:", "GPT:"
    ]

    /// Parse a GPT response into one or more TeamMessages
    static func parse(
        response: String,
        sessionId: String,
        replyToSeq: Int?
    ) -> [ParsedMessage] {
        var results: [ParsedMessage] = []
        let lines = response.components(separatedBy: "\n")
        var currentPrefix: String?
        var currentContent: [String] = []

        func flushCurrent() {
            guard let prefix = currentPrefix else { return }
            let content = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }

            let parsed = parsePrefix(prefix)
            // Strip hallucinated prefixes: GPT can't speak as claude/codex/user
            if parsed.from != .gpt && parsed.from != nil {
                // GPT is pretending to be another participant — rewrite as GPT
                results.append(ParsedMessage(
                    to: "all",
                    type: parsed.type,
                    content: content,
                    isDecision: parsed.isDecision
                ))
            } else {
                results.append(ParsedMessage(
                    to: parsed.to,
                    type: parsed.type,
                    content: content,
                    isDecision: parsed.isDecision
                ))
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let prefix = matchPrefix(trimmed) {
                flushCurrent()
                currentPrefix = prefix
                let afterPrefix = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                currentContent = afterPrefix.isEmpty ? [] : [afterPrefix]
            } else {
                currentContent.append(line)
            }
        }
        flushCurrent()

        // If nothing matched, treat entire response as GPT → all
        if results.isEmpty {
            let content = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                results.append(ParsedMessage(
                    to: "all",
                    type: .chat,
                    content: content,
                    isDecision: false
                ))
            }
        }

        return results
    }

    private static func matchPrefix(_ line: String) -> String? {
        let upper = line.uppercased()
        return validPrefixes.first { upper.hasPrefix($0) }
    }

    private static func parsePrefix(_ prefix: String) -> PrefixInfo {
        let upper = prefix.uppercased()

        if upper.hasPrefix("DECISION:") {
            return PrefixInfo(to: "all", type: .decision, from: nil, isDecision: true)
        }

        if upper.hasPrefix("ALL QUESTION:") {
            return PrefixInfo(to: "all", type: .question, from: nil, isDecision: false)
        }
        if upper.hasPrefix("ALL RESPONSE:") || upper.hasPrefix("ALL:") {
            return PrefixInfo(to: "all", type: .response, from: nil, isDecision: false)
        }

        if upper.hasPrefix("CLAUDE QUESTION:") || upper.hasPrefix("CLAUDE RESPONSE:") || upper.hasPrefix("CLAUDE:") {
            return PrefixInfo(to: "claude", type: upper.contains("QUESTION") ? .question : .chat, from: nil, isDecision: false)
        }
        if upper.hasPrefix("CODEX QUESTION:") || upper.hasPrefix("CODEX RESPONSE:") || upper.hasPrefix("CODEX:") {
            return PrefixInfo(to: "codex", type: upper.contains("QUESTION") ? .question : .chat, from: nil, isDecision: false)
        }
        if upper.hasPrefix("USER QUESTION:") || upper.hasPrefix("USER RESPONSE:") || upper.hasPrefix("USER:") {
            // GPT claiming to be user — hallucination
            return PrefixInfo(to: "user", type: .chat, from: .user, isDecision: false)
        }
        if upper.hasPrefix("GPT QUESTION:") || upper.hasPrefix("GPT RESPONSE:") || upper.hasPrefix("GPT:") {
            return PrefixInfo(to: "all", type: upper.contains("QUESTION") ? .question : .chat, from: .gpt, isDecision: false)
        }

        return PrefixInfo(to: "all", type: .chat, from: nil, isDecision: false)
    }

    struct ParsedMessage {
        let to: String
        let type: TeamMessage.MessageType
        let content: String
        let isDecision: Bool
    }

    private struct PrefixInfo {
        let to: String
        let type: TeamMessage.MessageType
        let from: Participant.Name?
        let isDecision: Bool
    }
}
