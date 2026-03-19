import Foundation
import Darwin
import AVFoundation
import Speech

enum BuckSpeakMode: String {
    case speak = "speak"
    case listen = "listen"
    case speakListen = "speak-listen"
}

struct BuckSpeakConfig {
    var mode: BuckSpeakMode?
    var text: String?
    var voice: String? = "Lee Premium"
    var rate: Int?
    var listenTimeoutMs: Int = 20000
    var silenceTimeoutMs: Int = 2500
    var localeIdentifier: String = Locale.current.identifier
}

private struct ResolvedVoice {
    let requested: String?
    let name: String?
    let identifier: String?
}

enum BuckSpeakCliError: Error {
    case message(String)
}

private func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
}

private func emitJson(
    _ response: BuckSpeakResponse
) {
    let payload: [String: Any] = [
        "status": response.status,
        "mode": response.mode,
        "spoken_text": jsonValue(response.spoken_text),
        "heard_text": jsonValue(response.heard_text),
        "speech_started_ms": jsonValue(response.speech_started_ms),
        "speech_ended_ms": jsonValue(response.speech_ended_ms),
        "duration_ms": response.duration_ms,
        "error": jsonValue(response.error),
        "requested_voice": jsonValue(response.requested_voice),
        "resolved_voice": jsonValue(response.resolved_voice),
        "resolved_voice_id": jsonValue(response.resolved_voice_id),
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

private func readStdinText() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        throw BuckSpeakCliError.message("stdin_decode_failed")
    }
    return text
}

private func usageText() -> String {
    """
    Usage:
      buck-speak.sh --speak --text "Hey ARIA"
      buck-speak.sh --listen
      buck-speak.sh --speak-listen --text "Hey ARIA"

    Options:
      --text TEXT             Text to speak
      --stdin                 Read text to speak from stdin
      --voice NAME            Optional macOS say voice name
      --rate WPM              Optional macOS say rate
      --listen-timeout MS     Listen timeout in milliseconds
      --silence-timeout MS    Silence timeout in milliseconds
      --locale ID             Optional speech recognizer locale
      --help                  Show this help
    """
}

private func parseArgs(_ arguments: [String], stdinText: String?) throws -> BuckSpeakConfig {
    var config = BuckSpeakConfig()
    var args = Array(arguments.dropFirst())

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            print(usageText())
            return config
        case "--speak":
            config.mode = .speak
        case "--listen":
            config.mode = .listen
        case "--speak-listen":
            config.mode = .speakListen
        case "--text":
            guard !args.isEmpty else { throw BuckSpeakCliError.message("missing_text") }
            config.text = args.removeFirst()
        case "--stdin":
            if let stdinText {
                config.text = stdinText
            } else {
                config.text = try readStdinText()
            }
        case "--voice":
            guard !args.isEmpty else { throw BuckSpeakCliError.message("missing_voice") }
            config.voice = args.removeFirst()
        case "--rate":
            guard !args.isEmpty, let value = Int(args.removeFirst()) else {
                throw BuckSpeakCliError.message("invalid_rate")
            }
            config.rate = value
        case "--listen-timeout":
            guard !args.isEmpty, let value = Int(args.removeFirst()), value > 0 else {
                throw BuckSpeakCliError.message("invalid_listen_timeout")
            }
            config.listenTimeoutMs = value
        case "--silence-timeout":
            guard !args.isEmpty, let value = Int(args.removeFirst()), value > 0 else {
                throw BuckSpeakCliError.message("invalid_silence_timeout")
            }
            config.silenceTimeoutMs = value
        case "--locale":
            guard !args.isEmpty else { throw BuckSpeakCliError.message("missing_locale") }
            config.localeIdentifier = args.removeFirst()
        default:
            throw BuckSpeakCliError.message("unknown_arg:\(arg)")
        }
    }

    return config
}

private func requestSpeechAuthorization() throws {
    let current = SFSpeechRecognizer.authorizationStatus()
    switch current {
    case .authorized:
        return
    case .denied, .restricted:
        throw BuckSpeakCliError.message("speech_permission_denied")
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        SFSpeechRecognizer.requestAuthorization { status in
            granted = (status == .authorized)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(10))
        if !granted {
            throw BuckSpeakCliError.message("speech_permission_denied")
        }
    @unknown default:
        throw BuckSpeakCliError.message("speech_permission_unknown")
    }
}

private func requestMicAuthorization() throws {
    let current = AVCaptureDevice.authorizationStatus(for: .audio)
    switch current {
    case .authorized:
        return
    case .denied, .restricted:
        throw BuckSpeakCliError.message("microphone_permission_denied")
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(10))
        if !granted {
            throw BuckSpeakCliError.message("microphone_permission_denied")
        }
    @unknown default:
        throw BuckSpeakCliError.message("microphone_permission_unknown")
    }
}

private func normalizedVoiceKey(_ value: String) -> String {
    value
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
}

private func resolveVoice(_ requestedVoice: String?) throws -> ResolvedVoice {
    guard let requestedVoice else {
        return ResolvedVoice(requested: nil, name: nil, identifier: nil)
    }

    let requested = requestedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requested.isEmpty else {
        return ResolvedVoice(requested: nil, name: nil, identifier: nil)
    }

    let voices = AVSpeechSynthesisVoice.speechVoices()

    if let exactName = voices.first(where: {
        $0.name.compare(requested, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }) {
        return ResolvedVoice(requested: requested, name: exactName.name, identifier: exactName.identifier)
    }

    if let exactIdentifier = voices.first(where: {
        $0.identifier.compare(requested, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }) {
        return ResolvedVoice(requested: requested, name: exactIdentifier.name, identifier: exactIdentifier.identifier)
    }

    let requestedKey = normalizedVoiceKey(requested)
    if let normalizedName = voices.first(where: { normalizedVoiceKey($0.name) == requestedKey }) {
        return ResolvedVoice(requested: requested, name: normalizedName.name, identifier: normalizedName.identifier)
    }

    throw BuckSpeakCliError.message("voice_unavailable:\(requested)")
}

private func runSay(text: String, voice: ResolvedVoice, rate: Int?) throws -> Int {
    let start = DispatchTime.now().uptimeNanoseconds
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    var args: [String] = []
    if let voiceName = voice.name, !voiceName.isEmpty {
        args += ["-v", voiceName]
    }
    if let rate {
        args += ["-r", String(rate)]
    }
    args.append(text)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw BuckSpeakCliError.message("say_failed")
    }
    return Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

private final class BuckSpeakListener {
    private let listenTimeoutMs: Int
    private let silenceTimeoutMs: Int
    private let localeIdentifier: String
    private let offsetMs: Int
    private let startNs = DispatchTime.now().uptimeNanoseconds
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: DispatchSourceTimer?

    private var finished = false
    private var status = "timeout"
    private var errorCode: String?
    private var heardText = ""
    private var speechStartedMs: Int?
    private var speechEndedMs: Int?
    private var lastSignalMs: Int?

    init(listenTimeoutMs: Int, silenceTimeoutMs: Int, localeIdentifier: String, offsetMs: Int) {
        self.listenTimeoutMs = listenTimeoutMs
        self.silenceTimeoutMs = silenceTimeoutMs
        self.localeIdentifier = localeIdentifier
        self.offsetMs = offsetMs
    }

    func run(
        mode: BuckSpeakMode,
        spokenText: String?,
        requestedVoice: String?,
        resolvedVoice: String?,
        resolvedVoiceId: String?
    ) -> BuckSpeakResponse {
        do {
            try requestMicAuthorization()
            try requestSpeechAuthorization()
            try startRecognition()
            semaphore.wait()
            return BuckSpeakResponse(
                status: status,
                mode: mode.rawValue,
                spoken_text: spokenText,
                heard_text: heardText.isEmpty ? nil : heardText,
                speech_started_ms: speechStartedMs,
                speech_ended_ms: speechEndedMs,
                duration_ms: durationMs,
                error: errorCode,
                requested_voice: requestedVoice,
                resolved_voice: resolvedVoice,
                resolved_voice_id: resolvedVoiceId
            )
        } catch let error as BuckSpeakCliError {
            return BuckSpeakResponse(
                status: "error",
                mode: mode.rawValue,
                spoken_text: spokenText,
                heard_text: nil,
                speech_started_ms: nil,
                speech_ended_ms: nil,
                duration_ms: 0,
                error: message(for: error),
                requested_voice: requestedVoice,
                resolved_voice: resolvedVoice,
                resolved_voice_id: resolvedVoiceId
            )
        } catch {
            return BuckSpeakResponse(
                status: "error",
                mode: mode.rawValue,
                spoken_text: spokenText,
                heard_text: nil,
                speech_started_ms: nil,
                speech_ended_ms: nil,
                duration_ms: 0,
                error: "listen_failed",
                requested_voice: requestedVoice,
                resolved_voice: resolvedVoice,
                resolved_voice_id: resolvedVoiceId
            )
        }
    }

    private var durationMs: Int {
        if let start = speechStartedMs, let end = speechEndedMs, end >= start {
            return end - start
        }
        return max(0, nowMs() - offsetMs)
    }

    private func nowMs() -> Int {
        offsetMs + Int((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000)
    }

    private func startRecognition() throws {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw BuckSpeakCliError.message("speech_recognizer_unavailable")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result: result, error: error)
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "buckspeak.timer"))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        guard rms > 0.015 else { return }
        markSignal()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lock.lock()
                heardText = text
                lock.unlock()
                markSignal()
            }
            if result.isFinal {
                finish(status: "ok", error: nil)
                return
            }
        }

        if let error {
            lock.lock()
            let hasTranscript = !heardText.isEmpty
            lock.unlock()
            if hasTranscript {
                finish(status: "ok", error: nil)
            } else {
                finish(status: "error", error: "speech_recognition_error:\(error.localizedDescription)")
            }
        }
    }

    private func markSignal() {
        let now = nowMs()
        lock.lock()
        if speechStartedMs == nil {
            speechStartedMs = now
        }
        lastSignalMs = now
        speechEndedMs = now
        lock.unlock()
    }

    private func tick() {
        let now = nowMs()

        lock.lock()
        let localFinished = finished
        let localSpeechStarted = speechStartedMs
        let localLastSignal = lastSignalMs
        let hasTranscript = !heardText.isEmpty
        lock.unlock()

        if localFinished {
            return
        }

        if now >= listenTimeoutMs + offsetMs {
            finish(status: hasTranscript ? "ok" : "timeout", error: nil)
            return
        }

        if let speechStarted = localSpeechStarted,
           let lastSignal = localLastSignal,
           now - max(speechStarted, lastSignal) >= silenceTimeoutMs {
            finish(status: hasTranscript ? "ok" : "timeout", error: nil)
        }
    }

    private func finish(status: String, error: String?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        self.status = status
        self.errorCode = error
        if speechEndedMs == nil, let lastSignalMs {
            speechEndedMs = lastSignalMs
        }
        lock.unlock()

        timer?.cancel()
        timer = nil
        request?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        semaphore.signal()
    }
}

private func message(for error: BuckSpeakCliError) -> String {
    switch error {
    case .message(let message):
        return message
    }
}

enum BuckSpeakCLI {
    private static let triggerFlags: Set<String> = ["--help", "-h", "--speak", "--listen", "--speak-listen"]

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { triggerFlags.contains($0) }
    }

    static func run(arguments: [String]) -> Int32 {
        if arguments.dropFirst().contains("--help") || arguments.dropFirst().contains("-h") {
            print(usageText())
            return 0
        }

        let response = runResponse(arguments: arguments, stdinText: nil)
        emitJson(response)
        return response.status == "error" ? 1 : 0
    }

    static func runResponse(arguments: [String], stdinText: String?) -> BuckSpeakResponse {
        do {
            let config = try parseArgs(arguments, stdinText: stdinText)

            guard let mode = config.mode else {
                throw BuckSpeakCliError.message("missing_mode")
            }

            switch mode {
            case .speak:
                let spoken = config.text ?? ""
                let voice = try resolveVoice(config.voice)
                let durationMs = try runSay(text: spoken, voice: voice, rate: config.rate)
                return BuckSpeakResponse(
                    status: "ok",
                    mode: mode.rawValue,
                    spoken_text: spoken,
                    heard_text: nil,
                    speech_started_ms: 0,
                    speech_ended_ms: durationMs,
                    duration_ms: durationMs,
                    error: nil,
                    requested_voice: voice.requested,
                    resolved_voice: voice.name,
                    resolved_voice_id: voice.identifier
                )

            case .listen:
                let listener = BuckSpeakListener(
                    listenTimeoutMs: config.listenTimeoutMs,
                    silenceTimeoutMs: config.silenceTimeoutMs,
                    localeIdentifier: config.localeIdentifier,
                    offsetMs: 0
                )
                return listener.run(
                    mode: mode,
                    spokenText: nil,
                    requestedVoice: nil,
                    resolvedVoice: nil,
                    resolvedVoiceId: nil
                )

            case .speakListen:
                let spoken = config.text ?? ""
                let voice = try resolveVoice(config.voice)
                let spokenDurationMs = try runSay(text: spoken, voice: voice, rate: config.rate)
                usleep(150_000)
                let listener = BuckSpeakListener(
                    listenTimeoutMs: config.listenTimeoutMs,
                    silenceTimeoutMs: config.silenceTimeoutMs,
                    localeIdentifier: config.localeIdentifier,
                    offsetMs: spokenDurationMs + 150
                )
                return listener.run(
                    mode: mode,
                    spokenText: spoken,
                    requestedVoice: voice.requested,
                    resolvedVoice: voice.name,
                    resolvedVoiceId: voice.identifier
                )
            }
        } catch let error as BuckSpeakCliError {
            return BuckSpeakResponse(
                status: "error",
                mode: "bootstrap",
                spoken_text: nil,
                heard_text: nil,
                speech_started_ms: nil,
                speech_ended_ms: nil,
                duration_ms: 0,
                error: message(for: error),
                requested_voice: nil,
                resolved_voice: nil,
                resolved_voice_id: nil
            )
        } catch {
            return BuckSpeakResponse(
                status: "error",
                mode: "bootstrap",
                spoken_text: nil,
                heard_text: nil,
                speech_started_ms: nil,
                speech_ended_ms: nil,
                duration_ms: 0,
                error: "unexpected_error",
                requested_voice: nil,
                resolved_voice: nil,
                resolved_voice_id: nil
            )
        }
    }
}
