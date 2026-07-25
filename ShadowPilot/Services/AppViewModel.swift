import Foundation
import SwiftUI
import AppKit
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

// First-token race winner arbitration for hedged Q&A requests
private actor RaceArbiter {
    private var winnerIndex: Int?
    func claim(_ i: Int) -> Bool {
        if winnerIndex == nil { winnerIndex = i }
        return winnerIndex == i
    }
}

@MainActor
class AppViewModel: ObservableObject {
    // Shared between the overlay and the dashboard — one brain, two surfaces
    static let shared = AppViewModel()

    @Published var isListening = false
    @Published var transcript = ""          // live listening / typing buffer
    @Published var currentQuestion = ""     // question the current answer belongs to
    @Published var answer = ""
    @Published var statusText = "Ready"
    @Published var showAnswer = false
    @Published var isLoadingAnswer = false
    @Published var isWriting = true
    @Published var isCapturing = false

    // Feature flags
    @Published var whisperMode = false      // reveal answer chunk by chunk
    @Published var autoListen = false       // hands-free: silence-fire + continuous listening

    // Mode routing
    @Published var answerMode: AnswerMode = .auto
    @Published var detectedMode: AnswerMode?

    // Filler — shown instantly while AI thinks
    @Published var fillerText: String = ""
    @Published var showFiller = false

    // Rolling conversation memory (always-on, compressed, capped — never persisted)
    @Published private(set) var history: [ConversationTurn] = []

    // Full-text turns for the session, shown as tabs in the answer panel
    struct DisplayTurn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        let answer: String
        let modeLabel: String
        let modelLabel: String
    }
    @Published private(set) var turns: [DisplayTurn] = []
    @Published var viewingIndex: Int? = nil   // nil = live (current question/answer)
    @Published var liveAnswerActive = false   // an answer is streaming/revealing (dashboard bubble)

    @AppStorage("jd") private var jd = ""
    @AppStorage("resume") private var resume = ""
    @AppStorage("silenceDelay") var silenceDelay: Double = 0.9
    @AppStorage("accentPreset") private var accentPreset = AccentPreset.indian.rawValue
    @AppStorage("styleSample") private var styleSample = ""
    @AppStorage("customAccent") private var customAccent = ""

    private let audioCapture = SystemAudioCapture()
    private let speechRecognizer = SpeechRecognizer()
    private let screenshotCapture = ScreenshotCapture()
    private let silenceDetector = SilenceDetector()

    // Streaming/answer state
    private(set) var isAnswerStreaming = false
    private var pendingAutoFire = false     // silence fired mid-answer → flush on completion
    private var currentAnswerTask: Task<Void, Never>?
    private var whisperTask: Task<Void, Never>?
    private var usedModelLabel = ""
    private var requestFiredAt: Date?

    // MARK: - Hotkey setup
    func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.onMicToggle  = { [weak self] in self?.isListening == true ? self?.stopListening() : self?.startListening() }
        hk.onGetAnswer  = { [weak self] in self?.getAnswer() }
        hk.onScreenshot = { [weak self] in self?.captureAndAnalyze() }
        hk.onClear      = { [weak self] in self?.clear() }
        hk.onWritingToggle = { [weak self] in self?.toggleWriting() }
        hk.register()
    }

    // MARK: - Listening
    func startListening() {
        guard !isListening else { return }
        isListening = true
        transcript = ""
        statusText = "Listening..."
        silenceDetector.silenceThreshold = silenceDelay
        silenceDetector.reset()
        SessionStore.shared.beginSessionIfNeeded()

        speechRecognizer.start { [weak self] partial in
            guard let self else { return }
            self.transcript = partial
            if !self.isAnswerStreaming {
                self.statusText = partial.isEmpty ? "Listening..." : partial
            }
        }

        silenceDetector.onSilence = { [weak self] in
            guard let self, self.isListening, self.autoListen else { return }
            let q = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return }   // never fire on empty transcript — keep listening
            if self.isAnswerStreaming {
                self.pendingAutoFire = true    // queued; flushed when the answer completes
            } else {
                self.fireAuto(question: q)
            }
        }

        Task {
            do {
                audioCapture.onBuffer = { [weak self] buffer in
                    guard let self else { return }
                    self.speechRecognizer.append(buffer)
                    if self.autoListen { self.silenceDetector.process(buffer: buffer) }
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
        pendingAutoFire = false
        silenceDetector.onSilence = nil
        speechRecognizer.stop()
        Task { await audioCapture.stop() }
        if !isAnswerStreaming {
            statusText = transcript.isEmpty ? "Ready" : transcript
        }
    }

    // Auto-mode fire: take the question, reset the buffer for the NEXT question,
    // keep audio + recognition running throughout.
    private func fireAuto(question: String) {
        speechRecognizer.restartBuffer()
        silenceDetector.reset()
        getAnswer(question: question)
    }

    private func flushPendingAutoFire() {
        guard pendingAutoFire else { return }
        pendingAutoFire = false
        let q = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard autoListen, isListening, !q.isEmpty else { return }
        fireAuto(question: q)
    }

    // MARK: - Get answer
    func getAnswer(question: String? = nil) {
        let q = (question ?? transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { statusText = "Nothing heard yet"; return }

        let mode = ModelRouter.resolveMode(question: q, selected: answerMode, previous: history.last?.mode)
        detectedMode = mode
        let chain = ModelRouter.chain(for: mode)
        guard !chain.isEmpty else { statusText = "Add API key in .env"; return }

        currentAnswerTask?.cancel()
        whisperTask?.cancel()
        viewingIndex = nil          // a new answer always brings the live tab forward
        currentQuestion = q
        isLoadingAnswer = true
        showAnswer = true
        answer = ""
        isAnswerStreaming = true
        liveAnswerActive = true
        requestFiredAt = Date()
        presentFiller()
        statusText = "\(mode.label) → \(chain[0].modelLabel)"

        currentAnswerTask = Task {
            do {
                let system = ModelRouter.systemPrompt(for: mode, jd: jd, resume: resume,
                                                      accent: accentPreset, styleSample: styleSample,
                                                      customAccent: customAccent)
                let full = try await runChain(chain, mode: mode, userText: q, system: system,
                                              onChunk: liveChunkHandler())
                finishAnswerUI()
                if whisperMode { await revealWhisper(full) } else { answer = full }
                statusText = doneStatus()

                appendHistory(question: q, answer: full, mode: mode)
                turns.append(DisplayTurn(question: q, answer: full,
                                         modeLabel: mode.label, modelLabel: usedModelLabel))
                viewingIndex = nil
                liveAnswerActive = false
                SessionStore.shared.append(question: q, answer: full,
                                           mode: mode.rawValue, model: usedModelLabel)
                afterAnswerCompleted()
            } catch is CancellationError {
                // User cleared / re-asked — never treated as failure, never kills the loop
                isAnswerStreaming = false
                liveAnswerActive = false
            } catch {
                finishAnswerUI()
                answer = "Error: \(error.localizedDescription)"
                statusText = "Error"
                // Real error (all providers failed) — auto-loop intentionally NOT restarted
            }
        }
    }

    // Re-ask the current question in an explicitly chosen mode (misclassification recovery)
    func reAsk(in mode: AnswerMode) {
        guard !currentQuestion.isEmpty else { return }
        answerMode = mode
        getAnswer(question: currentQuestion)
    }

    private func finishAnswerUI() {
        showFiller = false
        fillerText = ""
        isLoadingAnswer = false
        isAnswerStreaming = false
    }

    private func afterAnswerCompleted() {
        // Hands-free loop: listening never stopped, so just flush any queued fire.
        flushPendingAutoFire()
        // If auto is on but listening was stopped (manual stop before answer), restart.
        if autoListen && !isListening { startListening() }
    }

    private func doneStatus() -> String {
        if let t = requestFiredAt {
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            return "Done · \(usedModelLabel) · \(ms)ms"
        }
        return "Done"
    }

    // MARK: - Provider chain execution (hedged race for Q&A, plain fallback otherwise)

    private func runChain(_ chain: [RoutedService], mode: AnswerMode, userText: String,
                          system: String, onChunk: @escaping (String) -> Void) async throws -> String {
        let hist = history
        let maxTok = mode.maxTokens
        var remaining = chain

        // Hedged racing — Q&A only: top 2 fast providers, first token wins.
        if (mode == .interview || mode == .auto), chain.count >= 2 {
            let pair = Array(chain.prefix(2))
            remaining = Array(chain.dropFirst(2))
            do {
                return try await race(pair, system: system, userText: userText, hist: hist,
                                      maxTok: maxTok, onChunk: onChunk)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                statusText = "Racers failed, falling back..."
            }
        }

        var lastError: Error = URLError(.badServerResponse)
        for svc in remaining {
            try Task.checkCancellation()
            do {
                statusText = "\(mode.label) → \(svc.modelLabel)"
                var full = ""
                for try await chunk in svc.stream(system, userText, hist, maxTok) {
                    full += chunk
                    onChunk(full)
                }
                full = try await continueIfTruncated(full, svc: svc, system: system,
                                                     question: userText, hist: hist,
                                                     maxTok: maxTok, mode: mode, onChunk: onChunk)
                usedModelLabel = svc.modelLabel
                return full
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                statusText = "\(svc.modelLabel) failed, trying next..."
            }
        }
        throw lastError
    }

    // If the model hit its output limit, keep asking it to continue until the
    // answer is complete — the user always gets the FULL answer.
    private func continueIfTruncated(_ partial: String, svc: RoutedService, system: String,
                                     question: String, hist: [ConversationTurn], maxTok: Int,
                                     mode: AnswerMode,
                                     onChunk: @escaping (String) -> Void) async throws -> String {
        var result = partial
        var rounds = 0
        while result.hasSuffix(kTruncationMarker), rounds < 3 {
            try Task.checkCancellation()
            rounds += 1
            result = String(result.dropLast(kTruncationMarker.count))
            statusText = "Continuing answer (part \(rounds + 1))..."
            let contHist = hist + [ConversationTurn(question: question, answer: result, mode: mode)]
            var cont = ""
            for try await chunk in svc.stream(
                system,
                "Continue your previous answer EXACTLY where it stopped. Do not repeat anything already written — continue mid-sentence/mid-code if needed.",
                contHist, maxTok
            ) {
                cont += chunk
                onChunk(result + cont)
            }
            result += cont
        }
        return result
    }

    private func race(_ pair: [RoutedService], system: String, userText: String,
                      hist: [ConversationTurn], maxTok: Int,
                      onChunk: @escaping (String) -> Void) async throws -> String {
        let arbiter = RaceArbiter()
        var winnerLabel = ""

        let result: String = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, svc) in pair.enumerated() {
                group.addTask {
                    var full = ""
                    var claimed = false
                    for try await chunk in svc.stream(system, userText, hist, maxTok) {
                        if !claimed {
                            guard await arbiter.claim(i) else { throw CancellationError() }
                            claimed = true
                        }
                        full += chunk
                        let snapshot = full
                        await MainActor.run { onChunk(snapshot) }
                    }
                    guard claimed else { throw CancellationError() }
                    return (i, full)
                }
            }

            var winning: String?
            var firstRealError: Error?
            while let outcome = await group.nextResult() {
                switch outcome {
                case .success(let (i, full)):
                    winning = full
                    winnerLabel = pair[i].modelLabel
                case .failure(let err):
                    if !(err is CancellationError), firstRealError == nil { firstRealError = err }
                }
                if winning != nil { break }
            }
            group.cancelAll()
            if let winning { return winning }
            throw firstRealError ?? URLError(.badServerResponse)
        }

        usedModelLabel = winnerLabel
        return result
    }

    // MARK: - Screenshot
    func captureAndAnalyze() {
        let chain = ModelRouter.visionChain()
        guard !chain.isEmpty else { statusText = "Add API key in .env"; return }

        currentAnswerTask?.cancel()
        whisperTask?.cancel()
        isCapturing = true
        isLoadingAnswer = true
        showAnswer = true
        answer = ""
        isAnswerStreaming = true
        liveAnswerActive = true
        currentQuestion = "Screenshot"
        requestFiredAt = Date()
        showFiller = false

        currentAnswerTask = Task {
            do {
                let imageData = try await screenshotCapture.capture()
                statusText = "Analyzing..."
                presentFiller()

                let system = ModelRouter.systemPrompt(for: .coding, jd: jd, resume: resume,
                                                      accent: accentPreset, styleSample: styleSample,
                                                      customAccent: customAccent)
                let prompt = ModelRouter.visionPrompt(jd: "", resume: "")
                let hist = history
                let onChunk = liveChunkHandler()

                var full = ""
                var lastError: Error = URLError(.badServerResponse)
                var done = false
                for svc in chain {
                    try Task.checkCancellation()
                    guard let vision = svc.streamVision else { continue }
                    do {
                        statusText = "Code → \(svc.modelLabel)"
                        full = ""
                        for try await chunk in vision(system, prompt, imageData, hist, AnswerMode.coding.maxTokens) {
                            full += chunk
                            onChunk(full)
                        }
                        // Continuation goes through the text endpoint — the partial
                        // answer in history carries the context, no image re-send.
                        full = try await continueIfTruncated(full, svc: svc, system: system,
                                                             question: "Screenshot problem (image analyzed above)",
                                                             hist: hist, maxTok: AnswerMode.coding.maxTokens,
                                                             mode: .coding, onChunk: onChunk)
                        usedModelLabel = svc.modelLabel
                        done = true
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                        statusText = "\(svc.modelLabel) failed, trying next..."
                    }
                }
                guard done else { throw lastError }

                finishAnswerUI()
                if whisperMode { await revealWhisper(full) } else { answer = full }
                currentQuestion = "[screenshot]"
                statusText = doneStatus()

                appendHistory(question: "[screenshot]", answer: full, mode: .coding)
                turns.append(DisplayTurn(question: "Screenshot", answer: full,
                                         modeLabel: AnswerMode.coding.label, modelLabel: usedModelLabel))
                viewingIndex = nil
                liveAnswerActive = false
                SessionStore.shared.append(question: "[screenshot]", answer: full,
                                           mode: AnswerMode.coding.rawValue, model: usedModelLabel)
                isCapturing = false
                afterAnswerCompleted()
            } catch is CancellationError {
                isCapturing = false
                isAnswerStreaming = false
                liveAnswerActive = false
            } catch {
                finishAnswerUI()
                isCapturing = false
                answer = "Error: \(error.localizedDescription)"
                statusText = "Capture failed"
            }
        }
    }

    // MARK: - Conversation memory

    private func appendHistory(question: String, answer full: String, mode: AnswerMode) {
        // Long answers stored compressed — keeps key decisions without eating the budget
        let compressed = full.count > 800 ? String(full.prefix(800)) + "…" : full
        history.append(ConversationTurn(question: question, answer: compressed, mode: mode))
        // Cap: last 8 pairs or ~2500 tokens (~10k chars), drop oldest first
        while history.count > 8 || totalHistoryChars() > 10_000 {
            if history.isEmpty { break }
            history.removeFirst()
        }
    }

    private func totalHistoryChars() -> Int {
        history.reduce(0) { $0 + $1.question.count + $1.answer.count }
    }

    func clearHistory() {
        history = []
    }

    // MARK: - Writing toggle
    func toggleWriting() {
        isWriting.toggle()
        let panel = NSApp.windows.first(where: { $0 is OverlayWindow }) as? OverlayWindow
        if isWriting {
            panel?.focusTextField()
        } else {
            panel?.unfocusTextField()
        }
    }

    // MARK: - Clear
    func clear() {
        currentAnswerTask?.cancel()
        whisperTask?.cancel()
        if isListening { stopListening() }
        pendingAutoFire = false
        isAnswerStreaming = false
        transcript = ""
        currentQuestion = ""
        answer = ""
        showAnswer = false
        showFiller = false
        fillerText = ""
        isLoadingAnswer = false
        detectedMode = nil
        statusText = "Ready"
        history = []
        turns = []
        viewingIndex = nil
        liveAnswerActive = false
        SessionStore.shared.endSession()
    }

    // MARK: - Private helpers

    // Streams accumulated text into the visible answer as it arrives.
    // No-op in whisper mode — there the full answer is buffered and revealed chunk by chunk.
    private func liveChunkHandler() -> (String) -> Void {
        { [weak self] partial in
            guard let self, !self.whisperMode else { return }
            self.showFiller = false
            self.fillerText = ""
            self.isLoadingAnswer = false
            self.answer = partial
        }
    }

    // Reveal answer chunk by chunk — line-based for structured answers,
    // sentence-based for prose (Q&A answers have no newlines).
    private func revealWhisper(_ full: String) async {
        whisperTask?.cancel()
        let task = Task { [weak self] in
            var chunks = full.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var separator = "\n"
            if chunks.count <= 1 {
                chunks = Self.sentences(full)
                separator = " "
            }
            var revealed = ""
            for chunk in chunks {
                if Task.isCancelled { return }
                revealed += (revealed.isEmpty ? "" : separator) + chunk
                self?.answer = revealed
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        whisperTask = task
        await task.value
    }

    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { result.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { result.append(t) }
        return result
    }

    // Pick a random filler and show it
    private func presentFiller() {
        fillerText = fillerPhrases.randomElement() ?? fillerPhrases[0]
        showFiller = true
    }
}
