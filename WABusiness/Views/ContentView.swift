import SwiftUI
import AppKit

// MARK: - Tokens
extension Color {
    static let spAmber    = Color(red: 0.99, green: 0.76, blue: 0.28)
    static let spAmberDim = Color(red: 0.99, green: 0.76, blue: 0.28).opacity(0.18)
    static let spRed      = Color(red: 0.98, green: 0.32, blue: 0.32)
    static let spBlue     = Color(red: 0.45, green: 0.78, blue: 1.00)
    static let spBlueDim  = Color(red: 0.45, green: 0.78, blue: 1.00).opacity(0.15)
    static let spGreen    = Color(red: 0.35, green: 0.90, blue: 0.55)
    static let spGreenDim = Color(red: 0.35, green: 0.90, blue: 0.55).opacity(0.15)
    static let spText     = Color.primary.opacity(0.85)
    static let spSubtext  = Color.primary.opacity(0.38)
}

// MARK: - Waveform
struct WaveformView: View {
    let active: Bool
    @State private var h: [CGFloat] = [0.3, 0.5, 0.8, 0.4, 0.65]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(active ? Color.spRed : Color.spSubtext)
                    .frame(width: 2.5, height: active ? h[i] * 18 : 3)
            }
        }
        .frame(width: 22, height: 18)
        .onChange(of: active) { v in v ? go() : stop() }
        .onAppear { if active { go() } }
    }

    private func go() {
        for i in 0..<5 {
            withAnimation(.easeInOut(duration: Double.random(in: 0.22...0.5))
                .repeatForever(autoreverses: true).delay(Double(i) * 0.06)) {
                h[i] = CGFloat.random(in: 0.2...1)
            }
        }
    }
    private func stop() {
        withAnimation(.easeOut(duration: 0.2)) { h = [0.3, 0.5, 0.8, 0.4, 0.65] }
    }
}

// MARK: - Glass button
struct GlassButton: View {
    let icon: String
    let tint: Color
    let dimTint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(dimTint)
                        .overlay(Circle().stroke(tint.opacity(0.25), lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mode pill toggle
struct ModePill: View {
    let label: String
    let icon: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(isOn ? color : .spSubtext)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? color.opacity(0.15) : Color.primary.opacity(0.06))
                    .overlay(Capsule().stroke(isOn ? color.opacity(0.3) : Color.clear, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filler banner
struct FillerBanner: View {
    let text: String
    @State private var opacity: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            // Pulsing dot
            Circle()
                .fill(Color.spAmber)
                .frame(width: 5, height: 5)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        opacity = 1
                    }
                }
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.spAmber)
                .italic()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("AI thinking...")
                .font(.system(size: 10))
                .foregroundColor(.spSubtext)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

// MARK: - FocusableTextField
class FocusableNSTextField: NSTextField {
    var onFirstClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onFirstClick?()
        super.mouseDown(with: event)
    }
}

struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void
    var onFirstClick: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusableNSTextField {
        let tf = FocusableNSTextField()
        tf.onFirstClick = onFirstClick
        tf.delegate = context.coordinator
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = true
        tf.isSelectable = true
        tf.focusRingType = .none
        tf.placeholderString = placeholder
        tf.font = .systemFont(ofSize: 13, weight: .medium)
        tf.textColor = NSColor.labelColor.withAlphaComponent(0.85)
        TextFieldRef.shared.field = tf
        return tf
    }

    func updateNSView(_ tf: FocusableNSTextField, context: Context) {
        tf.onFirstClick = onFirstClick
        if tf.stringValue != text { tf.stringValue = text }
        TextFieldRef.shared.field = tf
    }


    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableTextField
        init(_ p: FocusableTextField) { self.parent = p }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { parent.text = tf.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}

// MARK: - Answer-mode pill (single-select, detected-mode highlight)
struct AnswerModePill: View {
    let mode: AnswerMode
    let isSelected: Bool
    let isDetected: Bool     // Auto picked this mode for the last question
    var dimmed: Bool = false // shown but not usable yet (Local with no repo)
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isSelected ? .spGreen : (isDetected ? .spAmber : .spSubtext))
                .opacity(dimmed ? 0.45 : 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.spGreenDim : (isDetected ? Color.spAmberDim : Color.primary.opacity(0.06)))
                        .overlay(Capsule().stroke(
                            isSelected ? Color.spGreen.opacity(0.3) : (isDetected ? Color.spAmber.opacity(0.4) : Color.clear),
                            lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cloud review pill

// The deep pass: hands the repo to a Cursor agent. Minutes, not seconds — so it
// shows its own progress and marks itself once findings are cached.
struct CloudPill: View {
    let isSelected: Bool
    let running: Bool
    let hasBrief: Bool
    let ready: Bool
    var action: () -> Void

    private var tint: Color {
        if running { return .spAmber }
        if isSelected { return .spGreen }
        return hasBrief ? .spGreen : .spBlue
    }
    private var filled: Bool { running || isSelected || hasBrief }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if running {
                    ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 9, height: 9)
                } else {
                    Image(systemName: hasBrief ? "cloud.fill" : "cloud")
                        .font(.system(size: 9, weight: .bold))
                }
                Text("Cloud")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(tint)
            .opacity(ready || running ? 1 : 0.45)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(filled ? tint.opacity(0.15) : Color.primary.opacity(0.06))
                    .overlay(Capsule().stroke(filled ? tint.opacity(0.35) : Color.clear, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .help(running
              ? "Cursor agent is reading the whole repo — the report lands in the answer panel"
              : (hasBrief
                 ? "Findings cached and fed into every Local answer — click to run another review"
                 : "Deep review of the whole repo by a Cursor agent (takes minutes, not seconds)"))
    }
}

// MARK: - Main bar
struct SpotlightBar: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var repo = RepoIndex.shared

    // Tapping a different mode while an answer is on screen re-asks instantly
    // (misclassification recovery — no re-dictation needed).
    func selectMode(_ mode: AnswerMode) {
        // Local is only meaningful with a codebase indexed — say so instead of
        // quietly answering without file references.
        if mode == .repo, !repo.isReady {
            vm.promptForRepo()
            return
        }
        // Cloud is an action as much as a mode: selecting it kicks off a full
        // review right away. Typing afterwards re-runs it scoped to what you type.
        if mode == .cloud {
            vm.answerMode = .cloud
            vm.cloudReview()
            return
        }
        let hadAnswer = vm.showAnswer && !vm.currentQuestion.isEmpty && vm.currentQuestion != "[screenshot]"
        if mode != vm.answerMode, mode != .auto, hadAnswer {
            vm.reAsk(in: mode)
        } else {
            vm.answerMode = mode
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WaveformView(active: vm.isListening)

                Divider()
                    .frame(height: 16)
                    .opacity(0.25)

                ZStack(alignment: .leading) {
                    FocusableTextField(
                        text: $vm.transcript,
                        placeholder: "Type your question — or /repo <folder or github url>",
                        onCommit: {
                            vm.getAnswer()
                            vm.isWriting = false
                            (NSApp.windows.first(where: { $0 is OverlayWindow }) as? OverlayWindow)?.unfocusTextField()
                        },
                        onFirstClick: {
                            if !vm.isWriting { vm.toggleWriting() }
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .opacity(vm.isWriting ? 1 : 0)

                    if !vm.isWriting {
                        Text(vm.statusText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(vm.isListening ? .spText : .spSubtext)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !vm.isWriting { vm.toggleWriting() }
                }

                HStack(spacing: 6) {
                    GlassButton(
                        icon:  vm.isListening ? "stop.fill" : "mic.fill",
                        tint:  vm.isListening ? .spRed : .spText,
                        dimTint: vm.isListening ? Color.spRed.opacity(0.15) : Color.primary.opacity(0.08)
                    ) { vm.isListening ? vm.stopListening() : vm.startListening() }
                    .keyboardShortcut(.return, modifiers: .command)

                    GlassButton(icon: "bolt.fill", tint: .spAmber, dimTint: .spAmberDim) {
                        vm.getAnswer()
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(vm.transcript.isEmpty && !vm.isListening)
                    .opacity(vm.transcript.isEmpty && !vm.isListening ? 0.3 : 1)

                    GlassButton(
                        icon:  vm.isCapturing ? "circle.dotted" : "camera.fill",
                        tint: .spBlue, dimTint: .spBlueDim
                    ) { vm.captureAndAnalyze() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(vm.isCapturing)


                    Button(action: vm.clear) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.spSubtext)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            // Answer-mode selector + feature toggles row
            HStack(spacing: 6) {
                ForEach(AnswerMode.allCases) { mode in
                    if mode.isCloud {
                        // Same repo as Local, but run by a Cursor agent — it needs
                        // its own progress and cached-findings state.
                        CloudPill(isSelected: vm.answerMode == .cloud,
                                  running: vm.cloudReviewRunning,
                                  hasBrief: !vm.repoBrief.isEmpty,
                                  ready: repo.isReady) {
                            selectMode(.cloud)
                        }
                    } else {
                        AnswerModePill(mode: mode,
                                       isSelected: vm.answerMode == mode,
                                       isDetected: vm.answerMode == .auto && vm.detectedMode == mode && mode != .auto,
                                       dimmed: mode == .repo && !repo.isReady) {
                            selectMode(mode)
                        }
                        .help(mode == .repo
                              ? (repo.isReady
                                 ? "Answer from \(repo.rootName) — real paths, line numbers, exact diff"
                                 : "No codebase yet — load one with /repo <folder or github url>")
                              : (mode == .auto ? "Detect question type automatically" : "Force \(mode.label) mode"))
                    }
                }

                Spacer(minLength: 4)

                ModePill(label: "Whisper", icon: "eye",
                         color: .spBlue, isOn: $vm.whisperMode)
                    .help("Answer reveals gradually — looks natural on camera")

                ModePill(label: "Hands-free", icon: "waveform",
                         color: .spAmber, isOn: $vm.autoListen)
                    .help("Auto-fires when the speaker pauses (\(String(format: "%.1f", vm.silenceDelay))s). Use headphones. Adjust delay in Setup.")

                // Loaded codebase — name plus a one-tap defect sweep
                // Icon-only: the repo name already lives in the Local pill's tooltip,
                // and the bar has no room for it twice.
                if repo.isReady {
                    Button { vm.scanForBugs() } label: {
                        Image(systemName: "ant.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.spGreen)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.spGreenDim)
                                    .overlay(Capsule().stroke(Color.spGreen.opacity(0.3), lineWidth: 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(repo.rootName) · \(repo.fileCount) files indexed — click (or ⌘⇧B) to scan for bugs")
                } else if repo.isIndexing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("indexing…")
                            .font(.system(size: 9))
                            .foregroundColor(.spSubtext)
                    }
                }

                if !vm.history.isEmpty {
                    Button {
                        vm.clearHistory()
                    } label: {
                        Text("↺\(vm.history.count)")
                            .font(.system(size: 9))
                            .foregroundColor(.spSubtext)
                    }
                    .buttonStyle(.plain)
                    .help("Clear conversation memory (\(vm.history.count) turns)")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Root
struct ContentView: View {
    @ObservedObject private var vm = AppViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            SpotlightBar(vm: vm)

            if vm.showFiller {
                Divider().opacity(0.2)
                FillerBanner(text: vm.fillerText)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else if vm.showAnswer {
                Divider().opacity(0.2)
                AnswerView(vm: vm)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .background(.ultraThinMaterial.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: vm.showAnswer)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: vm.showFiller)
        .onAppear {
            vm.registerHotkeys()
            vm.restoreRepo()
            NeonSync.shared.isBusy = { [weak vm] in vm?.isAnswerStreaming ?? false }
            NeonSync.shared.start()
        }
    }
}
