import AVFoundation

// Detects silence in mic input — fires callback after `threshold` seconds of quiet
final class SilenceDetector {
    var onSilence: (() -> Void)?

    private let silenceThreshold: Double      // seconds of silence before firing
    private let rmsFloor: Float = 0.01        // RMS below this = silence
    private var silenceStart: Date?
    private var fired = false

    init(threshold: Double = 1.8) {
        self.silenceThreshold = threshold
    }

    func reset() {
        silenceStart = nil
        fired = false
    }

    func process(buffer: AVAudioPCMBuffer) {
        guard !fired else { return }
        let rms = calculateRMS(buffer)
        if rms < rmsFloor {
            if silenceStart == nil { silenceStart = Date() }
            if let start = silenceStart,
               Date().timeIntervalSince(start) >= silenceThreshold {
                fired = true
                DispatchQueue.main.async { self.onSilence?() }
            }
        } else {
            silenceStart = nil
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
