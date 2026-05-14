import Foundation
import SwiftUI
import AVFoundation

// Filler phrases shown while AI is thinking — buys time naturally
private let fillerPhrases = [
    "That's a great question — let me think through this...",
    "So, the way I approach this is...",
    "Yeah, I've dealt with this before — give me a second to structure my thoughts...",
    "Interesting — there are a few angles here...",
    "Right, so the core of this is...",
    "Let me walk you through how I'd think about this...",
    "Good question — I want to make sure I give you a complete answer...",
    "So off the top of my head...",
]

@MainActor
class AppViewModel: ObservableObject {
    @Published var isListening = false
    @Published var transcript = ""
    @Published var answer = ""
    @Published var statusText = "Ready"
    @Published var showAnswer = false
    @Published var isLoadingAnswer = false
    @Published var isWriting = false
    @Published var isCapturing = false

    // Feature flags
    @Published var followUpMode = false   // remember conversation history
    @Published var whisperMode = false    // lines appear slowly one by one
    @Published var autoListen = false     // stop on silence, auto-fire

    // Filler — shown instantly while AI thinks
    @Published var fillerText: String = ""
    @Published var showFiller = false

    // Conversation history for follow-up mode
    @Published private(set) var history: [ConversationTurn] = []

    @AppStorage("jd") private var jd = ""
    @AppStorage("resume") private var resume = ""

    private let audioCapture = SystemAudioCapture()
    private let speechRecognizer = SpeechRecognizer()
    private let screenshotCapture = ScreenshotCapture()
    private let silenceDetector = SilenceDetector(threshold: 1.8)

    // Whisper mode — full answer buffered, then revealed line by line
    private var whisperLines: [String] = []
    private var whisperIndex = 0
    private var whisperTask: Task<Void, Never>?

    private var primaryService: GPTService? {
        EnvConfig.openAIKey.isEmpty ? nil : GPTService(apiKey: EnvConfig.openAIKey)
    }
    private var fallbackService: GPTService? {
        EnvConfig.openRouterKey.isEmpty ? nil : GPTService(apiKey: EnvConfig.openRouterKey,
                                                            baseURL: "https://openrouter.ai/api/v1",
                                                            model: "openai/gpt-4o")
    }

    // MARK: - Hotkey setup
    func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.onMicToggle  = { [weak self] in self?.isListening == true ? self?.stopListening() : self?.startListening() }
        hk.onGetAnswer  = { [weak self] in self?.getAnswer() }
        hk.onScreenshot = { [weak self] in self?.captureAndAnalyze() }
        hk.onClear      = { [weak self] in self?.clear() }
        hk.register()
    }

    // MARK: - Listening
    func startListening() {
        isListening = true
        transcript = ""
        answer = ""
        showAnswer = false
        showFiller = false
        statusText = "Listening..."
        silenceDetector.reset()

        speechRecognizer.start { [weak self] partial in
            self?.transcript = partial
            self?.statusText = partial.isEmpty ? "Listening..." : partial
        }

        if autoListen {
            silenceDetector.onSilence = { [weak self] in
                guard let self, self.isListening else { return }
                self.stopListening()
                self.getAnswer()
            }
        }

        Task {
            do {
                audioCapture.onBuffer = { [weak self] buffer in
                    self?.speechRecognizer.append(buffer)
                    if self?.autoListen == true {
                        self?.silenceDetector.process(buffer: buffer)
                    }
                }
                try await audioCapture.start()
            } catch {
                statusText = "Audio error: \(error.localizedDescription)"
                isListening = false
            }
        }
    }

    func stopListening() {
        isListening = false
        silenceDetector.onSilence = nil
        let final = speechRecognizer.stop()
        if !final.isEmpty { transcript = final }
        Task { await audioCapture.stop() }
        statusText = transcript.isEmpty ? "Ready" : transcript
    }

    // MARK: - Get answer
    func getAnswer() {
        guard primaryService != nil || fallbackService != nil else {
            statusText = "Add API key in Settings"; return
        }
        guard !transcript.isEmpty else {
            statusText = "Nothing heard yet"; return
        }

        isLoadingAnswer = true
        showAnswer = true
        answer = ""
        whisperTask?.cancel()

        // Show filler immediately so there's no awkward silence
        showFiller(for: transcript)
        statusText = "Thinking..."

        Task {
            do {
                let full = try await collectFull()
                showFiller = false
                fillerText = ""

                if whisperMode {
                    await revealWhisper(full)
                } else {
                    answer = full
                }

                isLoadingAnswer = false
                statusText = "Done"

                if followUpMode {
                    history.append(ConversationTurn(question: transcript, answer: full))
                }
            } catch {
                showFiller = false
                isLoadingAnswer = false
                answer = "Error: \(error.localizedDescription)"
                statusText = "Error"
            }
        }
    }

    // MARK: - Screenshot
    func captureAndAnalyze() {
        guard let service = primaryService ?? fallbackService else {
            statusText = "Add API key in .env"; return
        }

        isCapturing = true
        isLoadingAnswer = true
        showAnswer = true
        answer = ""
        whisperTask?.cancel()
        showFiller = false

        Task {
            do {
                let imageData = try await screenshotCapture.capture()
                statusText = "Analyzing..."
                showFiller(for: "screenshot")

                var full = ""
                do {
                    for try await chunk in service.streamVision(imageData: imageData, jd: jd, resume: resume, history: followUpMode ? history : []) {
                        full += chunk
                    }
                } catch {
                    if let fallback = fallbackService, service !== (primaryService as AnyObject) as? GPTService {
                        full = ""
                        for try await chunk in fallback.streamVision(imageData: imageData, jd: jd, resume: resume, history: followUpMode ? history : []) {
                            full += chunk
                        }
                    } else {
                        throw error
                    }
                }

                showFiller = false
                fillerText = ""

                if whisperMode {
                    await revealWhisper(full)
                } else {
                    answer = full
                }

                if followUpMode {
                    history.append(ConversationTurn(question: "[screenshot]", answer: full))
                }

                isCapturing = false
                isLoadingAnswer = false
                statusText = "Done"
            } catch {
                isCapturing = false
                isLoadingAnswer = false
                showFiller = false
                answer = "Error: \(error.localizedDescription)"
                statusText = "Capture failed"
            }
        }
    }

    // MARK: - Clear
    func clear() {
        if isListening { stopListening() }
        whisperTask?.cancel()
        transcript = ""
        answer = ""
        showAnswer = false
        showFiller = false
        fillerText = ""
        statusText = "Ready"
        if !followUpMode { history = [] }
    }

    func clearHistory() {
        history = []
    }

    // MARK: - Private helpers

    private func collectFull() async throws -> String {
        var full = ""
        let hist = followUpMode ? history : []
        if let primary = primaryService {
            do {
                for try await chunk in primary.stream(transcript: transcript, jd: jd, resume: resume, history: hist) {
                    full += chunk
                }
                return full
            } catch {
                guard let fallback = fallbackService else { throw error }
                full = ""
                statusText = "Retrying..."
                for try await chunk in fallback.stream(transcript: transcript, jd: jd, resume: resume, history: hist) {
                    full += chunk
                }
                return full
            }
        } else if let fallback = fallbackService {
            for try await chunk in fallback.stream(transcript: transcript, jd: jd, resume: resume, history: hist) {
                full += chunk
            }
            return full
        }
        throw URLError(.badServerResponse)
    }

    // Reveal answer one line at a time with a small delay — looks natural
    private func revealWhisper(_ full: String) async {
        let lines = full.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var revealed = ""
        for line in lines {
            revealed += (revealed.isEmpty ? "" : "\n") + line
            answer = revealed
            // ~600ms per line feels like natural reading pace
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
        }
    }

    // Pick a random filler and show it
    private func showFiller(for question: String) {
        fillerText = fillerPhrases.randomElement() ?? fillerPhrases[0]
        showFiller = true
    }
}
