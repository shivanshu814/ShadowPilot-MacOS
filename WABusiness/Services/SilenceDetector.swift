import AVFoundation

// Detects silence in the audio stream — fires callback after `threshold` seconds of quiet.
// Only arms AFTER speech has been heard (never fires on pre-speech silence),
// and re-arms automatically when speech resumes after a fire.
final class SilenceDetector {
    var onSilence: (() -> Void)?

    // Adjustable at runtime (SetupView slider, 0.3–2.0s)
    var silenceThreshold: Double

    private let rmsFloor: Float = 0.01        // RMS below this = silence
    private var silenceStart: Date?
    private var hasHeardSpeech = false
    private var armed = true                  // false between a fire and the next speech

    init(threshold: Double = 0.9) {
        self.silenceThreshold = threshold
    }

    func reset() {
        silenceStart = nil
        hasHeardSpeech = false
        armed = true
    }

    func process(buffer: AVAudioPCMBuffer) {
        let rms = calculateRMS(buffer)

        if rms >= rmsFloor {
            // Speech — arm (or re-arm after a previous fire) and clear the timer
            hasHeardSpeech = true
            armed = true
            silenceStart = nil
            return
        }

        // Silence — only counts once speech has been heard and we're armed
        guard hasHeardSpeech, armed else { return }
        if silenceStart == nil { silenceStart = Date() }
        if let start = silenceStart,
           Date().timeIntervalSince(start) >= silenceThreshold {
            armed = false          // one fire per speech burst; next speech re-arms
            silenceStart = nil
            DispatchQueue.main.async { self.onSilence?() }
        }
    }

    private func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return sqrt(sum / Float(count))
    }
}
