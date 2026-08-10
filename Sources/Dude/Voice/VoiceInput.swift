import AVFoundation
import Foundation
import Speech

/// Live speech-to-text for talking to Dude. Wraps `SFSpeechRecognizer` +
/// `AVAudioEngine`: tap the mic, it streams partial transcripts, and stops on a
/// final result or when you tap again.
///
/// Needs microphone + speech-recognition permission (`NSMicrophoneUsageDescription`,
/// `NSSpeechRecognitionUsageDescription`); the first `start()` triggers the
/// prompts. Prefers on-device recognition when the locale supports it, so audio
/// doesn't leave the machine.
@MainActor
final class VoiceInput: ObservableObject {
    /// What he's heard so far (partial, updates live).
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    /// Set when something blocks recording (denied permission, unavailable).
    @Published private(set) var status: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Auto-finish once he's heard nothing new for this long.
    private let silenceTimeout: TimeInterval = 3
    private var silenceTask: Task<Void, Never>?

    /// Called once a final transcript is ready (mic released / silence).
    var onFinal: ((String) -> Void)?

    func toggle() {
        if isRecording { stop(final: true) } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        status = nil

        guard await requestSpeechAuth() else {
            status = "Speech recognition permission is off — enable it in System Settings ▸ Privacy & Security."
            return
        }
        guard await requestMicAuth() else {
            status = "Microphone permission is off — enable it in System Settings ▸ Privacy & Security."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            status = "Speech recognition isn't available right now."
            return
        }

        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            status = "No microphone input is available."
            return
        }

        // The tap fires on a realtime audio thread, so its closure must NOT be
        // main-actor isolated (VoiceInput is @MainActor) — mark it @Sendable and
        // carry the request in without isolation, or Swift traps the app the
        // moment audio starts flowing. `append` is thread-safe.
        nonisolated(unsafe) let tapRequest = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = "Couldn't start the mic: \(error.localizedDescription)"
            teardownAudio()
            return
        }

        isRecording = true
        // Same rule: the recognizer calls this back off the main actor. Compute
        // the plain Sendable values first, then hop to the main actor to publish.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty {
                    self.transcript = text
                    self.armSilenceTimer()   // reset the 4s window on each word
                }
                if done { self.stop(final: true) }
            }
        }
    }

    /// (Re)start the "stopped talking" countdown. Fires once he's heard nothing
    /// new for `silenceTimeout`, finishing the transcription for you.
    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.silenceTimeout ?? 3) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(final: true)
        }
    }

    /// Stop capturing. When `final`, hand the transcript off via `onFinal`.
    func stop(final: Bool) {
        guard isRecording else { return }
        isRecording = false
        silenceTask?.cancel()
        silenceTask = nil
        teardownAudio()
        task?.cancel()
        task = nil

        if final {
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onFinal?(text) }
        }
    }

    private func teardownAudio() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        request = nil
    }

    // MARK: - Permissions

    private func requestSpeechAuth() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private func requestMicAuth() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
