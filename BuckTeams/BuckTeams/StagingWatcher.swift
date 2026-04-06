import Foundation

final class StagingWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var knownFiles: Set<String> = []
    private let onNewStaging: (StagingMessage) -> Void
    private let decoder = JSONDecoder()

    init(onNewStaging: @escaping (StagingMessage) -> Void) {
        self.onNewStaging = onNewStaging
        startFSEventWatcher()
    }

    private func startFSEventWatcher() {
        let path = TeamsPaths.staging.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            TeamsLog.log("StagingWatcher: failed to open fd for \(path)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .link],
            queue: .global(qos: .userInitiated)
        )

        source?.setEventHandler { [weak self] in
            self?.checkForNewFiles()
        }

        source?.setCancelHandler {
            close(fd)
        }

        source?.resume()
        TeamsLog.log("StagingWatcher: watching \(path)")
    }

    func checkForNewFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: TeamsPaths.staging, includingPropertiesForKeys: nil
        ) else { return }

        let jsonFiles = contents.filter {
            $0.pathExtension == "json" && !knownFiles.contains($0.lastPathComponent)
        }

        for file in jsonFiles {
            knownFiles.insert(file.lastPathComponent)

            // Brief delay for write completion
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.processFile(file)
            }
        }
    }

    private static let failedDir: URL = {
        let url = TeamsPaths.staging.appendingPathComponent("failed")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func processFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            TeamsLog.log("StagingWatcher: could not read \(url.lastPathComponent)")
            moveToFailed(url)
            return
        }

        do {
            let staging = try decoder.decode(StagingMessage.self, from: data)
            // Delete staging file after successful parse
            try? FileManager.default.removeItem(at: url)
            TeamsLog.log("StagingWatcher: received from \(staging.from.rawValue): \(staging.content.prefix(50))")
            onNewStaging(staging)
        } catch {
            TeamsLog.log("StagingWatcher: malformed JSON in \(url.lastPathComponent): \(error)")
            moveToFailed(url)
        }
    }

    private func moveToFailed(_ url: URL) {
        let dest = Self.failedDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    deinit {
        source?.cancel()
    }
}
