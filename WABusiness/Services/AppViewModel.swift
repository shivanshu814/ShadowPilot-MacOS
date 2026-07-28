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
    @Published var cloudReviewRunning = false // a Cursor agent is working — drives the Cloud pill

    @AppStorage("jd") private var jd = ""
    @AppStorage("resume") private var resume = ""
    @AppStorage("silenceDelay") var silenceDelay: Double = 0.9
    @AppStorage("accentPreset") private var accentPreset = AccentPreset.indian.rawValue
    @AppStorage("styleSample") private var styleSample = ""
    @AppStorage("customAccent") private var customAccent = ""
    // Findings from the last cloud review — carried into every repo answer so the
    // fast local path knows what the deep pass already established.
    @AppStorage("repoBrief") var repoBrief = ""

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
        hk.onBugScan    = { [weak self] in self?.scanForBugs() }
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
        // Hands-free must never spam a minutes-long cloud review on every pause.
        guard !answerMode.isCloud else { return }
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
        // "/repo …", a folder path, or a git URL loads a codebase instead of asking
        // Cloud is checked BEFORE /repo: with Cloud selected, a URL in the box
        // names the repo to review remotely, and must not be cloned locally.
        if let focus = Self.cloudCommandFocus(q) {
            transcript = ""
            cloudReview(focus: focus)
            return
        }
        if answerMode.isCloud {
            transcript = ""
            cloudReview(focus: q)
            return
        }
        if loadRepoIfCommand(q) { return }

        var mode = ModelRouter.resolveMode(question: q, selected: answerMode, previous: history.last?.mode)
        // Repo mode without an index would invite the model to invent file paths —
        // fall back to a plain code review instead.
        if mode == .repo, !RepoIndex.shared.isReady {
            mode = .codeReview
            statusText = "No codebase loaded — answering without file references"
        }
        // Cloud is answered by a Cursor agent, not by a provider chain — the
        // question becomes the review's focus.
        if mode.isCloud {
            detectedMode = mode
            transcript = ""
            cloudReview(focus: q)
            return
        }
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
                // Repo mode: retrieve the real files first, so the answer can cite
                // actual paths and line numbers instead of describing code generically.
                var prompt = q
                if mode == .repo, RepoIndex.shared.isReady {
                    statusText = "Searching \(RepoIndex.shared.rootName)…"
                    prompt = ModelRouter.repoUserPrompt(context: RepoIndex.shared.context(for: q),
                                                        question: q,
                                                        brief: repoBrief)
                    statusText = "\(mode.label) → \(chain[0].modelLabel)"
                }
                let full = try await runChain(chain, mode: mode, userText: prompt,
                                              continuationQuestion: q, system: system,
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

    // `userText` is what the model sees (in repo mode it carries the retrieved code);
    // `continuationQuestion` is the bare question re-sent when an answer is truncated,
    // so a continuation never re-uploads the whole repo context.
    private func runChain(_ chain: [RoutedService], mode: AnswerMode, userText: String,
                          continuationQuestion: String? = nil,
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
                                                     question: continuationQuestion ?? userText, hist: hist,
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

    // MARK: - Repo bug scan

    // Sweeps the indexed repo for real defects, batch by batch, streaming the
    // report as it builds — so findings are ready before the interviewer asks.
    func scanForBugs() {
        guard RepoIndex.shared.isReady else {
            statusText = "Load a repo in Setup first"
            return
        }
        let batches = RepoIndex.shared.reviewBatches()
        guard !batches.isEmpty else { statusText = "Nothing to scan"; return }
        let chain = ModelRouter.chain(for: .repo)
        guard !chain.isEmpty else { statusText = "Add API key in .env"; return }

        currentAnswerTask?.cancel()
        whisperTask?.cancel()
        viewingIndex = nil
        currentQuestion = "Bug scan · \(RepoIndex.shared.rootName)"
        answer = ""
        showAnswer = true
        showFiller = false
        isLoadingAnswer = true
        isAnswerStreaming = true
        liveAnswerActive = true
        requestFiredAt = Date()
        SessionStore.shared.beginSessionIfNeeded()

        currentAnswerTask = Task {
            let system = ModelRouter.systemPrompt(for: .repo, jd: jd, resume: resume,
                                                  accent: accentPreset, styleSample: styleSample,
                                                  customAccent: customAccent)
            var report = ""
            var failures = 0

            for (i, batch) in batches.enumerated() {
                if Task.isCancelled { break }
                statusText = "Scanning \(i + 1)/\(batches.count) · \(RepoIndex.shared.rootName)"
                let prefix = report   // immutable snapshot for the streaming closure
                do {
                    let part = try await runChain(
                        chain, mode: .repo,
                        userText: ModelRouter.bugScanPrompt(batch: batch, part: i + 1, total: batches.count),
                        continuationQuestion: "Continue the findings list exactly where you stopped.",
                        system: system,
                        onChunk: { [weak self] partial in
                            guard let self else { return }
                            self.isLoadingAnswer = false
                            self.answer = prefix.isEmpty ? partial : prefix + "\n\n" + partial
                        })
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !trimmed.uppercased().hasPrefix("NO FINDINGS") {
                        report += (report.isEmpty ? "" : "\n\n") + trimmed
                    }
                    answer = report
                } catch is CancellationError {
                    isAnswerStreaming = false
                    liveAnswerActive = false
                    return
                } catch {
                    failures += 1
                }
            }

            finishAnswerUI()
            let final = report.isEmpty
                ? "Scanned \(batches.count) batch\(batches.count == 1 ? "" : "es") of \(RepoIndex.shared.rootName) — no concrete defects surfaced."
                : report
            answer = final
            statusText = failures > 0 ? "Scan done · \(failures) batch(es) failed" : doneStatus()

            turns.append(DisplayTurn(question: currentQuestion, answer: final,
                                     modeLabel: AnswerMode.repo.label, modelLabel: usedModelLabel))
            viewingIndex = nil
            liveAnswerActive = false
            SessionStore.shared.append(question: currentQuestion, answer: final,
                                       mode: AnswerMode.repo.rawValue, model: usedModelLabel)
            afterAnswerCompleted()   // a scan must not break the hands-free loop
        }
    }

    // MARK: - Cloud review (Cursor Cloud Agents)

    // Launches an agent that reads the WHOLE repo in Cursor's cloud and writes a
    // findings report — architecture, defects, weak spots, talking points. It runs
    // for minutes, so this is a before-the-interview move; the report is then kept
    // as context so the instant local answers know what the deep pass found.
    func cloudReview(focus rawFocus: String = "") {
        let cursor = CursorAgentService()
        guard cursor.isConfigured else {
            presentRepoNotice(CursorAgentError.noKey.localizedDescription, status: "No Cursor key")
            return
        }

        // "github.com/me/app please review the auth flow" — the leading URL is
        // the repo to review, everything after it is what to weight it toward.
        var focus = rawFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        var explicitURL: String?
        if case .some(.remote(let url)) = RepoCommand.parse(focus) {
            explicitURL = url
            if let space = focus.rangeOfCharacter(from: .whitespacesAndNewlines) {
                focus = String(focus[space.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                focus = ""
            }
            UserDefaults.standard.set(url, forKey: "repoRemote")   // later /cloud reuses it
        }

        guard let repoURL = explicitURL ?? resolvedRemoteURL() else {
            presentRepoNotice(CursorAgentError.noRepo.localizedDescription, status: "No repo URL")
            return
        }

        currentAnswerTask?.cancel()
        whisperTask?.cancel()
        viewingIndex = nil
        currentQuestion = "Cloud review · \(repoName(from: repoURL))"
        answer = ""
        showAnswer = true
        showFiller = false
        isLoadingAnswer = true
        isAnswerStreaming = false
        requestFiredAt = Date()
        SessionStore.shared.beginSessionIfNeeded()

        cloudReviewRunning = true
        currentAnswerTask = Task {
            let started = Date()
            defer { cloudReviewRunning = false }
            do {
                // Cursor errors out if it has to guess the branch itself, so
                // look it up first and pass it explicitly.
                var ref = RemoteRepo(input: repoURL)?.branch
                if ref == nil, let parsed = RemoteRepo(input: repoURL) {
                    statusText = "Resolving default branch…"
                    ref = await GitHubAPI.defaultBranch(owner: parsed.owner,
                                                        name: parsed.name,
                                                        token: EnvConfig.gitToken)
                }

                statusText = "Starting cloud agent…"
                answer = "Starting a Cursor agent on `\(repoURL)`\(ref.map { " (\($0))" } ?? "")…\n\nThis reads the whole repo and takes a few minutes. Ask other questions meanwhile — the report lands here when it's done."
                let run = try await cursor.startReview(
                    repoURL: repoURL,
                    ref: ref,
                    prompt: CursorAgentService.reviewPrompt(focus: focus),
                    name: "Interview review — \(repoName(from: repoURL))")

                // No streaming endpoint: poll, backing off from 4s to 15s.
                var delay: UInt64 = 4
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    delay = min(delay + 2, 15)

                    let elapsed = Int(Date().timeIntervalSince(started))
                    let state = try await cursor.state(of: run)
                    switch state {
                    case .pending(let raw):
                        statusText = "Cloud agent \(raw.lowercased()) · \(elapsed)s"
                        answer = "Cursor agent is \(raw.lowercased()) on `\(repoURL)` — \(elapsed)s elapsed.\n\nIt reads the full codebase, so a few minutes is normal. Esc cancels."
                    case .finished(let report):
                        isLoadingAnswer = false
                        answer = report
                        repoBrief = report          // feeds every later repo answer
                        statusText = "Cloud review done · \(elapsed)s"
                        turns.append(DisplayTurn(question: currentQuestion, answer: report,
                                                 modeLabel: "Cloud", modelLabel: "Cursor agent"))
                        viewingIndex = nil
                        SessionStore.shared.append(question: currentQuestion, answer: report,
                                                   mode: AnswerMode.repo.rawValue, model: "Cursor agent")
                        afterAnswerCompleted()
                        return
                    case .failed(let message):
                        isLoadingAnswer = false
                        answer = message
                        statusText = "Cloud review failed"
                        return
                    }

                    if Date().timeIntervalSince(started) > 1800 {   // 30 min ceiling
                        isLoadingAnswer = false
                        answer = "The agent is still running after 30 minutes — check it in Cursor (agent `\(run.agentId)`)."
                        statusText = "Cloud review timed out"
                        return
                    }
                }
            } catch is CancellationError {
                isLoadingAnswer = false
                statusText = "Cloud review cancelled"
            } catch {
                isLoadingAnswer = false
                answer = error.localizedDescription
                statusText = "Cloud review failed"
            }
        }
    }

    // "/cloud", "/review", "/cloud focus on the auth flow" → the focus text (may be
    // empty). nil when it isn't a cloud command at all.
    static func cloudCommandFocus(_ text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        for word in ["/cloud", "/review", "/deep"] {
            if lower == word { return "" }
            if lower.hasPrefix(word + " ") {
                return String(s.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // The GitHub URL for the loaded repo: the one that was cloned, or the origin
    // remote of a folder opened locally.
    private func resolvedRemoteURL() -> String? {
        let remote = UserDefaults.standard.string(forKey: "repoRemote") ?? ""
        if !remote.isEmpty, let parsed = RemoteRepo(input: remote) { return parsed.cloneURL(token: "") }
        let path = RepoIndex.shared.isReady
            ? RepoIndex.shared.rootPath
            : (UserDefaults.standard.string(forKey: "repoPath") ?? "")
        guard !path.isEmpty else { return nil }
        return Git.originURL(path: path)
    }

    private func repoName(from url: String) -> String {
        RemoteRepo(input: url)?.name ?? "repo"
    }

    // Tapping the Local pill with nothing indexed — say how to load one rather
    // than silently answering without file references.
    func promptForRepo() {
        presentRepoNotice("""
        No codebase loaded yet.

        Load one right here in the bar, mid-conversation:

        `/repo ~/code/my-service` — a folder already on this Mac
        `/repo github.com/owner/name` — clones it first, then indexes

        Once it's loaded, **Local** answers with real file paths, real line numbers and the exact diff to make. **Cloud** hands the whole repo to a Cursor agent for a deep review.
        """, status: "No codebase loaded", title: "Local repo")
    }

    private func presentRepoNotice(_ message: String, status: String, title: String = "Cloud review") {
        currentAnswerTask?.cancel()
        transcript = ""
        viewingIndex = nil
        currentQuestion = title
        answer = message
        showAnswer = true
        showFiller = false
        isLoadingAnswer = false
        isAnswerStreaming = false
        statusText = status
    }

    // Typing a folder path or a repo URL into the bar loads that codebase on the
    // spot — no Setup trip mid-interview. Returns false when the text is just a
    // question, so the normal answer path takes over.
    // Clicking the Local pill with no codebase: open a folder picker right there
    // rather than only explaining the /repo command. The overlay is a
    // non-activating panel, so the app has to come forward or the sheet opens
    // behind everything.
    func chooseRepoFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Index"
        panel.message = "Pick the root of the repo to load"
        if let last = UserDefaults.standard.string(forKey: "repoPath"), !last.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            promptForRepo()          // cancelled: show what else can be done
            return
        }
        UserDefaults.standard.set("", forKey: "repoRemote")
        loadRepo(.local(url.path))
    }

    @discardableResult
    func loadRepoIfCommand(_ text: String) -> Bool {
        guard let command = RepoCommand.parse(text) else { return false }
        loadRepo(command)
        return true
    }

    private func loadRepo(_ command: RepoCommand) {
        currentAnswerTask?.cancel()
        whisperTask?.cancel()
        transcript = ""
        viewingIndex = nil
        currentQuestion = "Load codebase"
        answer = ""
        showAnswer = true
        showFiller = false
        isLoadingAnswer = true
        isAnswerStreaming = false

        if case .invalid(let target) = command {
            isLoadingAnswer = false
            answer = target.isEmpty
                ? "Give me a target: `/repo ~/code/my-service` or `/repo github.com/owner/repo`."
                : "Can't load `\(target)` — that's not a folder on this Mac or a repo URL I recognise."
            statusText = "Repo not loaded"
            return
        }

        currentAnswerTask = Task {
            var path: String?
            switch command {
            case .remote(let url):
                statusText = "Cloning \(url)…"
                answer = "Cloning `\(url)`…"
                path = await RepoFetcher.shared.fetch(url)
                if path != nil { UserDefaults.standard.set(url, forKey: "repoRemote") }
            case .local(let p):
                path = p
                UserDefaults.standard.set("", forKey: "repoRemote")
            case .invalid:
                break
            }

            guard let path else {
                isLoadingAnswer = false
                answer = RepoFetcher.shared.error ?? "Couldn't reach that repo."
                statusText = "Clone failed"
                return
            }

            statusText = "Indexing \((path as NSString).lastPathComponent)…"
            answer = "Indexing `\((path as NSString).lastPathComponent)`…"
            await RepoIndex.shared.load(path: path)
            isLoadingAnswer = false

            if let err = RepoIndex.shared.indexError {
                answer = err
                statusText = "Index failed"
                return
            }
            UserDefaults.standard.set(path, forKey: "repoPath")
            let idx = RepoIndex.shared
            answer = """
            **\(idx.rootName)** is loaded — \(idx.fileCount) files, \(idx.chunkCount) searchable blocks.

            Ask anything about it and the answer comes back with real file paths, line numbers and the exact diff. ⌘⇧B sweeps the whole repo for bugs.
            """
            statusText = "Repo ready · \(idx.rootName)"
        }
    }

    // Re-open the last repo (local folder or previously cloned remote) at launch.
    func restoreRepo() {
        let saved = UserDefaults.standard.string(forKey: "repoPath") ?? ""
        guard !saved.isEmpty, !RepoIndex.shared.isReady, !RepoIndex.shared.isIndexing else { return }
        Task { await RepoIndex.shared.load(path: saved) }
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
