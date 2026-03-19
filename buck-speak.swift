#!/usr/bin/env swift

import Foundation
import Darwin
import AVFoundation
import Speech

enum Mode: String {
    case speak = "speak"
    case listen = "listen"
    case speakListen = "speak-listen"
}

struct Config {
    var mode: Mode?
    var text: String?
    var voice: String?
    var rate: Int?
    var listenTimeoutMs: Int = 20000
    var silenceTimeoutMs: Int = 2500
    var localeIdentifier: String = Locale.current.identifier
}

enum CliError: Error {
    case message(String)
}

func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
}

func emitJson(
    status: String,
    mode: String,
    spokenText: String?,
    heardText: String?,
    speechStartedMs: Int?,
    speechEndedMs: Int?,
    durationMs: Int,
    error: String?
) {
    let payload: [String: Any] = [
        "status": status,
        "mode": mode,
        "spoken_text": jsonValue(spokenText),
        "heard_text": jsonValue(heardText),
        "speech_started_ms": jsonValue(speechStartedMs),
        "speech_ended_ms": jsonValue(speechEndedMs),
        "duration_ms": durationMs,
        "error": jsonValue(error),
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func readStdinText() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        throw CliError.message("stdin_decode_failed")
    }
    return text
}

func parseArgs() throws -> Config {
    var config = Config()
    var args = Array(CommandLine.arguments.dropFirst())

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            let help = """
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
            print(help)
            exit(0)
        case "--speak":
            config.mode = .speak
        case "--listen":
            config.mode = .listen
        case "--speak-listen":
            config.mode = .speakListen
        case "--text":
            guard !args.isEmpty else { throw CliError.message("missing_text") }
            config.text = args.removeFirst()
        case "--stdin":
            config.text = try readStdinText()
        case "--voice":
            guard !args.isEmpty else { throw CliError.message("missing_voice") }
            config.voice = args.removeFirst()
        case "--rate":
            guard !args.isEmpty, let value = Int(args.removeFirst()) else {
                throw CliError.message("invalid_rate")
            }
            config.rate = value
        case "--listen-timeout":
            guard !args.isEmpty, let value = Int(args.removeFirst()), value > 0 else {
                throw CliError.message("invalid_listen_timeout")
            }
            config.listenTimeoutMs = value
        case "--silence-timeout":
            guard !args.isEmpty, let value = Int(args.removeFirst()), value > 0 else {
                throw CliError.message("invalid_silence_timeout")
            }
            config.silenceTimeoutMs = value
        case "--locale":
            guard !args.isEmpty else { throw CliError.message("missing_locale") }
            config.localeIdentifier = args.removeFirst()
        default:
            throw CliError.message("unknown_arg:\(arg)")
        }
    }

    guard let mode = config.mode else {
        throw CliError.message("missing_mode")
    }

    if mode == .speak || mode == .speakListen {
        let trimmed = config.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw CliError.message("missing_text")
        }
        config.text = trimmed
    }

    return config
}

func requestSpeechAuthorization() throws {
    let current = SFSpeechRecognizer.authorizationStatus()
    switch current {
    case .authorized:
        return
    case .denied, .restricted:
        throw CliError.message("speech_permission_denied")
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        SFSpeechRecognizer.requestAuthorization { status in
            granted = (status == .authorized)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(10))
        if !granted {
            throw CliError.message("speech_permission_denied")
        }
    @unknown default:
        throw CliError.message("speech_permission_unknown")
    }
}

func requestMicAuthorization() throws {
    let current = AVCaptureDevice.authorizationStatus(for: .audio)
    switch current {
    case .authorized:
        return
    case .denied, .restricted:
        throw CliError.message("microphone_permission_denied")
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(10))
        if !granted {
            throw CliError.message("microphone_permission_denied")
        }
    @unknown default:
        throw CliError.message("microphone_permission_unknown")
    }
}

func runSay(text: String, voice: String?, rate: Int?) throws -> Int {
    let start = DispatchTime.now().uptimeNanoseconds
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    var args: [String] = []
    if let voice, !voice.isEmpty {
        args += ["-v", voice]
    }
    if let rate {
        args += ["-r", String(rate)]
    }
    args.append(text)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw CliError.message("say_failed")
    }
    return Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

final class Listener {
    private let listenTimeoutMs: Int
    private let silenceTimeoutMs: Int
    private let localeIdentifier: String
    private let offsetMs: Int
    private let startNs = DispatchTime.now().uptimeNanoseconds
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    private var audioEngine = AVAudioEngine()
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

    func run(mode: Mode, spokenText: String?) -> Int32 {
        do {
            try requestMicAuthorization()
            try requestSpeechAuthorization()
            try startRecognition()
            semaphore.wait()
            emitJson(
                status: status,
                mode: mode.rawValue,
                spokenText: spokenText,
                heardText: heardText.isEmpty ? nil : heardText,
                speechStartedMs: speechStartedMs,
                speechEndedMs: speechEndedMs,
                durationMs: durationMs,
                error: errorCode
            )
            return status == "error" ? 1 : 0
        } catch let error as CliError {
            emitJson(
                status: "error",
                mode: mode.rawValue,
                spokenText: spokenText,
                heardText: nil,
                speechStartedMs: nil,
                speechEndedMs: nil,
                durationMs: 0,
                error: message(for: error)
            )
            return 1
        } catch {
            emitJson(
                status: "error",
                mode: mode.rawValue,
                spokenText: spokenText,
                heardText: nil,
                speechStartedMs: nil,
                speechEndedMs: nil,
                durationMs: 0,
                error: "listen_failed"
            )
            return 1
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
            throw CliError.message("speech_recognizer_unavailable")
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

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "buck.speak.timer"))
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

func message(for error: CliError) -> String {
    switch error {
    case .message(let message):
        return message
    }
}

func main() -> Int32 {
    do {
        let config = try parseArgs()
        guard let mode = config.mode else {
            throw CliError.message("missing_mode")
        }

        switch mode {
        case .speak:
            let spoken = config.text ?? ""
            let durationMs = try runSay(text: spoken, voice: config.voice, rate: config.rate)
            emitJson(
                status: "ok",
                mode: mode.rawValue,
                spokenText: spoken,
                heardText: nil,
                speechStartedMs: 0,
                speechEndedMs: durationMs,
                durationMs: durationMs,
                error: nil
            )
            return 0

        case .listen:
            let listener = Listener(
                listenTimeoutMs: config.listenTimeoutMs,
                silenceTimeoutMs: config.silenceTimeoutMs,
                localeIdentifier: config.localeIdentifier,
                offsetMs: 0
            )
            return listener.run(mode: mode, spokenText: nil)

        case .speakListen:
            let spoken = config.text ?? ""
            let spokenDurationMs = try runSay(text: spoken, voice: config.voice, rate: config.rate)
            usleep(150_000)
            let listener = Listener(
                listenTimeoutMs: config.listenTimeoutMs,
                silenceTimeoutMs: config.silenceTimeoutMs,
                localeIdentifier: config.localeIdentifier,
                offsetMs: spokenDurationMs + 150
            )
            return listener.run(mode: mode, spokenText: spoken)
        }
    } catch let error as CliError {
        emitJson(
            status: "error",
            mode: "bootstrap",
            spokenText: nil,
            heardText: nil,
            speechStartedMs: nil,
            speechEndedMs: nil,
            durationMs: 0,
            error: message(for: error)
        )
        return 1
    } catch {
        emitJson(
            status: "error",
            mode: "bootstrap",
            spokenText: nil,
            heardText: nil,
            speechStartedMs: nil,
            speechEndedMs: nil,
            durationMs: 0,
            error: "unexpected_error"
        )
        return 1
    }
}

exit(main())
