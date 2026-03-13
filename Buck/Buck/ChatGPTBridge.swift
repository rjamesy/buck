import ApplicationServices
import AppKit

final class ChatGPTBridge {
    /// Which window this bridge targets: "AXStandardWindow" (main) or "AXSystemDialog" (companion)
    let targetSubrole: String
    private var appElement: AXUIElement?
    private var chatGPTPid: pid_t = 0
    private var lastTerminalCheckTime: Date?

    init(targetSubrole: String = "AXStandardWindow") {
        self.targetSubrole = targetSubrole
    }

    static func log(_ msg: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/logs/buck.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - Find ChatGPT

    func findChatGPT() throws -> Bool {
        guard AXIsProcessTrusted() else {
            Self.log("AXIsProcessTrusted=false")
            throw BuckError.accessibilityDenied
        }

        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.chat"
        ).first else {
            Self.log("ChatGPT not running")
            throw BuckError.chatGPTNotFound
        }
        chatGPTPid = app.processIdentifier
        appElement = AXUIElementCreateApplication(app.processIdentifier)
        lastTerminalCheckTime = nil
        return true
    }

    // MARK: - Send Message

    private func waitForSendButton(in window: AXUIElement, timeout: TimeInterval = 30) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            if let btn = findSendButton(in: window) { return btn }
            Self.log("Send button not found (attempt \(attempt)), waiting...")
            Thread.sleep(forTimeInterval: 2.0)
        }
        Self.log("Send button not found after \(Int(timeout))s")
        return nil
    }

    func sendMessage(_ text: String) throws {
        guard let app = appElement else {
            throw BuckError.chatGPTNotFound
        }

        for attempt in 1...3 {
            Self.log("Send attempt \(attempt)/3")

            guard let window = getFirstWindow(app) else {
                throw BuckError.noWindow
            }

            guard let textArea = findElement(in: window, role: kAXTextAreaRole) else {
                throw BuckError.inputFieldNotFound
            }

            // On retry: clear input field first
            if attempt > 1 {
                Self.log("Clearing stuck input field for retry")
                AXUIElementSetAttributeValue(textArea, kAXValueAttribute as CFString, "" as CFTypeRef)
                Thread.sleep(forTimeInterval: 0.5)
            }

            // Set the text value
            let setResult = AXUIElementSetAttributeValue(
                textArea,
                kAXValueAttribute as CFString,
                text as CFTypeRef
            )
            guard setResult == .success else {
                throw BuckError.cannotSetValue
            }

            // Small delay for Electron to process the state change
            Thread.sleep(forTimeInterval: 0.3)

            // Find send button — wait up to 30s for GPT to finish generating
            guard let sendButton = waitForSendButton(in: window) else {
                throw BuckError.sendButtonNotFound
            }

            // Verify button is enabled
            var enabled: CFTypeRef?
            AXUIElementCopyAttributeValue(sendButton, kAXEnabledAttribute as CFString, &enabled)
            guard let isEnabled = enabled as? Bool, isEnabled else {
                throw BuckError.sendButtonDisabled
            }

            let pressResult = AXUIElementPerformAction(sendButton, kAXPressAction as CFString)
            guard pressResult == .success else {
                throw BuckError.cannotPressSend
            }

            // Verify message actually sent
            if verifyMessageSent(window: window, originalText: text) {
                Self.log("Message sent successfully on attempt \(attempt)")
                return
            }

            Self.log("Message stuck in input field on attempt \(attempt)")
        }

        Self.log("All 3 send attempts failed — message stuck")
        throw BuckError.messageSendFailed
    }

    // MARK: - Send Verification

    private func verifyMessageSent(window: AXUIElement, originalText: String) -> Bool {
        Thread.sleep(forTimeInterval: 0.5)
        guard let textArea = findElement(in: window, role: kAXTextAreaRole) else { return false }
        let currentText = getStringAttribute(textArea, kAXValueAttribute) ?? ""
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Field must be empty/near-empty (< 2 chars handles placeholder like FFFC)
        if trimmed.count < 2 { return true }
        // If field still has substantial text, check it's not the original message stuck there
        let originalPrefix = String(originalText.prefix(50))
        if trimmed.hasPrefix(originalPrefix) {
            Self.log("Input field still contains original message (len=\(trimmed.count))")
            return false
        }
        // Field contains different text (e.g. placeholder like "Message ChatGPT") — treat as sent
        return true
    }

    // MARK: - Read Messages

    /// Count the substantive message groups in the chat
    func countMessageGroups() -> Int {
        guard let app = appElement,
              let window = getFirstWindow(app),
              let chatPane = findChatPane(in: window),
              let messagesScrollArea = findMessagesScrollArea(in: chatPane),
              let outerList = findFirstChild(of: messagesScrollArea, role: kAXListRole),
              let innerList = findFirstChild(of: outerList, role: kAXListRole) else {
            return 0
        }
        let groups = getChildren(of: innerList).filter { getRole($0) == kAXGroupRole }
        return groups.filter { !getChildren(of: $0).isEmpty }.count
    }

    /// Read text from the last message group
    func readLastResponse() throws -> String {
        guard let app = appElement else {
            throw BuckError.chatGPTNotFound
        }
        guard let window = getFirstWindow(app) else {
            throw BuckError.noWindow
        }

        guard let chatPane = findChatPane(in: window) else {
            throw BuckError.chatPaneNotFound
        }

        guard let messagesScrollArea = findMessagesScrollArea(in: chatPane) else {
            throw BuckError.messagesNotFound
        }

        guard let outerList = findFirstChild(of: messagesScrollArea, role: kAXListRole),
              let innerList = findFirstChild(of: outerList, role: kAXListRole) else {
            throw BuckError.messagesNotFound
        }

        let groups = getChildren(of: innerList).filter { getRole($0) == kAXGroupRole }

        guard let lastMessageGroup = findLastMessageGroup(in: groups) else {
            throw BuckError.messagesNotFound
        }

        return collectText(from: lastMessageGroup)
    }

    // MARK: - Wait for Response

    func waitForResponse(timeout: TimeInterval = 120) async throws -> String {
        guard let app = appElement else {
            throw BuckError.chatGPTNotFound
        }
        let initialText = (try? readLastResponse()) ?? ""
        let initialGroupCount = countMessageGroups()
        let deadline = Date().addingTimeInterval(timeout)
        var peakLength = 0
        var bestText = ""
        var gptStarted = false
        var sendButtonGone = false  // true once send button disappeared (generation active)
        var sendButtonBackCount = 0 // consecutive polls with send button visible after generation
        var stableCount = 0
        var lastStableText = ""
        var groupStableWithSameText = 0

        enum SendButtonState { case visible, gone, unknown }

        // Minimum wait before checking — gives GPT time to start
        try await Task.sleep(nanoseconds: 1_000_000_000)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let currentText = (try? readLastResponse()) ?? ""
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentGroupCount = countMessageGroups()
            let currentLen = currentText.count

            // Track send button state for completion detection (tri-state)
            let sendButtonState: SendButtonState
            if let window = getFirstWindow(app) {
                sendButtonState = findSendButton(in: window) != nil ? .visible : .gone
            } else {
                sendButtonState = .unknown
            }

            // Only update send button tracking when we can actually inspect the window
            switch sendButtonState {
            case .gone:
                if !sendButtonGone {
                    sendButtonGone = true
                    Self.log("Send button disappeared — generation active")
                }
            case .unknown:
                Self.log("poll: window uninspectable, skipping send button check")
            case .visible:
                break
            }

            // Detect GPT started: either group count increased or text changed
            if !gptStarted {
                if currentGroupCount > initialGroupCount || currentText != initialText {
                    gptStarted = true
                    Self.log("GPT started responding, groups=\(currentGroupCount) (was \(initialGroupCount))")
                } else {
                    continue
                }
            }

            // Skip empty/placeholder content
            if trimmed.isEmpty || trimmed == "\u{FFFC}" {
                Self.log("poll: len=\(currentLen) peak=\(peakLength) (empty, skipping)")
                sendButtonBackCount = 0
                continue
            }

            // Skip if the text is identical to what was there before we sent
            if currentText == initialText {
                if currentGroupCount > initialGroupCount {
                    groupStableWithSameText += 1
                    if groupStableWithSameText >= 3 {
                        Self.log("Response identical to initial, groups confirm GPT responded")
                        return currentText
                    }
                    Self.log("poll: groups=\(currentGroupCount) text unchanged (\(groupStableWithSameText)/3)")
                } else {
                    sendButtonBackCount = 0
                    groupStableWithSameText = 0
                }
                continue
            }
            groupStableWithSameText = 0

            // Detect GPT tool-use indicators (e.g. "Looked at Terminal • Focused on selected lines")
            // GPT is still processing — real response hasn't arrived yet
            if isToolUseIndicator(trimmed) {
                Self.log("poll: tool-use indicator, waiting for real response: \(trimmed.prefix(80))")
                sendButtonBackCount = 0
                continue
            }

            // Track best text for timeout fallback
            if currentLen >= peakLength {
                if currentLen > peakLength {
                    if let window = getFirstWindow(app) { expandAndScroll(in: window) }
                }
                peakLength = currentLen
                bestText = currentText
            }

            // Track text stability for completion detection
            if currentText == lastStableText {
                stableCount += 1
            } else {
                stableCount = 0
                lastStableText = currentText
            }

            // Send button reappearance detection (requires 2 consecutive polls for debounce)
            switch sendButtonState {
            case .visible where sendButtonGone:
                sendButtonBackCount += 1
                Self.log("poll: len=\(currentLen) peak=\(peakLength) sendBtn=back(\(sendButtonBackCount)/2)")
            case .gone:
                sendButtonBackCount = 0
                Self.log("poll: len=\(currentLen) peak=\(peakLength) sendBtn=gone")
            case .unknown:
                // Don't advance or reset — uninspectable poll
                Self.log("poll: len=\(currentLen) peak=\(peakLength) sendBtn=unknown")
            case .visible:
                // Send button still visible but sendButtonGone never set — generation hasn't started at UI level
                Self.log("poll: len=\(currentLen) peak=\(peakLength) sendBtn=visible(pre-gen)")
            }

            if sendButtonGone && sendButtonBackCount >= 2 {
                // GPT finished — send button returned for 2 consecutive polls
                if let window = getFirstWindow(app) {
                    expandAndScroll(in: window)
                }
                let finalText = (try? readLastResponse()) ?? bestText
                if !finalText.isEmpty && finalText != initialText && !isToolUseIndicator(finalText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Self.log("Response complete (send button returned), len=\(finalText.count)")
                    return finalText
                }
            }

            // Text-stability completion: text non-empty, different from initial, stable for N polls
            let stabilityThreshold = currentLen < 200 ? 3 : 4
            if stableCount >= stabilityThreshold && currentText != initialText {
                if let window = getFirstWindow(app) { expandAndScroll(in: window) }
                let finalText = (try? readLastResponse()) ?? bestText
                if !finalText.isEmpty && finalText != initialText {
                    Self.log("Response complete (text stable \(stableCount) polls), len=\(finalText.count)")
                    return finalText
                }
            }
        }

        // On timeout, return bestText if we got something substantial
        if bestText.count > 0 {
            Self.log("Timeout but returning best text, len=\(bestText.count) peak=\(peakLength)")
            return bestText
        }

        Self.log("Timeout waiting for response (peak=\(peakLength))")
        throw BuckError.timeout
    }

    // MARK: - Response Validation

    /// Check if text is only GPT tool-use indicators (not a real response)
    /// GPT shows these while using screen-reading tools before answering
    private func isToolUseIndicator(_ text: String) -> Bool {
        let patterns = [
            "Looked at Terminal",
            "Focused on selected lines",
            "Looked at Screen",
            "Looked at ",
            "Browsed ",
            "Searched "
        ]
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        // If ALL non-empty lines are tool-use indicators, it's not a real response
        return lines.allSatisfy { line in
            patterns.contains(where: { line.contains($0) }) || line == "•"
        }
    }

    // MARK: - New Chat (compact only)

    /// Start a new ChatGPT thread. Only used during session compaction.
    func startNewChat() {
        guard let app = appElement,
              let window = getFirstWindow(app) else {
            Self.log("startNewChat: no window")
            return
        }

        // Look for the "New chat" button in the sidebar or toolbar
        if let newChatBtn = findElement(in: window, role: kAXButtonRole, matcher: { el in
            let desc = self.getStringAttribute(el, kAXDescriptionAttribute) ?? ""
            let help = self.getStringAttribute(el, kAXHelpAttribute) ?? ""
            return desc.contains("New chat") || help.contains("New chat") ||
                   desc.contains("New Chat") || help.contains("New Chat")
        }) {
            AXUIElementPerformAction(newChatBtn, kAXPressAction as CFString)
            Self.log("startNewChat: clicked 'New chat' button")
            Thread.sleep(forTimeInterval: 1.0)
            return
        }

        // Fallback: Cmd+N keyboard shortcut
        Self.log("startNewChat: 'New chat' button not found, trying Cmd+N")
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: true) // N key
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: false)
        keyUp?.flags = .maskCommand

        let chatGPTPid = self.chatGPTPid
        keyDown?.postToPid(chatGPTPid)
        keyUp?.postToPid(chatGPTPid)
        Thread.sleep(forTimeInterval: 1.0)
        Self.log("startNewChat: sent Cmd+N")
    }

    // MARK: - AX Tree Navigation

    private func getFirstWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else {
            return nil
        }
        // Find the window matching our target subrole
        for win in windows {
            let subrole = getStringAttribute(win, kAXSubroleAttribute) ?? ""
            if subrole == targetSubrole {
                return win
            }
        }
        // Fallback: if only one window exists, use it regardless of subrole
        if windows.count == 1 {
            return windows.first
        }
        Self.log("No window with subrole \(targetSubrole) found (\(windows.count) windows)")
        return nil
    }

    private func findChatPane(in window: AXUIElement) -> AXUIElement? {
        let windowChildren = getChildren(of: window)
        guard let mainGroup = windowChildren.first(where: { getRole($0) == kAXGroupRole }) else {
            return nil
        }

        // Main window: Group → SplitGroup → Group(max children)
        let mainGroupChildren = getChildren(of: mainGroup)
        if let splitGroup = mainGroupChildren.first(where: { getRole($0) == "AXSplitGroup" }) {
            let groups = getChildren(of: splitGroup).filter { getRole($0) == kAXGroupRole }
            return groups.max(by: { getChildren(of: $0).count < getChildren(of: $1).count })
        }

        // Companion chat: the first AXGroup child IS the chat pane (no sidebar/SplitGroup)
        return mainGroup
    }

    private func expandAndScroll(in window: AXUIElement) {
        // 1. Click "Scroll to bottom" if present
        if let scrollBtn = findButtonByDescription(in: window, desc: "Scroll to bottom") {
            AXUIElementPerformAction(scrollBtn, kAXPressAction as CFString)
        }

        // 2. Click "Show full message" if present
        if let showFullBtn = findButtonByDescription(in: window, desc: "Show full message") {
            AXUIElementPerformAction(showFullBtn, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1.0)
        }

        // 3. Click "See more" if present
        if let seeMoreBtn = findButtonByDescription(in: window, desc: "See more") {
            AXUIElementPerformAction(seeMoreBtn, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func findButtonByDescription(in element: AXUIElement, desc: String) -> AXUIElement? {
        return findElement(in: element, role: kAXButtonRole) { el in
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &value)
            return (value as? String) == desc
        }
    }

    private func findSendButton(in window: AXUIElement) -> AXUIElement? {
        return findElement(in: window, role: kAXButtonRole) { element in
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXHelpAttribute as CFString, &value)
            if let help = value as? String, help.contains("Send message") {
                return true
            }
            return false
        }
    }

    private func findElement(
        in element: AXUIElement,
        role: String,
        matcher: ((AXUIElement) -> Bool)? = nil,
        depth: Int = 0
    ) -> AXUIElement? {
        if depth > 15 { return nil }

        let currentRole = getRole(element)
        if currentRole == role {
            if let matcher = matcher {
                if matcher(element) { return element }
            } else {
                return element
            }
        }

        for child in getChildren(of: element) {
            if let found = findElement(in: child, role: role, matcher: matcher, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func findFirstChild(of element: AXUIElement, role: String) -> AXUIElement? {
        return getChildren(of: element).first { getRole($0) == role }
    }

    /// Find the messages scroll area — the one containing an AXList (not the input text area)
    private func findMessagesScrollArea(in chatPane: AXUIElement) -> AXUIElement? {
        for child in getChildren(of: chatPane) {
            if getRole(child) == kAXScrollAreaRole {
                // The messages scroll area contains an AXList; the input scroll area contains AXTextArea
                if getChildren(of: child).contains(where: { getRole($0) == kAXListRole }) {
                    return child
                }
            }
        }
        return nil
    }

    private func findLastMessageGroup(in groups: [AXUIElement]) -> AXUIElement? {
        // Message groups have 1 child (AXGroup) which contains the actual text.
        // Find the last group that has any children at all.
        for group in groups.reversed() {
            let children = getChildren(of: group)
            if children.isEmpty { continue }
            // Check if this group or its first child has substantial content
            for child in children {
                let grandchildren = getChildren(of: child)
                if grandchildren.count > 0 {
                    return group
                }
            }
        }
        return nil
    }

    private func collectText(from element: AXUIElement) -> String {
        var texts: [String] = []
        collectTextRecursive(element, into: &texts, depth: 0)
        return texts.joined(separator: "\n")
    }

    private func collectTextRecursive(_ element: AXUIElement, into texts: inout [String], depth: Int) {
        if depth > 20 { return }

        let role = getRole(element)

        if role == kAXStaticTextRole {
            // Check AXValue first, then AXDescription — both can contain text
            if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
                texts.append(value)
            } else if let desc = getStringAttribute(element, kAXDescriptionAttribute), !desc.isEmpty {
                texts.append(desc)
            }
            return  // Don't recurse into static text children
        }

        // Skip headings (just markers like "Code block")
        if role == "AXHeading" {
            return
        }

        for child in getChildren(of: element) {
            collectTextRecursive(child, into: &texts, depth: depth + 1)
        }
    }

    // MARK: - Ensure Terminal Enabled

    private func ensureTerminalEnabled(in window: AXUIElement) {
        if let last = lastTerminalCheckTime, Date().timeIntervalSince(last) < 60 {
            return
        }

        // Find "Work with Apps" button
        guard let workWithAppsBtn = findElement(in: window, role: kAXButtonRole, matcher: { el in
            let desc = self.getStringAttribute(el, kAXDescriptionAttribute) ?? ""
            return desc == "Work with Apps"
        }) else {
            Self.log("ensureTerminal: 'Work with Apps' button not found")
            return
        }

        // Open the popover
        AXUIElementPerformAction(workWithAppsBtn, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.5)

        // Find the popover
        guard let popover = findElement(in: window, role: "AXPopover") else {
            Self.log("ensureTerminal: Popover not found after clicking")
            return
        }

        // Find the list inside the popover (AXOpaqueProviderGroup)
        guard let list = findElement(in: popover, role: "AXOpaqueProviderGroup") else {
            Self.log("ensureTerminal: List not found in popover")
            // Close popover
            AXUIElementPerformAction(workWithAppsBtn, kAXPressAction as CFString)
            return
        }

        // Get all children and determine Terminal's section
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else {
            AXUIElementPerformAction(workWithAppsBtn, kAXPressAction as CFString)
            return
        }

        var inOtherApps = false
        var terminalButton: AXUIElement? = nil
        var terminalIsActive = false

        for child in children {
            let role = getRole(child)
            if role == kAXStaticTextRole {
                var valRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valRef)
                if let val = valRef as? String, val == "Other Apps" {
                    inOtherApps = true
                }
            }
            if role == kAXButtonRole {
                let desc = getStringAttribute(child, kAXDescriptionAttribute) ?? ""
                if desc.contains("Terminal") {
                    terminalButton = child
                    terminalIsActive = !inOtherApps  // under "Working with" = active
                    break
                }
            }
        }

        if terminalIsActive {
            Self.log("ensureTerminal: Terminal already active")
            // Close popover
            AXUIElementPerformAction(workWithAppsBtn, kAXPressAction as CFString)
            return
        }

        if let btn = terminalButton {
            Self.log("ensureTerminal: Terminal not active, clicking to enable...")
            AXUIElementPerformAction(btn, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1.0)
            Self.log("ensureTerminal: Terminal enabled")
        } else {
            Self.log("ensureTerminal: Terminal button not found in popover")
        }

        // Close popover
        AXUIElementPerformAction(workWithAppsBtn, kAXPressAction as CFString)
        lastTerminalCheckTime = Date()
    }

    // MARK: - AX Helpers

    private func getRole(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return (value as? String) ?? ""
    }

    private func getChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }
}

// MARK: - Errors

enum BuckError: LocalizedError {
    case accessibilityDenied
    case chatGPTNotFound
    case noWindow
    case inputFieldNotFound
    case sendButtonNotFound
    case sendButtonDisabled
    case cannotSetValue
    case cannotPressSend
    case chatPaneNotFound
    case messagesNotFound
    case timeout
    case messageSendFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: return "Accessibility permission denied — re-add Buck in System Settings → Privacy → Accessibility"
        case .chatGPTNotFound: return "ChatGPT is not running"
        case .noWindow: return "ChatGPT has no open window"
        case .inputFieldNotFound: return "Cannot find ChatGPT input field"
        case .sendButtonNotFound: return "Cannot find send button"
        case .sendButtonDisabled: return "Send button is disabled"
        case .cannotSetValue: return "Cannot set text in input field"
        case .cannotPressSend: return "Cannot press send button"
        case .chatPaneNotFound: return "Cannot find chat pane"
        case .messagesNotFound: return "Cannot find messages in chat"
        case .timeout: return "Timed out waiting for GPT response"
        case .messageSendFailed: return "Message could not be sent after 3 attempts — text stuck in input field"
        }
    }
}
