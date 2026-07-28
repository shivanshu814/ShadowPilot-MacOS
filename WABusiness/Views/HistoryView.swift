import SwiftUI
import AppKit

// ═══════════════════════════════════════════════════════════════
//  WA Business Dashboard — ChatGPT-style two-pane chat experience.
//  Left: new chat + searchable session history grouped by date.
//  Right: live conversation with streaming answers and an input bar,
//  or a read-only transcript of any past session.
// ═══════════════════════════════════════════════════════════════

struct DashboardView: View {
    @ObservedObject var vm = AppViewModel.shared
    @ObservedObject private var health = ProviderHealth.shared

    @State private var sessions: [SessionRow] = []
    @State private var selectedSessionId: String?   // nil = live session
    @State private var storedEntries: [EntryRow] = []
    @State private var searchText = ""
    @State private var searchResults: [EntryRow] = []
    @State private var input = ""
    @State private var confirmDeleteAll = false
    @FocusState private var inputFocused: Bool

    private var isLive: Bool { selectedSessionId == nil && searchText.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.25)
            chatArea
        }
        .frame(minWidth: 940, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            reloadSessions()
            inputFocused = true
        }
        .onChange(of: vm.turns.count) { _ in reloadSessions() }
        .alert("Delete ALL history?", isPresented: $confirmDeleteAll) {
            Button("Delete everything", role: .destructive) {
                SessionStore.shared.deleteAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reloadSessions() }
                selectedSessionId = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all sessions locally and from cloud backup on next sync.")
        }
    }

    // ═══════════════════════════ SIDEBAR ═══════════════════════════

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Logo
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.spAmber, .orange],
                                                    startPoint: .top, endPoint: .bottom))
                Text("WA Business")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 14)

            // New chat
            Button {
                vm.clear()
                selectedSessionId = nil
                searchText = ""
                searchResults = []
                reloadSessions()
                inputFocused = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("New chat")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(Color.black.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [.spAmber, .orange],
                                             startPoint: .leading, endPoint: .trailing))
                )
                .shadow(color: Color.spAmber.opacity(0.25), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("Search chats...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onSubmit { runSearch() }
                if !searchText.isEmpty {
                    Button { searchText = ""; searchResults = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Session list
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    liveSessionRow

                    ForEach(groupedSessions, id: \.0) { group, rows in
                        Text(group)
                            .font(.system(size: 9.5, weight: .bold)).tracking(1.2)
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 3)
                        ForEach(rows) { s in sessionRow(s) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.2)

            // Footer — provider health at a glance
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Provider.allCases) { p in
                        Circle()
                            .fill(footerDot(p))
                            .frame(width: 5, height: 5)
                            .help("\(p.displayName): \(footerHelp(p))")
                    }
                }
                Text("providers")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                Button { confirmDeleteAll = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete all history")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 248)
        .background(Color.primary.opacity(0.035))
    }

    private var liveSessionRow: some View {
        Button {
            selectedSessionId = nil
            searchText = ""
            searchResults = []
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color.spGreen).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vm.turns.first.map { String($0.question.prefix(26)) } ?? "New chat")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(vm.turns.isEmpty ? "start asking…" : "\(vm.turns.count) messages · live")
                        .font(.system(size: 9.5)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(isLive ? Color.spGreenDim : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ s: SessionRow) -> some View {
        let selected = selectedSessionId == s.id && searchText.isEmpty
        return Button {
            selectedSessionId = s.id
            storedEntries = SessionStore.shared.fetchEntries(sessionId: s.id)
            searchText = ""
            searchResults = []
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                    .foregroundColor(selected ? .spAmber : .secondary.opacity(0.6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundColor(.primary.opacity(selected ? 1 : 0.85))
                        .lineLimit(1)
                    Text("\(s.entryCount) messages")
                        .font(.system(size: 9.5)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.spAmberDim : Color.clear))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Export as Markdown") { exportStored(s.id, title: s.title) }
            Button("Delete", role: .destructive) {
                SessionStore.shared.deleteSession(s.id)
                if selectedSessionId == s.id { selectedSessionId = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reloadSessions() }
            }
        }
    }

    // ═══════════════════════════ CHAT AREA ═══════════════════════════

    private var chatArea: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().opacity(0.2)

            if !searchText.isEmpty {
                searchResultsList
            } else if isLive {
                liveChat
            } else {
                storedChat
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatHeader: some View {
        HStack(spacing: 10) {
            if !searchText.isEmpty {
                Text("Search: \"\(searchText)\"")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(searchResults.count) results")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else if isLive {
                Circle().fill(Color.spGreen).frame(width: 7, height: 7)
                Text(vm.turns.first.map { String($0.question.prefix(50)) } ?? "New chat")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if vm.liveAnswerActive {
                    Text("thinking…")
                        .font(.system(size: 10)).foregroundColor(.spAmber)
                }
            } else if let s = sessions.first(where: { $0.id == selectedSessionId }) {
                Image(systemName: "clock")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text(s.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer()
            if isLive && !vm.turns.isEmpty && searchText.isEmpty {
                headerButton("square.and.arrow.up", "Export chat") { exportLive() }
                headerButton("eraser", "Clear chat") { vm.clear() }
            } else if let id = selectedSessionId, searchText.isEmpty {
                headerButton("square.and.arrow.up", "Export chat") {
                    exportStored(id, title: sessions.first { $0.id == id }?.title ?? "Session")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private func headerButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // ─────────── Live chat (streaming + input) ───────────

    private var liveChat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    // Plain VStack — LazyVStack mis-measures selectable wrapped text
                    // (truncated lines, overlapping headings)
                    VStack(alignment: .leading, spacing: 18) {
                        if vm.turns.isEmpty && !vm.liveAnswerActive {
                            emptyState
                        }
                        ForEach(vm.turns) { turn in
                            questionBubble(turn.question)
                            answerCard(turn.answer, mode: turn.modeLabel, model: turn.modelLabel)
                        }
                        if vm.liveAnswerActive {
                            questionBubble(vm.currentQuestion)
                            liveAnswerCard
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: vm.answer) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: vm.turns.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: vm.liveAnswerActive) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            inputBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LinearGradient(colors: [.spAmber.opacity(0.7), .orange.opacity(0.4)],
                                                startPoint: .top, endPoint: .bottom))
            Text("Ask anything")
                .font(.system(size: 18, weight: .semibold))
            Text("Questions route to the best model automatically —\nQ&A hits Groq in under a second.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                suggestionChip("Tell me about yourself")
                suggestionChip("Design a URL shortener")
                suggestionChip("Implement two sum")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            vm.getAnswer(question: text)
        } label: {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.spSubtext)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.05))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    private var liveAnswerCard: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                if vm.answer.isEmpty {
                    LoadingDots().padding(.vertical, 4)
                } else {
                    MarkdownView(text: vm.answer)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
        }
    }

    // ─────────── Stored session (read-only) ───────────

    private var storedChat: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(storedEntries) { e in
                    questionBubble(e.question)
                    answerCard(e.answer, mode: e.mode, model: e.model, ts: e.ts, entryId: e.id)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
    }

    // ─────────── Search results ───────────

    private var searchResultsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if searchResults.isEmpty {
                    Text("No matches — press Enter in the search box to search.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                }
                ForEach(searchResults) { e in
                    questionBubble(e.question)
                    answerCard(e.answer, mode: e.mode, model: e.model, ts: e.ts, entryId: e.id)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
    }

    // ─────────── Bubbles ───────────

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.spAmber, .orange],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 26, height: 26)
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black.opacity(0.8))
        }
    }

    private func questionBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.92))
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.spAmber.opacity(0.13))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.spAmber.opacity(0.2), lineWidth: 1))
                )
        }
    }

    private func answerCard(_ text: String, mode: String, model: String,
                            ts: Date? = nil, entryId: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    badge(mode, color: .spBlue)
                    Text(model)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let ts {
                        Text(Self.timeFmt.string(from: ts))
                            .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy answer")
                    if let entryId {
                        Button {
                            SessionStore.shared.deleteEntry(entryId)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                if let id = selectedSessionId {
                                    storedEntries = SessionStore.shared.fetchEntries(sessionId: id)
                                }
                                if !searchText.isEmpty { runSearch() }
                                reloadSessions()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this Q&A")
                    }
                }
                MarkdownView(text: text)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    // ─────────── Input bar ───────────

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.2)
            HStack(spacing: 10) {
                // Mode picker
                Menu {
                    ForEach(AnswerMode.allCases) { m in
                        Button {
                            vm.answerMode = m
                        } label: {
                            HStack {
                                Text(m.label)
                                if vm.answerMode == m { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                        Text(vm.answerMode.label)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.spSubtext)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Text input
                TextField("Ask anything — routes to the best model…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { send() }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(Color.primary.opacity(0.055))
                            .overlay(RoundedRectangle(cornerRadius: 22)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    )

                // Send
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black.opacity(0.8))
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(
                                input.trimmingCharacters(in: .whitespaces).isEmpty
                                ? AnyShapeStyle(Color.primary.opacity(0.1))
                                : AnyShapeStyle(LinearGradient(colors: [.spAmber, .orange],
                                                               startPoint: .top, endPoint: .bottom)))
                        )
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(.ultraThinMaterial.opacity(0.4))
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        vm.getAnswer(question: q)
    }

    private func footerDot(_ p: Provider) -> Color {
        switch health.status[p] ?? .unknown {
        case .ok:            return .spGreen
        case .failed:        return .spRed
        case .checking:      return .spAmber
        case .disabled, .notConfigured: return .gray.opacity(0.4)
        case .unknown:       return .spSubtext
        }
    }

    private func footerHelp(_ p: Provider) -> String {
        switch health.status[p] ?? .unknown {
        case .ok(let ms):       return "ok · \(ms)ms"
        case .failed(let msg):  return "failed — \(msg.prefix(60))"
        case .checking:         return "checking…"
        case .disabled:         return "disabled"
        case .notConfigured:    return "no key"
        case .unknown:          return "not tested yet"
        }
    }

    // ─────────── Data helpers ───────────

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    private var groupedSessions: [(String, [SessionRow])] {
        let cal = Calendar.current
        var today: [SessionRow] = [], yesterday: [SessionRow] = [], week: [SessionRow] = [], older: [SessionRow] = []
        let filter = searchText.lowercased()
        for s in sessions {
            if !filter.isEmpty && !s.title.lowercased().contains(filter) { continue }
            if cal.isDateInToday(s.startedAt) { today.append(s) }
            else if cal.isDateInYesterday(s.startedAt) { yesterday.append(s) }
            else if s.startedAt > Date().addingTimeInterval(-7 * 86400) { week.append(s) }
            else { older.append(s) }
        }
        var out: [(String, [SessionRow])] = []
        if !today.isEmpty     { out.append(("TODAY", today)) }
        if !yesterday.isEmpty { out.append(("YESTERDAY", yesterday)) }
        if !week.isEmpty      { out.append(("PREVIOUS 7 DAYS", week)) }
        if !older.isEmpty     { out.append(("OLDER", older)) }
        return out
    }

    private func reloadSessions() {
        sessions = SessionStore.shared.fetchSessions()
    }

    private func runSearch() {
        searchResults = searchText.isEmpty ? [] : SessionStore.shared.search(searchText)
        if !searchText.isEmpty { selectedSessionId = nil }
    }

    private func exportLive() {
        var md = "# WA Business Session\n\n"
        for t in vm.turns {
            md += "## Q: \(t.question)\n\n_\(t.modeLabel) · \(t.modelLabel)_\n\n\(t.answer)\n\n---\n\n"
        }
        saveMarkdown(md, name: "session.md")
    }

    private func exportStored(_ id: String, title: String) {
        saveMarkdown(SessionStore.shared.exportMarkdown(sessionId: id),
                     name: "\(title.prefix(30)).md")
    }

    private func saveMarkdown(_ md: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// ═══════════════════════════ WINDOW ═══════════════════════════

enum DashboardWindow {
    private static var controller: NSWindowController?

    @MainActor
    static func show() {
        if let c = controller {
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "WA Business"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 600)
        window.center()
        window.contentView = NSHostingView(rootView: DashboardView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller = NSWindowController(window: window)
    }
}
