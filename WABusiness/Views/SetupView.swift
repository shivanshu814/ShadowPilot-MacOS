import SwiftUI
import AppKit

// Minimalist session setup — flat sections, no decoration, only what's needed.
struct SetupView: View {
    @AppStorage("jd") var jd = ""
    @AppStorage("resume") var resume = ""
    @AppStorage("repoPath") var repoPath = ""       // local folder, or the clone dir of a remote
    @AppStorage("repoRemote") var repoRemote = ""   // remote URL, empty when the source is local
    @AppStorage("silenceDelay") var silenceDelay: Double = 0.9
    @AppStorage("accentPreset") var accentPreset = AccentPreset.indian.rawValue
    @AppStorage("styleSample") var styleSample = ""
    @AppStorage("customAccent") var customAccent = ""
    @Binding var isSetupDone: Bool
    @ObservedObject private var health = ProviderHealth.shared
    @ObservedObject private var sync = NeonSync.shared
    @StateObject private var styleRecorder = StyleRecorder()
    @State private var sampleBeforeRecording = ""
    @ObservedObject private var repo = RepoIndex.shared
    @ObservedObject private var fetcher = RepoFetcher.shared
    @ObservedObject private var vm = AppViewModel.shared

    private var hasAnyProvider: Bool {
        Provider.allCases.contains { p in
            if case .ok = health.status[p] { return true }
            if case .unknown = health.status[p] { return isConfigured(p) }
            return false
        }
    }

    private func isConfigured(_ p: Provider) -> Bool {
        switch p {
        case .groq:       return !EnvConfig.groqKey.isEmpty
        case .cloudflare: return !EnvConfig.cloudflareAccountId.isEmpty && !EnvConfig.cloudflareToken.isEmpty
        case .bedrock:    return !EnvConfig.bedrockKey.isEmpty
        case .openRouter: return !EnvConfig.openRouterKey.isEmpty
        case .openAI:     return !EnvConfig.openAIKey.isEmpty
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // Header
                Text("WA Business")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.spAmber)
                    .padding(.top, 40)
                Text("Session Setup")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 2)

                sectionDivider

                // Providers
                sectionHeader("Providers", trailing: retest)
                VStack(spacing: 0) {
                    ForEach(Provider.allCases) { p in
                        providerRow(p)
                        Divider().opacity(0.08)
                    }
                    // Repo-mode services: same live check, but optional and
                    // never part of a provider chain.
                    ForEach(ProviderHealth.Service.allCases) { s in
                        serviceRow(s)
                        if s != ProviderHealth.Service.allCases.last { Divider().opacity(0.08) }
                    }
                }
                .padding(.top, 6)

                sectionDivider

                // Hands-free delay
                sectionHeader("Silence delay", trailing: AnyView(
                    Text(String(format: "%.1fs", silenceDelay))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                ))
                Slider(value: $silenceDelay, in: 0.3...2.0, step: 0.1)
                    .tint(.spAmber)
                    .padding(.top, 6)
                Text("Pause length that auto-fires the answer in hands-free mode. Use headphones.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                sectionDivider

                // History / sync
                sectionHeader("History", trailing: AnyView(
                    Button("Dashboard") { DashboardWindow.show() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.spBlue)
                ))
                HStack {
                    Toggle("Cloud backup", isOn: $sync.enabled)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 12))
                    Spacer()
                    Text(sync.isConfigured
                         ? (sync.pendingCount > 0 ? "\(sync.pendingCount) pending" : "synced")
                         : "not configured")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 6)

                sectionDivider

                // Codebase — local folder or a cloned remote repo
                sectionHeader("Codebase", trailing: repoStatusChip)
                codebaseSection
                    .padding(.top, 8)

                sectionDivider

                // Context
                sectionHeader("Role context", trailing: nil)
                ContextField(label: "Job description", placeholder: "Paste the job posting…", text: $jd, height: 84)
                    .padding(.top, 8)
                ContextField(label: "Resume", placeholder: "Paste your resume…", text: $resume, height: 84)
                    .padding(.top, 10)

                sectionDivider

                // Speaking style — answers are written in the user's own English accent/voice
                sectionHeader("Speaking style", trailing: recordButton)
                Picker("", selection: $accentPreset) {
                    ForEach(AccentPreset.allCases) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.top, 8)
                if accentPreset == AccentPreset.custom.rawValue {
                    ContextField(label: "My accent, in my own words",
                                 placeholder: "e.g. I'm from Hyderabad — I mix in a bit of Hindi rhythm, say 'actually' and 'itself' a lot, keep sentences short…",
                                 text: $customAccent, height: 64)
                        .padding(.top, 10)
                }
                ContextField(label: "How I speak (voice sample)",
                             placeholder: "Tap Record and talk for 30–60s about your work — or paste a transcript of you speaking English…",
                             text: $styleSample, height: 84)
                    .padding(.top, 10)
                Text(styleRecorder.isRecording
                     ? "Recording from mic — speak naturally, then tap Stop."
                     : "Answers get written in your accent and phrasing, so they sound like you when read aloud.")
                    .font(.system(size: 10.5))
                    .foregroundColor(styleRecorder.isRecording ? .spRed : .secondary)
                    .padding(.top, 4)

                // CTA
                Button(action: { isSetupDone = true }) {
                    Text("Begin Session")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(hasAnyProvider ? .black : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(hasAnyProvider ? Color.spAmber : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(!hasAnyProvider)
                .padding(.top, 24)

                if !hasAnyProvider {
                    Text("Add at least one API key to ~/.wabusiness.env, then re-test.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
        }
        .background(.ultraThinMaterial)
        .frame(width: 460)
        .onReceive(styleRecorder.$liveText) { text in
            guard styleRecorder.isRecording, !text.isEmpty else { return }
            styleSample = sampleBeforeRecording.isEmpty
                ? text
                : sampleBeforeRecording + " " + text
        }
    }

    private var recordButton: AnyView {
        AnyView(Button {
            if styleRecorder.isRecording {
                styleRecorder.stop()
            } else {
                sampleBeforeRecording = styleSample.trimmingCharacters(in: .whitespacesAndNewlines)
                let preset = AccentPreset(rawValue: accentPreset) ?? .neutral
                styleRecorder.start(locale: preset.speechLocale)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: styleRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                Text(styleRecorder.isRecording ? "Stop" : "Record")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(styleRecorder.isRecording ? .spRed : .spBlue)
        }
        .buttonStyle(.plain)
        .help("Record your own voice — the transcript teaches the AI how you speak"))
    }

    // MARK: - Codebase

    // Point the app at a repo — a folder on disk, or a remote URL that gets
    // shallow-cloned. Either way it ends up as a local index, so answers can
    // cite real files and real line numbers.
    private var codebaseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: repo.isReady ? (repoRemote.isEmpty ? "folder.fill" : "cloud.fill")
                                               : "folder.badge.questionmark")
                    .font(.system(size: 12))
                    .foregroundColor(repo.isReady ? .spGreen : .secondary.opacity(0.5))
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.isReady ? repo.rootName : "No codebase loaded")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(repo.isReady ? (repoRemote.isEmpty ? repo.rootPath : repoRemote)
                                      : "Repo mode answers with real file paths and line numbers")
                        .font(.system(size: 10, design: repoRemote.isEmpty ? .monospaced : .default))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)

                if repo.isReady {
                    Button {
                        repo.unload()
                        repoPath = ""
                        repoRemote = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Unload this codebase")
                }
            }

            if busy {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(fetcher.isFetching ? fetcher.status : repo.progress)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            } else if let err = fetcher.error ?? repo.indexError {
                Text(err)
                    .font(.system(size: 10.5))
                    .foregroundColor(.spRed)
                    .fixedSize(horizontal: false, vertical: true)
            } else if repo.isReady {
                Text("\(repo.fileCount) files · \(repo.chunkCount) searchable blocks · ⌘⇧B scans for bugs")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            } else {
                // The repo is named in conversation, not configured here — the bar
                // takes a folder path or a URL directly.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Load one from the bar, mid-conversation:")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Text("/repo ~/code/my-service\n/repo github.com/owner/name")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.75))
                    Text("Private repo needs GITHUB_TOKEN in ~/.wabusiness.env.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            Divider().opacity(0.08)
            cloudReviewRow
        }
        .onAppear {
            if !repoPath.isEmpty, !repo.isReady, !repo.isIndexing {
                Task { await repo.load(path: repoPath) }
            }
        }
    }

    // Deep pass: a Cursor agent reads the whole repo in the cloud and writes a
    // report. Minutes, not seconds — run it before the interview. The findings
    // then ride along with every fast local answer.
    private var cloudReviewRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "cloud.bolt.fill")
                    .font(.system(size: 12))
                    .foregroundColor(cursorConfigured ? .spBlue : .secondary.opacity(0.5))
                    .frame(width: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Cloud review")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(cursorConfigured
                         ? "Cursor agent reads the whole repo and reports back — takes minutes"
                         : "Add CURSOR_API_KEY to ~/.wabusiness.env to enable")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)

                if cursorConfigured {
                    Button("Run review") { AppViewModel.shared.cloudReview() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.spBlue)
                        .disabled(!repo.isReady)
                }
            }

            if !vm.repoBrief.isEmpty {
                HStack(spacing: 8) {
                    Text("Review findings kept as context (\(vm.repoBrief.count / 1000)k chars)")
                        .font(.system(size: 10))
                        .foregroundColor(.spGreen)
                    Button("clear") { vm.repoBrief = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var cursorConfigured: Bool { CursorAgentService().isConfigured }

    private var busy: Bool { repo.isIndexing || fetcher.isFetching }

    private var repoStatusChip: AnyView? {
        guard repo.isReady else { return nil }
        return AnyView(
            Text("Repo mode ready")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.spGreen)
        )
    }

    // MARK: - Building blocks

    private var sectionDivider: some View {
        Divider().opacity(0.12).padding(.vertical, 18)
    }

    private func sectionHeader(_ title: String, trailing: AnyView?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(.secondary)
            Spacer()
            if let trailing { trailing }
        }
    }

    private var retest: AnyView {
        AnyView(Group {
            if health.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await health.checkAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Re-test all providers")
            }
        })
    }

    private func providerRow(_ p: Provider) -> some View {
        let status = health.status[p] ?? .unknown
        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor(status))
                .frame(width: 6, height: 6)
            Text(p.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 84, alignment: .leading)
            Text(health.modelLabel(p))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusText(p, status)
        }
        .padding(.vertical, 8)
        .help(statusHelp(status))
    }

    // Cursor and GitHub: optional, so "no key" reads as neutral rather than a
    // problem, and there is no mute control.
    private func serviceRow(_ s: ProviderHealth.Service) -> some View {
        let status = health.serviceStatus[s] ?? .unknown
        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor(status))
                .frame(width: 6, height: 6)
            Text(s.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 84, alignment: .leading)
            Text(health.serviceDetail(s))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            switch status {
            case .ok(let ms):
                Text("\(ms)ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.spGreen)
            case .failed:
                Text("failed")
                    .font(.system(size: 11)).foregroundColor(.spRed)
            case .checking:
                ProgressView().controlSize(.mini)
            case .notConfigured, .unknown, .disabled:
                Text("optional")
                    .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 8)
        .help(statusHelp(status).isEmpty ? "\(s.displayName) — \(s.detail)" : statusHelp(status))
    }

    @ViewBuilder
    private func statusText(_ p: Provider, _ status: ProviderHealth.Status) -> some View {
        switch status {
        case .ok(let ms):
            Text("\(ms)ms")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.spGreen)
        case .failed:
            HStack(spacing: 8) {
                Text("failed")
                    .font(.system(size: 11)).foregroundColor(.spRed)
                Button("mute") { health.disable(p) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
            }
        case .disabled:
            Button("enable") { health.enable(p); Task { await health.checkAll() } }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
        case .checking:
            ProgressView().controlSize(.mini)
        case .notConfigured:
            Text("no key").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.6))
        case .unknown:
            Text(isConfigured(p) ? "—" : "no key")
                .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.6))
        }
    }

    private func dotColor(_ s: ProviderHealth.Status) -> Color {
        switch s {
        case .ok:            return .spGreen
        case .failed:        return .spRed
        case .checking:      return .spAmber
        case .disabled:      return .gray
        case .notConfigured: return .gray.opacity(0.4)
        case .unknown:       return .spSubtext
        }
    }

    private func statusHelp(_ s: ProviderHealth.Status) -> String {
        if case .failed(let msg) = s { return msg }
        return ""
    }
}

struct ContextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary.opacity(0.8))

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary.opacity(0.45))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1))
            )
        }
    }
}
