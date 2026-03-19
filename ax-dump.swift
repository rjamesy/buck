#!/usr/bin/env swift
// Quick AX tree dump of ChatGPT to diagnose navigation failures
import ApplicationServices
import AppKit

func getRole(_ el: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
    return (v as? String) ?? "?"
}

func getChildren(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
    return (v as? [AXUIElement]) ?? []
}

func getStr(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, attr as CFString, &v)
    return v as? String
}

func dump(_ el: AXUIElement, indent: Int = 0, maxDepth: Int = 8) {
    if indent > maxDepth { return }
    let pad = String(repeating: "  ", count: indent)
    let role = getRole(el)
    let children = getChildren(el)
    let val = getStr(el, kAXValueAttribute)
    let desc = getStr(el, kAXDescriptionAttribute)
    let help = getStr(el, kAXHelpAttribute)

    var info = "\(pad)\(role) [\(children.count) children]"
    if let v = val { info += " val=\"\(String(v.prefix(60)))\"" }
    if let d = desc { info += " desc=\"\(String(d.prefix(60)))\"" }
    if let h = help { info += " help=\"\(String(h.prefix(60)))\"" }
    print(info)

    for child in children {
        dump(child, indent: indent + 1, maxDepth: maxDepth)
    }
}

guard AXIsProcessTrusted() else {
    print("ERROR: Not AX trusted")
    exit(1)
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chat").first else {
    print("ERROR: ChatGPT not running")
    exit(1)
}

let appEl = AXUIElementCreateApplication(app.processIdentifier)

// Get focused window first, fallback to first window
var windowEl: AXUIElement?
var focused: CFTypeRef?
if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focused) == .success {
    windowEl = (focused as! AXUIElement)
    print("Using: focused window")
} else {
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wins)
    windowEl = (wins as? [AXUIElement])?.first
    print("Using: first window (no focused window)")
}

guard let window = windowEl else {
    print("ERROR: No window")
    exit(1)
}

print("\n=== ChatGPT AX Tree (depth 8) ===\n")
dump(window, maxDepth: 8)

// Now try the exact navigation path Buck uses
print("\n=== Buck Navigation Path ===\n")

let windowChildren = getChildren(window)
print("Window children: \(windowChildren.count)")
guard let mainGroup = windowChildren.first(where: { getRole($0) == kAXGroupRole }) else {
    print("FAIL: No AXGroup child of window")
    exit(0)
}
print("mainGroup: \(getRole(mainGroup)) [\(getChildren(mainGroup).count) children]")

let mainGroupChildren = getChildren(mainGroup)
for (i, c) in mainGroupChildren.enumerated() {
    print("  mainGroup[\(i)]: \(getRole(c)) [\(getChildren(c).count) children]")
}

guard let splitGroup = mainGroupChildren.first(where: { getRole($0) == "AXSplitGroup" }) else {
    print("FAIL: No AXSplitGroup in mainGroup")
    exit(0)
}
print("splitGroup: AXSplitGroup [\(getChildren(splitGroup).count) children]")

let sgChildren = getChildren(splitGroup).filter { getRole($0) == kAXGroupRole }
print("splitGroup groups: \(sgChildren.count)")
for (i, g) in sgChildren.enumerated() {
    let cc = getChildren(g).count
    print("  group[\(i)]: \(cc) children")
}

guard let chatPane = sgChildren.max(by: { getChildren($0).count < getChildren($1).count }) else {
    print("FAIL: No chat pane")
    exit(0)
}
print("chatPane (max children): \(getChildren(chatPane).count) children")

// Find scroll area
let chatPaneChildren = getChildren(chatPane)
print("\nChat pane children roles:")
for (i, c) in chatPaneChildren.enumerated() {
    print("  [\(i)]: \(getRole(c)) [\(getChildren(c).count) children]")
}

guard let scrollArea = chatPaneChildren.first(where: { getRole($0) == kAXScrollAreaRole }) else {
    print("FAIL: No AXScrollArea in chatPane")
    exit(0)
}
print("\nscrollArea children:")
for (i, c) in getChildren(scrollArea).enumerated() {
    print("  [\(i)]: \(getRole(c)) [\(getChildren(c).count) children]")
}

guard let outerList = getChildren(scrollArea).first(where: { getRole($0) == kAXListRole }) else {
    print("FAIL: No outer AXList in scrollArea")
    exit(0)
}
print("outerList: \(getChildren(outerList).count) children")

guard let innerList = getChildren(outerList).first(where: { getRole($0) == kAXListRole }) else {
    print("FAIL: No inner AXList in outerList")
    // Show what's actually in outerList
    for (i, c) in getChildren(outerList).enumerated() {
        print("  outerList[\(i)]: \(getRole(c)) [\(getChildren(c).count) children]")
    }
    exit(0)
}
print("innerList: \(getChildren(innerList).count) children")

let groups = getChildren(innerList).filter { getRole($0) == kAXGroupRole }
print("message groups: \(groups.count)")

for (i, g) in groups.enumerated() {
    let children = getChildren(g)
    print("  group[\(i)]: \(children.count) children")
    for (j, child) in children.enumerated() {
        let grandchildren = getChildren(child)
        print("    child[\(j)]: \(getRole(child)) [\(grandchildren.count) children]")
    }
}
