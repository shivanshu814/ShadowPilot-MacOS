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

// MARK: - Main bar
struct SpotlightBar: View {
    @ObservedObject var vm: AppViewModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WaveformView(active: vm.isListening)

                Divider()
                    .frame(height: 16)
                    .opacity(0.25)

                if vm.isWriting {
                    TextField("Type your question...", text: $vm.transcript, onCommit: {
                        vm.getAnswer()
                        vm.isWriting = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.spText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .focused($isFieldFocused)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isFieldFocused = true
                        }
                    }
                } else {
                    Text(vm.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(vm.isListening ? .spText : .spSubtext)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeInOut(duration: 0.15), value: vm.statusText)
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

                    GlassButton(
                        icon: "square.and.pencil",
                        tint: vm.isWriting ? .spAmber : .spText,
                        dimTint: vm.isWriting ? Color.spAmberDim : Color.primary.opacity(0.08)
                    ) {
                        vm.isWriting.toggle()
                        if vm.isWriting {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                NSApp.keyWindow?.makeKey()
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }
                    }
                    .keyboardShortcut("w", modifiers: .command)

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

            // Mode toggles row
            HStack(spacing: 6) {
                ModePill(label: "Follow-up", icon: "arrow.triangle.2.circlepath",
                         color: .spGreen, isOn: $vm.followUpMode)
                    .help("Remember conversation — gives context-aware answers")

                ModePill(label: "Whisper", icon: "eye",
                         color: .spBlue, isOn: $vm.whisperMode)
                    .help("Answer reveals line by line — looks natural on camera")

                ModePill(label: "Auto", icon: "waveform",
                         color: .spAmber, isOn: $vm.autoListen)
                    .help("Auto-fires when you stop speaking")

                if vm.followUpMode && !vm.history.isEmpty {
                    Spacer()
                    Button {
                        vm.clearHistory()
                    } label: {
                        Text("Clear history (\(vm.history.count))")
                            .font(.system(size: 9))
                            .foregroundColor(.spSubtext)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Root
struct ContentView: View {
    @StateObject private var vm = AppViewModel()

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
        .onAppear { vm.registerHotkeys() }
    }
}
