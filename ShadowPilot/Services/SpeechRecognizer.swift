import Speech
import AVFoundation

class SpeechRecognizer {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var finalTranscript = ""

    func start(onPartial: @escaping (String) -> Void) {
        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true

        task = recognizer?.recognitionTask(with: request!) { result, _ in
            if let text = result?.bestTranscription.formattedString {
                DispatchQueue.main.async { onPartial(text) }
                if result?.isFinal == true { self.finalTranscript = text }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() -> String {
        request?.endAudio()
        task?.cancel()
        let result = finalTranscript
        request = nil
        task = nil
        finalTranscript = ""
        return result
    }
}
