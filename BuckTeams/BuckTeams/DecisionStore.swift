import Foundation
import CryptoKit

final class DecisionStore {
    private var proposals: [String: DecisionProposal] = [:] // keyed by content hash
    private let expiryWindow = 10 // proposals expire after 10 messages

    // MARK: - Propose / Agree

    /// Process a decision-type message. Returns true if consensus reached.
    func processDecision(content: String, from: Participant.Name, atSeq seq: Int) -> Bool {
        let hash = contentHash(content)

        if var existing = proposals[hash] {
            existing.agreements.insert(from.rawValue)
            proposals[hash] = existing

            if existing.agreements.count >= 2 || from == .user {
                // Consensus reached
                appendToDecisionsFile(content: content, proposer: existing.proposer, agreedBy: existing.agreements)
                proposals.removeValue(forKey: hash)
                return true
            }
            return false
        } else {
            // New proposal
            proposals[hash] = DecisionProposal(
                contentHash: hash,
                content: content,
                proposerSeq: seq,
                proposer: from,
                agreements: [from.rawValue],
                createdAtSeq: seq
            )

            // User auto-confirms
            if from == .user {
                appendToDecisionsFile(content: content, proposer: from, agreedBy: [from.rawValue])
                proposals.removeValue(forKey: hash)
                return true
            }
            return false
        }
    }

    /// Expire old proposals based on current seq
    func expireOldProposals(currentSeq: Int) {
        proposals = proposals.filter { _, proposal in
            currentSeq - proposal.createdAtSeq <= expiryWindow
        }
    }

    // MARK: - File

    func readDecisions() -> String {
        (try? String(contentsOf: TeamsPaths.decisionsFile, encoding: .utf8)) ?? ""
    }

    private func appendToDecisionsFile(content: String, proposer: Participant.Name, agreedBy: Set<String>) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let agreed = agreedBy.sorted().joined(separator: ", ")
        let entry = "\n### Decision (\(timestamp))\n**Proposed by:** \(proposer.displayName) | **Agreed by:** \(agreed)\n\n\(content)\n\n---\n"

        let path = TeamsPaths.decisionsFile.path
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: TeamsPaths.decisionsFile) {
                handle.seekToEndOfFile()
                handle.write(entry.data(using: .utf8)!)
                handle.closeFile()
            }
        } else {
            let header = "# Buck Teams — Decisions\n\n---\n"
            try? (header + entry).write(to: TeamsPaths.decisionsFile, atomically: true, encoding: .utf8)
        }
    }

    func clearDecisions() {
        try? FileManager.default.removeItem(at: TeamsPaths.decisionsFile)
    }

    // MARK: - Hash

    private func contentHash(_ content: String) -> String {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
