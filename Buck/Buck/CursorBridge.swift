import ApplicationServices
import AppKit

/// AX bridge for Cursor (Electron-based IDE, fork of VS Code).
///
/// Unlike ChatGPT's native text field + send button, Cursor's chat input
/// is a Monaco editor inside a Chromium webview. We use:
///   - AXManualAccessibility to expose the webview DOM as AX elements
///   - Keyboard simulation (CGEvent) to type text and press Enter
///   - AX tree traversal to read chat bubble responses
///
/// The chat panel lives under domId "workbench.panel.aichat.*" and
/// messages are in groups with domId "bubble-*".
///
/// IMPORTANT: Cmd+L TOGGLES the chat panel. Never send it when the panel
/// is already open — use AXFocused on the composer area instead.
final class CursorBridge {
    static let cursorBundleId = "com.todesktop.230313mzl4w4u92"

    private var appElement: AXUIElement?
    private var cursorPid: pid_t = 0

    // MARK: - Find Cursor

    func findCursor() throws -> Bool {
        guard AXIsProcessTrusted() else {
            log("AXIsProcessTrusted=false")
            throw CursorBridgeError.accessibilityDenied
        }

        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.cursorBundleId
        ).first else {
            log("Cursor not running")
            throw CursorBridgeError.cursorNotFound
        }
        cursorPid = app.processIdentifier
        appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Force Chromium to expose its webview DOM to the AX tree.
        let result = AXUIElementSetAttributeValue(
            appElement!, "AXManualAccessibility" as CFString, true as CFTypeRef
        )
        if result != .success {
            log("AXManualAccessibility failed (\(result.rawValue)) — AX tree will be minimal")
        }

        Thread.sleep(forTimeInterval: 0.5)
        return true
    }

    // MARK: - Send Message

    func sendMessage(_ text: String) throws {
        guard appElement != nil else {
            throw CursorBridgeError.cursorNotFound
        }

        // Ensure panel is open and snapshot bubble IDs before sending.
        // This snapshot is also used by waitForResponse as the polling baseline
        // to avoid a race where the response appears between send and poll start.
        activateCursor()
        Thread.sleep(forTimeInterval: 0.5)
        focusChatInput()
        Thread.sleep(forTimeInterval: 0.3)
        let idsBefore = currentBubbleIds()
        preSendBubbleIds = idsBefore
        preSendLastText = (try? readLastResponse()) ?? ""

        for attempt in 1...3 {
            log("Send attempt \(attempt)/3 (bubble IDs before: \(idsBefore.count))")

            activateCursor()
            Thread.sleep(forTimeInterval: 0.3)
            focusChatInput()
            Thread.sleep(forTimeInterval: 0.3)

            let src = CGEventSource(stateID: .combinedSessionState)

            // Clear any existing input: Cmd+A then Delete
            postKey(src: src, virtualKey: 0x00, flags: .maskCommand) // A
            Thread.sleep(forTimeInterval: 0.1)
            postKey(src: src, virtualKey: 0x33) // Delete/Backspace
            Thread.sleep(forTimeInterval: 0.3)

            // Type the message character by character.
            // Re-activate periodically to survive focus contention.
            for (i, char) in text.unicodeScalars.enumerated() {
                if i % 100 == 0 && i > 0 {
                    activateCursor()
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.value)])
                down?.postToPid(cursorPid)
                let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
                up?.postToPid(cursorPid)
                Thread.sleep(forTimeInterval: 0.01)
            }

            Thread.sleep(forTimeInterval: 0.5)
            log("Typed \(text.count) chars")

            // Press Enter to send
            activateCursor()
            Thread.sleep(forTimeInterval: 0.1)
            postKey(src: src, virtualKey: 0x24) // Return
            log("Pressed Enter")

            // Verify send — check for new bubble domIds
            Thread.sleep(forTimeInterval: 3.0)
            ensureChatPanelOpen()
            Thread.sleep(forTimeInterval: 0.5)

            let idsAfter = currentBubbleIds()
            let newIds = idsAfter.subtracting(idsBefore)
            if !newIds.isEmpty {
                log("Message sent on attempt \(attempt) — \(newIds.count) new bubble(s)")
                return
            }

            log("Send verification failed on attempt \(attempt) — no new bubble IDs")
        }

        throw CursorBridgeError.messageSendFailed
    }

    // MARK: - Read Messages

    /// Re-assert AXManualAccessibility and get a fresh window reference.
    private func freshWindow() -> AXUIElement? {
        guard let app = appElement else { return nil }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, true as CFTypeRef)
        return getFirstWindow(app)
    }

    /// Get the set of all visible bubble domIds.
    private func currentBubbleIds() -> Set<String> {
        guard let win = freshWindow(),
              let chatPanel = findByDomId(win, "workbench.panel.aichat") else { return [] }
        return Set(findBubbles(chatPanel).compactMap { getStringAttribute($0, "AXDOMIdentifier") })
    }

    /// Count chat bubbles visible in the panel
    func countMessageBubbles() -> Int {
        guard let win = freshWindow(),
              let chatPanel = findByDomId(win, "workbench.panel.aichat") else {
            return 0
        }
        return findBubbles(chatPanel).count
    }

    /// Read text from the last chat bubble
    func readLastResponse() throws -> String {
        guard appElement != nil else {
            throw CursorBridgeError.cursorNotFound
        }
        guard let win = freshWindow() else {
            throw CursorBridgeError.noWindow
        }
        guard let chatPanel = findByDomId(win, "workbench.panel.aichat") else {
            throw CursorBridgeError.chatPanelNotFound
        }

        let bubbles = findBubbles(chatPanel)
        guard let lastBubble = bubbles.last else {
            throw CursorBridgeError.messagesNotFound
        }

        return collectText(from: lastBubble)
    }

    // MARK: - Wait for Response

    /// The pre-send bubble IDs, set by sendMessage for use as polling baseline.
    /// This avoids a race where the response appears between send and poll start.
    private var preSendBubbleIds: Set<String> = []
    private var preSendLastText: String = ""

    func waitForResponse(timeout: TimeInterval = 120) async throws -> String {
        guard appElement != nil else {
            throw CursorBridgeError.cursorNotFound
        }

        // Use the pre-send snapshot if available (set by sendMessage),
        // otherwise take a fresh snapshot now.
        let initialText = preSendLastText.isEmpty ? ((try? readLastResponse()) ?? "") : preSendLastText
        let initialIds = preSendBubbleIds.isEmpty ? currentBubbleIds() : preSendBubbleIds
        preSendBubbleIds = []
        preSendLastText = ""
        let deadline = Date().addingTimeInterval(timeout)
        var peakLength = 0
        var bestText = ""
        var cursorStarted = false
        var stableCount = 0
        var lastStableText = ""
        var panelReopenAttempts = 0

        try await Task.sleep(nanoseconds: 2_000_000_000)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // If panel is missing, reopen
            var currentText = (try? readLastResponse()) ?? ""
            var currentIds = currentBubbleIds()

            if currentIds.isEmpty && panelReopenAttempts < 5 {
                panelReopenAttempts += 1
                log("poll: chat panel not found, reopening (\(panelReopenAttempts)/5)")
                ensureChatPanelOpen()
                try await Task.sleep(nanoseconds: 1_500_000_000)
                currentText = (try? readLastResponse()) ?? ""
                currentIds = currentBubbleIds()
            }

            let newResponseIds = currentIds.subtracting(initialIds)
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentLen = currentText.count

            // Detect response started: new bubble IDs appeared
            if !cursorStarted {
                if !newResponseIds.isEmpty || currentText != initialText {
                    cursorStarted = true
                    log("Cursor started responding, new IDs=\(newResponseIds.count)")
                } else {
                    log("poll: waiting... bubbles=\(currentIds.count)")
                    continue
                }
            }

            if trimmed.isEmpty { stableCount = 0; continue }
            if currentText == initialText { continue }

            if currentLen >= peakLength {
                peakLength = currentLen
                bestText = currentText
            }

            if currentText == lastStableText {
                stableCount += 1
            } else {
                stableCount = 0
                lastStableText = currentText
            }

            log("poll: len=\(currentLen) peak=\(peakLength) stable=\(stableCount)/3")

            let stabilityThreshold = currentLen < 200 ? 3 : 4
            if stableCount >= stabilityThreshold && currentText != initialText {
                let finalText = (try? readLastResponse()) ?? bestText
                if !finalText.isEmpty && finalText != initialText {
                    log("Response complete (stable \(stableCount) polls), len=\(finalText.count)")
                    return finalText
                }
            }
        }

        if bestText.count > 0 {
            log("Timeout but returning best text, len=\(bestText.count)")
            return bestText
        }

        log("Timeout waiting for response (peak=\(peakLength))")
        throw CursorBridgeError.timeout
    }

    // MARK: - New Chat

    func startNewChat() {
        guard let app = appElement,
              let win = getFirstWindow(app) else {
            log("startNewChat: no window")
            return
        }

        if let newChatBtn = findElement(in: win, role: kAXButtonRole, matcher: { el in
            let desc = self.getStringAttribute(el, kAXDescriptionAttribute) ?? ""
            return desc == "New Chat"
        }) {
            AXUIElementPerformAction(newChatBtn, kAXPressAction as CFString)
            log("startNewChat: clicked 'New Chat' button")
            Thread.sleep(forTimeInterval: 1.0)
            return
        }

        log("startNewChat: button not found")
    }

    // MARK: - Focus Chat Input

    /// Focus the chat input without toggling the panel.
    ///
    /// Cmd+L TOGGLES the panel (open↔closed). We must NOT use it when
    /// the panel is already open. Instead, we use AXFocused + AXPress
    /// on the composer-toolbar-section to focus the input via AX.
    ///
    /// If the panel is closed, we use Cmd+L to open it (safe — goes
    /// from closed to open, which always focuses the input).
    private func focusChatInput() {
        guard let win = freshWindow() else { return }

        if let chatPanel = findByDomId(win, "workbench.panel.aichat") {
            // Panel is open — focus via AX (never Cmd+L)
            if let composer = findByDomId(chatPanel, "composer-toolbar-section") {
                AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, true as CFTypeRef)
                AXUIElementPerformAction(composer, kAXPressAction as CFString)
                log("Focused composer-toolbar via AX")
            } else {
                AXUIElementSetAttributeValue(chatPanel, kAXFocusedAttribute as CFString, true as CFTypeRef)
                log("Focused chat panel via AX (composer not found)")
            }
        } else {
            // Panel is closed — Cmd+L opens it and focuses the input
            log("Chat panel closed, opening with Cmd+L")
            let src = CGEventSource(stateID: .combinedSessionState)
            postKey(src: src, virtualKey: 0x25, flags: .maskCommand) // Cmd+L
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Ensure Chat Panel Open

    /// Reopen the chat panel if it was closed (e.g. after agent mode send).
    /// Only sends Cmd+L when the panel is confirmed to be absent.
    private func ensureChatPanelOpen() {
        if let win = freshWindow(), findByDomId(win, "workbench.panel.aichat") != nil {
            return
        }

        log("Chat panel not visible, sending Cmd+L to reopen")
        activateCursor()
        Thread.sleep(forTimeInterval: 0.3)

        let src = CGEventSource(stateID: .combinedSessionState)
        postKey(src: src, virtualKey: 0x25, flags: .maskCommand) // Cmd+L
        Thread.sleep(forTimeInterval: 1.5)

        if let win = freshWindow(), findByDomId(win, "workbench.panel.aichat") != nil {
            log("Chat panel reopened")
        } else {
            log("Chat panel still not found after Cmd+L")
        }
    }

    // MARK: - Activate Cursor

    private func activateCursor() {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.cursorBundleId
        ).first else { return }
        app.activate()
    }

    // MARK: - AX Tree Navigation

    private func getFirstWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }
        for win in windows {
            let subrole = getStringAttribute(win, kAXSubroleAttribute) ?? ""
            if subrole == "AXStandardWindow" { return win }
        }
        return windows.first
    }

    private func findByDomId(_ el: AXUIElement, _ id: String, depth: Int = 0) -> AXUIElement? {
        if depth > 25 { return nil }
        if let domId = getStringAttribute(el, "AXDOMIdentifier"), domId.contains(id) {
            return el
        }
        for child in getChildren(of: el) {
            if let found = findByDomId(child, id, depth: depth + 1) { return found }
        }
        return nil
    }

    private func findBubbles(_ el: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        if depth > 25 { return [] }
        var results: [AXUIElement] = []
        if let domId = getStringAttribute(el, "AXDOMIdentifier"), domId.hasPrefix("bubble-") {
            results.append(el)
        }
        for child in getChildren(of: el) {
            results.append(contentsOf: findBubbles(child, depth: depth + 1))
        }
        return results
    }

    private func collectText(from element: AXUIElement, depth: Int = 0) -> String {
        if depth > 30 { return "" }
        var texts: [String] = []
        let role = getRole(element)

        if role == kAXStaticTextRole || role == "AXListMarker" {
            if let val = getStringAttribute(element, kAXValueAttribute),
               !val.trimmingCharacters(in: .whitespaces).isEmpty {
                texts.append(val)
            }
            return texts.joined(separator: "\n")
        }

        for child in getChildren(of: element) {
            let childText = collectText(from: child, depth: depth + 1)
            if !childText.isEmpty { texts.append(childText) }
        }
        return texts.joined(separator: "\n")
    }

    private func findElement(
        in element: AXUIElement,
        role: String,
        matcher: ((AXUIElement) -> Bool)? = nil,
        depth: Int = 0
    ) -> AXUIElement? {
        if depth > 20 { return nil }
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

    // MARK: - Keyboard Helpers

    private func postKey(src: CGEventSource?, virtualKey: CGKeyCode, flags: CGEventFlags? = nil) {
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        if let flags = flags { down?.flags = flags }
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        if let flags = flags { up?.flags = flags }
        down?.postToPid(cursorPid)
        up?.postToPid(cursorPid)
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

    // MARK: - Logging

    private func log(_ msg: String) { Self.log(msg) }

    static func log(_ msg: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/logs/buck.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [CursorBridge] \(msg)\n"
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
}

// MARK: - Errors

enum CursorBridgeError: LocalizedError {
    case accessibilityDenied
    case cursorNotFound
    case noWindow
    case chatPanelNotFound
    case messagesNotFound
    case timeout
    case messageSendFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission denied — add Buck in System Settings → Privacy → Accessibility"
        case .cursorNotFound:
            return "Cursor is not running"
        case .noWindow:
            return "Cursor has no open window"
        case .chatPanelNotFound:
            return "Cannot find Cursor chat panel — is it open? (Cmd+L)"
        case .messagesNotFound:
            return "Cannot find messages in Cursor chat"
        case .timeout:
            return "Timed out waiting for Cursor response"
        case .messageSendFailed:
            return "Message could not be sent after 3 attempts — keystrokes may have been lost to focus contention"
        }
    }
}
