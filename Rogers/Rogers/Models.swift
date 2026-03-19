import Foundation
import CryptoKit

struct ThreadMessage {
    let role: String          // "user", "assistant", or "unknown"
    let content: String
    let contentHash: String   // SHA256 hex

    init(role: String, content: String) {
        self.role = role
        self.content = content
        self.contentHash = Self.hash(content)
    }

    static func hash(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct SessionInfo: Identifiable {
    let id: String
    let threadTitle: String
    let gptName: String
    let turnCount: Int
    let isActive: Bool
    let isCompacted: Bool
    let lastPolledAt: Date
}
