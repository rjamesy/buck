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

func focusChatInput() -> Bool {
    guard let win = freshWindow() else { return false }
    if let chatPanel = findByDomId(win, "workbench.panel.aichat") {
        // Panel open — focus via AX (never Cmd+L which toggles)
        if let composer = findByDomId(chatPanel, "composer-toolbar-section") {
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, true as CFTypeRef)
            AXUIElementPerformAction(composer, kAXPressAction as CFString)
        } else {
            AXUIElementSetAttributeValue(chatPanel, kAXFocusedAttribute as CFString, true as CFTypeRef)
        }
        Thread.sleep(forTimeInterval: 0.3)
        return true
    } else {
        // Panel closed — Cmd+L to open
        postKey(0x25, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 1.0)
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

let args = CommandLine.arguments.dropFirst()
if args.isEmpty {
    print("Usage: test-cursor-bridge [count|read|send <msg>]")
    exit(0)
}

if args.first == "count" {
    guard let w = freshWindow(), let p = findByDomId(w, "workbench.panel.aichat") else {
        print("Panel not found"); exit(1)
    }
    let bubs = findBubbles(p)
    print("Bubbles: \(bubs.count)")
    for (i, b) in bubs.enumerated() {
        let id = getString(b, "AXDOMIdentifier") ?? "?"
        let t = String(collectText(b).prefix(100)).replacingOccurrences(of: "\n", with: " ")
        print("  [\(i)] \(id): \(t)")
    }
    exit(0)
}

if args.first == "read" {
    print(lastBubbleText())
    exit(0)
}

// --- SEND ---
let message = (args.first == "send" ? args.dropFirst() : args).joined(separator: " ")
print("Sending: \(message)")

app.activate()
Thread.sleep(forTimeInterval: 0.5)
guard focusChatInput() else { print("ERROR: cannot focus input"); exit(1) }

// Snapshot BEFORE send — this is the baseline for all subsequent checks
let idsBefore = currentBubbleIds()
let textBefore = lastBubbleText()
print("  baseline: \(idsBefore.count) bubbles")

for attempt in 1...3 {
    if attempt > 1 {
        print("  retry \(attempt)/3...")
        app.activate()
        Thread.sleep(forTimeInterval: 0.3)
        _ = focusChatInput()
        Thread.sleep(forTimeInterval: 0.3)
    }

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

    // Verify — new bubble IDs?
    Thread.sleep(forTimeInterval: 3.0)
    ensurePanelOpen()
    Thread.sleep(forTimeInterval: 0.5)

    let idsAfter = currentBubbleIds()
    let newIds = idsAfter.subtracting(idsBefore)
    if !newIds.isEmpty {
        print("Sent! (\(newIds.count) new)")
        break
    }
    if attempt == 3 { print("ERROR: not delivered after 3 attempts"); exit(1) }
}

// --- POLL ---
// Use idsBefore (pre-send baseline) for response detection.
// The user's bubble + response bubble are BOTH "new" relative to this.
// We detect the response by: text of last bubble differs from textBefore.
print("Polling for response...")
var lastText = ""
var stable = 0
var reopens = 0

for i in 0..<30 {
    Thread.sleep(forTimeInterval: 2.0)

    if currentBubbleIds().isEmpty && reopens < 5 {
        reopens += 1
        ensurePanelOpen()
        Thread.sleep(forTimeInterval: 1.0)
    }

    let text = lastBubbleText()
    if text.isEmpty || text == textBefore {
        // Check if new IDs appeared (response might have different text structure)
        let curIds = currentBubbleIds()
        let newCount = curIds.subtracting(idsBefore).count
        print("  [\(i)] waiting... (new=\(newCount))")
        continue
    }

    if text == lastText {
        stable += 1
        if stable >= 3 {
            print("\n--- Response ---")
            print(text)
            exit(0)
        }
    } else {
        stable = 0
        lastText = text
        print("  [\(i)] streaming (len=\(text.count))")
    }
}

print("Timeout. Best: \(lastText.prefix(300))")
exit(1)
