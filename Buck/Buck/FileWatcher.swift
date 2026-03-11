import Foundation

final class FileWatcher {
    static let inboxURL: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buck/inbox")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var knownFiles: Set<String> = []
    private let onNewFile: (URL) -> Void

    init(onNewFile: @escaping (URL) -> Void) {
        self.onNewFile = onNewFile

        // Only clean stale .tmp files (incomplete writes) — never delete .json
        // .json files in inbox/outbox may be actively polled by buck-review.sh
        Self.clearStaleTmpFiles(Self.inboxURL)
        Self.clearStaleTmpFiles(ResponseWriter.outboxURL)

        NSLog("[Buck] FileWatcher init, inbox: %@", Self.inboxURL.path)

        startFSEventWatcher()
        startPollingFallback()
    }

    private static func clearStaleTmpFiles(_ url: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        var count = 0
        for file in contents where file.pathExtension == "tmp" {
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modDate < cutoff {
                try? FileManager.default.removeItem(at: file)
                count += 1
            }
        }
        if count > 0 { NSLog("[Buck] Cleared %d stale .tmp files from %@", count, url.lastPathComponent) }
    }

    // Primary: DispatchSource file system events
    private func startFSEventWatcher() {
        let path = Self.inboxURL.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[Buck] Failed to open inbox fd for path: %@", path)
            return
        }
        NSLog("[Buck] Opened inbox fd=%d for path: %@", fd, path)

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .link],
            queue: .global(qos: .userInitiated)
        )

        source?.setEventHandler { [weak self] in
            NSLog("[Buck] FS event triggered")
            self?.checkForNewFiles()
        }

        source?.setCancelHandler {
            close(fd)
        }

        source?.resume()
    }

    // Fallback: poll every 2 seconds in case FS events are missed
    private func startPollingFallback() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2.0)
        t.setEventHandler { [weak self] in
            self?.checkForNewFiles()
        }
        t.resume()
        timer = t
    }

    private func checkForNewFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.inboxURL,
            includingPropertiesForKeys: nil
        ) else {
            NSLog("[Buck] Failed to read inbox directory")
            return
        }

        let jsonFiles = contents.filter {
            $0.pathExtension == "json" && !knownFiles.contains($0.lastPathComponent)
        }

        for file in jsonFiles {
            NSLog("[Buck] New file detected: %@", file.lastPathComponent)
            knownFiles.insert(file.lastPathComponent)

            // Brief delay to ensure file write is complete
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                NSLog("[Buck] Processing file: %@", file.lastPathComponent)
                self?.onNewFile(file)
            }
        }
    }

    deinit {
        source?.cancel()
        timer?.cancel()
    }
}
