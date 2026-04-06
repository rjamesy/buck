import Cocoa
import ApplicationServices

let cursorBundleId = "com.todesktop.230313mzl4w4u92"

func getAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    return value
}
func getString(_ el: AXUIElement, _ attr: String) -> String? {
    guard let val = getAttr(el, attr) else { return nil }
    return val as? String
}
func getChildren(_ el: AXUIElement) -> [AXUIElement] {
    guard let val = getAttr(el, kAXChildrenAttribute as String) else { return [] }
    return val as? [AXUIElement] ?? []
}
func findByDomId(_ el: AXUIElement, _ id: String, depth: Int = 0) -> AXUIElement? {
    if depth > 25 { return nil }
    if let domId = getString(el, "AXDOMIdentifier"), domId.contains(id) { return el }
    for child in getChildren(el) {
        if let f = findByDomId(child, id, depth: depth + 1) { return f }
    }
    return nil
}
func findFirst(_ el: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
    if depth > 25 { return nil }
    if getString(el, kAXRoleAttribute as String) == role { return el }
    for child in getChildren(el) {
        if let f = findFirst(child, role: role, depth: depth + 1) { return f }
    }
    return nil
}
func findBubbles(_ el: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    if depth > 25 { return [] }
    var results: [AXUIElement] = []
    if let domId = getString(el, "AXDOMIdentifier"), domId.hasPrefix("bubble-") {
        results.append(el)
    }
    for child in getChildren(el) {
        results.append(contentsOf: findBubbles(child, depth: depth + 1))
    }
    return results
}
func collectText(_ el: AXUIElement, depth: Int = 0) -> String {
    if depth > 30 { return "" }
    var texts: [String] = []
    let role = getString(el, kAXRoleAttribute as String) ?? ""
    if role == "AXStaticText" || role == "AXListMarker" {
        if let val = getString(el, kAXValueAttribute as String),
           !val.trimmingCharacters(in: .whitespaces).isEmpty {
            texts.append(val)
        }
        return texts.joined(separator: "\n")
    }
    for child in getChildren(el) {
        let t = collectText(child, depth: depth + 1)
        if !t.isEmpty { texts.append(t) }
    }
    return texts.joined(separator: "\n")
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundleId).first else {
    print("ERROR: Cursor not running"); exit(1)
}
let pid = app.processIdentifier
let appEl = AXUIElementCreateApplication(pid)

func freshWindow() -> AXUIElement? {
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)
    guard let ws = getAttr(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }
    return ws.first
}
func postKey(_ vk: CGKeyCode, flags: CGEventFlags? = nil) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let d = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)
    if let f = flags { d?.flags = f }
    let u = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)
    if let f = flags { u?.flags = f }
    d?.postToPid(pid)
    u?.postToPid(pid)
}
func currentBubbleIds() -> Set<String> {
    guard let w = freshWindow(),
          let p = findByDomId(w, "workbench.panel.aichat") else { return [] }
    return Set(findBubbles(p).compactMap { getString($0, "AXDOMIdentifier") })
}
func lastBubbleText() -> String {
    guard let w = freshWindow(),
          let p = findByDomId(w, "workbench.panel.aichat") else { return "" }
    guard let last = findBubbles(p).last else { return "" }
    return collectText(last).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Focus the AXTextArea INSIDE the chat panel (not the toolbar container).
func focusChatTextArea() -> Bool {
    guard let win = freshWindow() else { return false }

    if let chatPanel = findByDomId(win, "workbench.panel.aichat") {
        // Find the actual AXTextArea — the Monaco editor input
        if let textArea = findFirst(chatPanel, role: kAXTextAreaRole as String) {
            AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, true as CFTypeRef)
            AXUIElementPerformAction(textArea, kAXPressAction as CFString)
            print("  focused AXTextArea directly")
            return true
        }
        // Fallback: try clicking the chat panel area
        print("  AXTextArea not found, falling back to panel focus")
        AXUIElementSetAttributeValue(chatPanel, kAXFocusedAttribute as CFString, true as CFTypeRef)
        return true
    } else {
        // Panel closed — Cmd+L to open
        print("  panel closed, opening with Cmd+L")
        postKey(0x25, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 1.0)
        // Now focus the textarea in the newly opened panel
        if let w2 = freshWindow(), let cp2 = findByDomId(w2, "workbench.panel.aichat"),
           let ta = findFirst(cp2, role: kAXTextAreaRole as String) {
            AXUIElementSetAttributeValue(ta, kAXFocusedAttribute as CFString, true as CFTypeRef)
            AXUIElementPerformAction(ta, kAXPressAction as CFString)
            print("  focused AXTextArea after Cmd+L")
        }
        return freshWindow().flatMap { findByDomId($0, "workbench.panel.aichat") } != nil
    }
}

func ensurePanelOpen() {
    if freshWindow().flatMap({ findByDomId($0, "workbench.panel.aichat") }) != nil { return }
    print("  panel closed, reopening...")
    app.activate()
    Thread.sleep(forTimeInterval: 0.3)
    postKey(0x25, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 1.5)
}

// MARK: - Main
AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)
Thread.sleep(forTimeInterval: 0.5)
print("Connected to Cursor (pid=\(pid))")

let message = CommandLine.arguments.count > 1
    ? CommandLine.arguments.dropFirst().joined(separator: " ")
    : "Reply with one word: FIXED"
print("Sending: \(message)")

app.activate()
Thread.sleep(forTimeInterval: 0.5)
guard focusChatTextArea() else { print("ERROR: cannot focus input"); exit(1) }
Thread.sleep(forTimeInterval: 0.3)

let idsBefore = currentBubbleIds()
let textBefore = lastBubbleText()
print("  baseline: \(idsBefore.count) bubbles")

// Clear + type
postKey(0x00, flags: .maskCommand) // Cmd+A
Thread.sleep(forTimeInterval: 0.1)
postKey(0x33) // Delete
Thread.sleep(forTimeInterval: 0.3)

let src = CGEventSource(stateID: .combinedSessionState)
for (i, char) in message.unicodeScalars.enumerated() {
    if i % 100 == 0 && i > 0 { app.activate(); Thread.sleep(forTimeInterval: 0.05) }
    let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
    d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.value)])
    d?.postToPid(pid)
    let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
    u?.postToPid(pid)
    Thread.sleep(forTimeInterval: 0.01)
}
Thread.sleep(forTimeInterval: 0.5)

app.activate()
Thread.sleep(forTimeInterval: 0.1)
postKey(0x24) // Enter

// Verify
Thread.sleep(forTimeInterval: 3.0)
ensurePanelOpen()
Thread.sleep(forTimeInterval: 0.5)

let idsAfter = currentBubbleIds()
let newIds = idsAfter.subtracting(idsBefore)
if !newIds.isEmpty {
    print("Sent! (\(newIds.count) new)")
} else {
    print("ERROR: not delivered (no new bubble IDs)")
    exit(1)
}

// Echo detection — Cursor echoes the sent message while "thinking"
func isEcho(_ bubbleText: String, of sentText: String) -> Bool {
    let b = bubbleText.trimmingCharacters(in: .whitespacesAndNewlines)
    let s = sentText.trimmingCharacters(in: .whitespacesAndNewlines)
    if b.isEmpty || s.isEmpty { return false }
    if b == s { return true }
    if s.contains(b) && b.count > 20 { return true }
    if b.contains(s) { return true }
    if String(b.prefix(50)) == String(s.prefix(50)) && b.count >= 20 { return true }
    return false
}

// Poll
print("Polling for response...")
var lastText = ""; var stable = 0; var reopens = 0
for i in 0..<60 {
    Thread.sleep(forTimeInterval: 2.0)
    if currentBubbleIds().isEmpty && reopens < 5 {
        reopens += 1; ensurePanelOpen(); Thread.sleep(forTimeInterval: 1.0)
    }
    let text = lastBubbleText()
    if text.isEmpty || text == textBefore {
        print("  [\(i)] waiting...")
        continue
    }
    // Skip Cursor's echo of the sent message
    if isEcho(text, of: message) {
        print("  [\(i)] echo (skipping)")
        stable = 0
        continue
    }
    if text == lastText {
        stable += 1
        if stable >= 3 { print("\n--- Response ---"); print(text); exit(0) }
    } else {
        stable = 0; lastText = text; print("  [\(i)] streaming (len=\(text.count))")
    }
}
print("Timeout. Best: \(lastText.prefix(200))")
exit(1)
