import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let buckFolder = "/Users/rjamesy/Mac Projects/buck"
    private static let scriptPath = "\(buckFolder)/buck-speak.sh"

    private var statusItem: NSStatusItem!
    private var inboxTimer: Timer?
    private var isProcessingRequest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? BuckSpeakIPC.ensureDirectories()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "BuckSpeak")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "BuckSpeak"
        }

        statusItem.menu = buildMenu()
        startInboxPolling()
    }

    private func startInboxPolling() {
        inboxTimer?.invalidate()
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollInbox()
        }
    }

    private func pollInbox() {
        guard !isProcessingRequest else { return }
        guard let pendingRequests = try? BuckSpeakIPC.pendingRequestURLs(),
              let requestURL = pendingRequests.first else { return }

        let processingURL = requestURL.deletingPathExtension().appendingPathExtension("processing")
        do {
            try FileManager.default.moveItem(at: requestURL, to: processingURL)
        } catch {
            return
        }

        isProcessingRequest = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: processingURL)
                DispatchQueue.main.async {
                    self?.isProcessingRequest = false
                }
            }

            guard let request = try? BuckSpeakIPC.readRequest(at: processingURL) else { return }
            let response = BuckSpeakCLI.runResponse(arguments: ["BuckSpeak"] + request.arguments, stdinText: request.stdinText)
            try? BuckSpeakIPC.writeResponse(response, id: request.id)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let exists = FileManager.default.isExecutableFile(atPath: Self.scriptPath)

        let statusTitle = exists ? "BuckSpeak running" : "BuckSpeak running (script missing)"
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let pathLine = NSMenuItem(title: "Script: \(Self.scriptPath)", action: nil, keyEquivalent: "")
        pathLine.isEnabled = false
        menu.addItem(pathLine)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Script", action: #selector(openScript), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Open Buck Folder", action: #selector(openBuckFolder), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        return menu
    }

    @objc private func openScript() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.scriptPath))
    }

    @objc private func openBuckFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.buckFolder))
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@main
enum BuckSpeakEntrypoint {
    static func main() {
        if BuckSpeakCLI.shouldRun(arguments: CommandLine.arguments) {
            exit(BuckSpeakCLI.run(arguments: CommandLine.arguments))
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
