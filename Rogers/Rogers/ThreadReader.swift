import ApplicationServices
import AppKit

final class ThreadReader {
    private var appElement: AXUIElement?
    private var chatGPTPid: pid_t = 0

    static func log(_ msg: String) {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rogers")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("rogers.log")
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

    // MARK: - ChatGPT Discovery

    func isChatGPTRunning() -> Bool {
        return NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.chat"
        ).first != nil
    }

    func findChatGPT() -> Bool {
        guard AXIsProcessTrusted() else {
            Self.log("AXIsProcessTrusted=false")
            return false
        }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.chat"
        ).first else {
            return false
        }
        chatGPTPid = app.processIdentifier
        appElement = AXUIElementCreateApplication(app.processIdentifier)
        return true
    }

    // MARK: - Thread Title

    /// Read the current thread title and GPT name from the toolbar.
    /// Try to read thread title from toolbar (old ChatGPT format: "Title, GPT Name").
    /// Returns nil if toolbar doesn't contain a thread title (current ChatGPT default model).
    func readThreadTitle() -> (title: String, gptName: String?)? {
        guard let app = appElement,
              let window = getMainWindow(app) else { return nil }

        guard let toolbar = findElement(in: window, role: kAXToolbarRole) else {
            return nil
        }

        // Known non-title button descriptions to skip
        let skipPrefixes = ["ChatGPT", "Toggle", "Move to"]
        let skipExact: Set<String> = [
            "New chat", "Open sidebar", "Close sidebar", "Toggle Sidebar",
            "Toggle sidebar", "Share", "Search", "Model selector", "Attach",
            "Temporary chat", "ChatGPT", "Menu", "Close", "Minimize", "Zoom",
            "Fullscreen", "Full Screen", "Move to new window", "Options",
            "Send", "Record meeting", "Dictation", "Agent", "Work with Apps"
        ]

        var candidates: [String] = []
        collectButtons(in: toolbar) { el in
            let desc = self.getStringAttribute(el, kAXDescriptionAttribute) ?? ""
            if desc.isEmpty || desc.count <= 3 { return }
            if skipExact.contains(desc) { return }
            if skipPrefixes.contains(where: { desc.hasPrefix($0) }) { return }
            candidates.append(desc)
        }

        // Only accept comma-separated format (thread title, GPT name)
        // This filters out model selectors like "ChatGPT Auto"
        guard let bestDesc = candidates.first(where: { $0.contains(", ") }) else {
            return nil
        }

        if let commaRange = bestDesc.range(of: ", ", options: .backwards) {
            let title = String(bestDesc[bestDesc.startIndex..<commaRange.lowerBound])
            let gptName = String(bestDesc[commaRange.upperBound...])
            return (title: title, gptName: gptName)
        }

        return nil
    }

    // MARK: - Sidebar Reading

    /// Read all thread names from the ChatGPT sidebar.
    /// Returns ordered list of thread button descriptions (newest first within each time section).
    func readSidebarNames() -> [String] {
        guard let app = appElement,
              let window = getMainWindow(app) else { return [] }

        // Navigate: Window > Group > SplitGroup > sidebar (min children group)
        let windowChildren = getChildren(of: window)
        guard let mainGroup = windowChildren.first(where: { getRole($0) == kAXGroupRole }) else { return [] }
        guard let splitGroup = getChildren(of: mainGroup).first(where: { getRole($0) == "AXSplitGroup" }) else { return [] }
        let groups = getChildren(of: splitGroup).filter { getRole($0) == kAXGroupRole }
        guard let sidebar = groups.min(by: { getChildren(of: $0).count < getChildren(of: $1).count }) else { return [] }

        // Find scroll area with thread list
        guard let scrollArea = getChildren(of: sidebar).first(where: { getRole($0) == kAXScrollAreaRole }) else { return [] }
        guard let outerList = getChildren(of: scrollArea).first(where: { getRole($0) == kAXListRole }) else { return [] }

        // Non-thread sidebar items to skip
        let skipNames: Set<String> = [
            "ChatGPT", "GPTs", "New project", "See more", "New chat"
        ]

        var names: [String] = []
        for subList in getChildren(of: outerList) {
            guard getRole(subList) == kAXListRole else { continue }
            for group in getChildren(of: subList) {
                let innerChildren = getChildren(of: group)
                guard let innerGroup = innerChildren.first else { continue }
                for btn in getChildren(of: innerGroup) {
                    guard getRole(btn) == kAXButtonRole else { continue }
                    let desc = getStringAttribute(btn, kAXDescriptionAttribute) ?? ""
                    if !desc.isEmpty && desc.count >= 3 && !skipNames.contains(desc) {
                        names.append(desc)
                    }
                }
            }
        }

        return names
    }

    /// Collect all buttons in a subtree, calling handler for each.
    private func collectButtons(in element: AXUIElement, depth: Int = 0, handler: (AXUIElement) -> Void) {
        if depth > 10 { return }
        if getRole(element) == kAXButtonRole {
            handler(element)
        }
        for child in getChildren(of: element) {
            collectButtons(in: child, depth: depth + 1, handler: handler)
        }
    }

    // MARK: - Message Reading

    /// Read all visible message groups from the current scroll position.
    /// Returns messages with role detection and content hash.
    func readVisibleMessages() -> [ThreadMessage] {
        guard let app = appElement,
              let window = getMainWindow(app),
              let chatPane = findChatPane(in: window),
              let scrollArea = findMessagesScrollArea(in: chatPane),
              let outerList = findFirstChild(of: scrollArea, role: kAXListRole),
              let innerList = findFirstChild(of: outerList, role: kAXListRole) else {
            return []
        }

        let groups = getChildren(of: innerList).filter { getRole($0) == kAXGroupRole }
        var messages: [ThreadMessage] = []

        // Get the chat pane's X origin for role detection
        let containerX = getPosition(of: chatPane)?.x ?? 0

        for group in groups {
            let children = getChildren(of: group)
            if children.isEmpty { continue }

            // Find the inner content group
            guard let innerGroup = children.first(where: { !getChildren(of: $0).isEmpty }) else {
                continue
            }

            // Skip thinking indicators ("See details" button only)
            if isThinkingIndicator(innerGroup) { continue }

            let text = collectText(from: innerGroup)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let role = detectRole(innerGroup: innerGroup, containerX: containerX)
            messages.append(ThreadMessage(role: role, content: trimmed))
        }

        return messages
    }

    /// Count visible message groups (cheap — for polling).
    func countVisibleMessages() -> Int {
        guard let app = appElement,
              let window = getMainWindow(app),
              let chatPane = findChatPane(in: window),
              let scrollArea = findMessagesScrollArea(in: chatPane),
              let outerList = findFirstChild(of: scrollArea, role: kAXListRole),
              let innerList = findFirstChild(of: outerList, role: kAXListRole) else {
            return 0
        }
        let groups = getChildren(of: innerList).filter { getRole($0) == kAXGroupRole }
        return groups.filter { !getChildren(of: $0).isEmpty }.count
    }

    /// Scroll to top, then read all messages by scrolling down.
    /// Deduplicates overlapping reads automatically via content hash.
    func readAllMessages() -> [ThreadMessage] {
        guard let app = appElement,
              let window = getMainWindow(app),
              let chatPane = findChatPane(in: window),
              let scrollArea = findMessagesScrollArea(in: chatPane) else {
            return []
        }

        // Get scrollbar to manipulate scroll position
        guard let scrollbar = findElement(in: scrollArea, role: kAXScrollBarRole, matcher: { el in
            let orientation = self.getStringAttribute(el, kAXOrientationAttribute) ?? ""
            return orientation == "AXVerticalOrientation"
        }) else {
            // No scrollbar means all content fits on screen
            return readVisibleMessages()
        }

        // Save current scroll position
        let originalValue = getScrollValue(scrollbar)

        // Scroll to top
        setScrollValue(scrollbar, value: 0.0)
        Thread.sleep(forTimeInterval: 0.5)

        var allMessages: [ThreadMessage] = []
        var seenHashes = Set<String>()
        var noNewCount = 0

        for _ in 0..<200 {  // Safety cap — max 200 scroll steps
            let visible = readVisibleMessages()
            var foundNew = false

            for msg in visible {
                if seenHashes.insert(msg.contentHash).inserted {
                    allMessages.append(msg)
                    foundNew = true
                }
            }

            if !foundNew {
                noNewCount += 1
                if noNewCount >= 2 {
                    break  // No new messages for 2 consecutive scrolls — done
                }
            } else {
                noNewCount = 0
            }

            // Scroll down by a page
            let currentValue = getScrollValue(scrollbar) ?? 1.0
            let nextValue = min(currentValue + 0.15, 1.0)
            if nextValue >= 1.0 && currentValue >= 0.99 {
                // Already at bottom
                break
            }
            setScrollValue(scrollbar, value: nextValue)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Restore scroll position (scroll to bottom)
        setScrollValue(scrollbar, value: originalValue ?? 1.0)

        Self.log("readAllMessages: collected \(allMessages.count) messages")
        return allMessages
    }

    // MARK: - Role Detection

    /// Detect if a message is user or assistant by X position.
    /// User messages are right-aligned (higher X), GPT messages are left-aligned.
    /// Returns "unknown" if position is indeterminate.
    private func detectRole(innerGroup: AXUIElement, containerX: CGFloat) -> String {
        guard let groupPos = getPosition(of: innerGroup) else {
            return "unknown"
        }

        let offset = groupPos.x - containerX
        // User messages are indented significantly to the right (>100px from container)
        if offset > 100 {
            return "user"
        } else {
            return "assistant"
        }
    }

    /// Check if a group is a thinking indicator (e.g. "Thought for X seconds")
    private func isThinkingIndicator(_ group: AXUIElement) -> Bool {
        let children = getChildren(of: group)
        // Thinking indicators typically contain only an AXButton with "See details"
        if children.count <= 2 {
            for child in children {
                if getRole(child) == kAXButtonRole {
                    let desc = getStringAttribute(child, kAXDescriptionAttribute) ?? ""
                    if desc == "See details" { return true }
                }
            }
        }
        return false
    }

    // MARK: - Write Operations (Compact)

    /// Start a new ChatGPT thread.
    func startNewChat() {
        guard let app = appElement,
              let window = getMainWindow(app) else {
            Self.log("startNewChat: no window")
            return
        }

        // Look for "New chat" button
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

        // Fallback: Cmd+N
        Self.log("startNewChat: trying Cmd+N")
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x2D, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.postToPid(chatGPTPid)
        keyUp?.postToPid(chatGPTPid)
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Send a message to ChatGPT.
    func sendMessage(_ text: String) -> Bool {
        guard let app = appElement,
              let window = getMainWindow(app) else { return false }

        guard let textArea = findElement(in: window, role: kAXTextAreaRole) else {
            Self.log("sendMessage: input field not found")
            return false
        }

        let setResult = AXUIElementSetAttributeValue(
            textArea, kAXValueAttribute as CFString, text as CFTypeRef
        )
        guard setResult == .success else {
            Self.log("sendMessage: cannot set value")
            return false
        }

        Thread.sleep(forTimeInterval: 0.3)

        guard let sendButton = findSendButton(in: window) else {
            Self.log("sendMessage: send button not found")
            return false
        }

        let pressResult = AXUIElementPerformAction(sendButton, kAXPressAction as CFString)
        guard pressResult == .success else {
            Self.log("sendMessage: cannot press send")
            return false
        }

        Self.log("sendMessage: sent successfully")
        return true
    }

    /// Wait for GPT to finish responding. Returns the last message text.
    func waitForResponse(timeout: TimeInterval = 120) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        let initialCount = countVisibleMessages()
        var stableCount = 0
        var lastText = ""

        Thread.sleep(forTimeInterval: 1.0)

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2.0)

            let currentCount = countVisibleMessages()
            if currentCount <= initialCount { continue }

            let messages = readVisibleMessages()
            guard let last = messages.last else { continue }
            let currentText = last.content

            if currentText == lastText {
                stableCount += 1
                if stableCount >= 3 {
                    return currentText
                }
            } else {
                stableCount = 0
                lastText = currentText
            }
        }

        return lastText.isEmpty ? nil : lastText
    }

    // MARK: - AX Lock

    /// Check if Buck's AX lock is active. Returns true if locked (Rogers should not write).
    static func isAXLocked() -> Bool {
        let lockFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/ax.lock")
        return FileManager.default.fileExists(atPath: lockFile.path)
    }

    // MARK: - AX Tree Navigation

    private func getMainWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }

        // Prefer AXStandardWindow (main window)
        for win in windows {
            let subrole = getStringAttribute(win, kAXSubroleAttribute) ?? ""
            if subrole == "AXStandardWindow" { return win }
        }
        return windows.first
    }

    private func findChatPane(in window: AXUIElement) -> AXUIElement? {
        let windowChildren = getChildren(of: window)
        guard let mainGroup = windowChildren.first(where: { getRole($0) == kAXGroupRole }) else {
            return nil
        }
        let mainGroupChildren = getChildren(of: mainGroup)
        if let splitGroup = mainGroupChildren.first(where: { getRole($0) == "AXSplitGroup" }) {
            let groups = getChildren(of: splitGroup).filter { getRole($0) == kAXGroupRole }
            return groups.max(by: { getChildren(of: $0).count < getChildren(of: $1).count })
        }
        return mainGroup
    }

    private func findMessagesScrollArea(in chatPane: AXUIElement) -> AXUIElement? {
        for child in getChildren(of: chatPane) {
            if getRole(child) == kAXScrollAreaRole {
                if getChildren(of: child).contains(where: { getRole($0) == kAXListRole }) {
                    return child
                }
            }
        }
        return nil
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

    // MARK: - Text Collection

    private func collectText(from element: AXUIElement) -> String {
        var texts: [String] = []
        collectTextRecursive(element, into: &texts, depth: 0)
        return texts.joined(separator: "\n")
    }

    private func collectTextRecursive(_ element: AXUIElement, into texts: inout [String], depth: Int) {
        if depth > 20 { return }

        let role = getRole(element)

        if role == kAXStaticTextRole {
            if let value = getStringAttribute(element, kAXValueAttribute), !value.isEmpty {
                texts.append(value)
            } else if let desc = getStringAttribute(element, kAXDescriptionAttribute), !desc.isEmpty {
                texts.append(desc)
            }
            return
        }

        if role == "AXHeading" { return }

        for child in getChildren(of: element) {
            collectTextRecursive(child, into: &texts, depth: depth + 1)
        }
    }

    // MARK: - Scroll Helpers

    private func getScrollValue(_ scrollbar: AXUIElement) -> Double? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(scrollbar, kAXValueAttribute as CFString, &value)
        return value as? Double
    }

    private func setScrollValue(_ scrollbar: AXUIElement, value: Double) {
        AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, value as CFTypeRef)
    }

    // MARK: - Position Helpers

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard err == .success else { return nil }
        var point = CGPoint.zero
        if AXValueGetValue(value as! AXValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    // MARK: - AX Helpers

    @discardableResult
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
