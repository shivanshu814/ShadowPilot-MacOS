import Speech
import AVFoundation

class SpeechRecognizer {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onPartial: ((String) -> Void)?

    var isRunning: Bool { task != nil }

    func start(onPartial: @escaping (String) -> Void) {
        self.onPartial = onPartial
        beginTask()
    }

    // Fresh transcription buffer WITHOUT stopping audio capture — used in auto mode
    // so the next question starts accumulating while the current answer streams.
    func restartBuffer() {
        endTask()
        onPartial?("")
        beginTask()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        endTask()
        onPartial = nil
    }

    // MARK: - Private

    private func beginTask() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let text = result?.bestTranscription.formattedString else { return }
            DispatchQueue.main.async { self.onPartial?(text) }
        }
    }

    private func endTask() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}
