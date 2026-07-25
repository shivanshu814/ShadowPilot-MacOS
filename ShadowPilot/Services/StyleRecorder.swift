import AVFoundation
import Speech

// Records the USER's own voice from the microphone and transcribes it.
// Used once during setup to capture how the user actually speaks English —
// the transcript becomes the style sample the LLM mimics in every answer.
// Distinct from SpeechRecognizer, which transcribes SYSTEM audio (the interviewer).
@MainActor
final class StyleRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var liveText = ""

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // locale should match the user's accent (e.g. en-IN) — recognition is far
    // more accurate when the recognizer expects that accent.
    func start(locale: String) {
        guard !isRecording else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { return }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }   // no input device
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            DispatchQueue.main.async { self?.liveText = text }
        }

        liveText = ""
        isRecording = true
    }

    // Returns the final transcript of what was said.
    @discardableResult
    func stop() -> String {
        guard isRecording else { return liveText }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        return liveText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
