import SwiftUI

struct AnswerView: View {
    @ObservedObject var vm: AppViewModel

    // What's on screen: a past tab, or the live answer
    private var displayedQuestion: String {
        if let i = vm.viewingIndex, vm.turns.indices.contains(i) { return vm.turns[i].question }
        return vm.currentQuestion
    }
    private var displayedAnswer: String {
        if let i = vm.viewingIndex, vm.turns.indices.contains(i) { return vm.turns[i].answer }
        return vm.answer
    }
    private var isViewingLive: Bool { vm.viewingIndex == nil }

    var body: some View {
        VStack(spacing: 0) {
            // Chat tabs — every past Q&A of the session, one tap away
            if vm.turns.count > 1 || (!vm.turns.isEmpty && !isViewingLive) || (vm.turns.count == 1 && vm.isLoadingAnswer) {
                tabBar
                Divider().opacity(0.15)
            }

            // Question strip
            if !displayedQuestion.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text("Q")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.spAmber)
                        .frame(width: 17, height: 17)
                        .background(Color.spAmberDim)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(displayedQuestion)
                        .font(.system(size: 12))
                        .foregroundColor(.spSubtext)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let i = vm.viewingIndex, vm.turns.indices.contains(i) {
                        Text("\(vm.turns[i].modeLabel) · \(vm.turns[i].modelLabel)")
                            .font(.system(size: 9))
                            .foregroundColor(.spSubtext)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                Divider().opacity(0.15)
            }

            // Answer
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if isViewingLive && vm.isLoadingAnswer {
                        LoadingDots()
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !displayedAnswer.isEmpty {
                        MarkdownView(text: displayedAnswer)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(minHeight: 500, maxHeight: 900)
        }
        // amber left accent
        .overlay(alignment: .topLeading) {
            Capsule()
                .fill(Color.spAmber)
                .frame(width: 3, height: 24)
                .padding(.leading, 6)
                .padding(.top, 10)
                .opacity(vm.isLoadingAnswer && isViewingLive ? 0.4 : 1)
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(vm.turns.enumerated()), id: \.element.id) { i, turn in
                        // The newest turn IS the live answer once it completes —
                        // show it as "Live" unless a newer one is streaming.
                        let isCurrentTab = vm.viewingIndex == i
                        Button {
                            vm.viewingIndex = i
                        } label: {
                            Text(tabTitle(i, turn))
                                .font(.system(size: 10, weight: isCurrentTab ? .bold : .medium))
                                .foregroundColor(isCurrentTab ? .spAmber : .spSubtext)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(isCurrentTab ? Color.spAmberDim : Color.primary.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                        .id(i)
                        .help(turn.question)
                    }

                    // Live tab — current streaming/latest answer
                    Button {
                        vm.viewingIndex = nil
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(vm.isLoadingAnswer ? Color.spGreen : Color.spSubtext)
                                .frame(width: 4, height: 4)
                            Text("Live")
                                .font(.system(size: 10, weight: isViewingLive ? .bold : .medium))
                        }
                        .foregroundColor(isViewingLive ? .spGreen : .spSubtext)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(isViewingLive ? Color.spGreenDim : Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .id(-1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .onChange(of: vm.turns.count) { _ in
                withAnimation { proxy.scrollTo(-1, anchor: .trailing) }
            }
        }
    }

    private func tabTitle(_ i: Int, _ turn: AppViewModel.DisplayTurn) -> String {
        let words = turn.question.split(separator: " ").prefix(3).joined(separator: " ")
        return "\(i + 1) · \(String(words.prefix(22)))"
    }
}

// MARK: - Loading dots
struct LoadingDots: View {
    @State private var phase = 0
    let timer = Timer.publish(every: 0.38, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i == phase ? Color.spAmber : Color.spSubtext)
                    .frame(width: 5, height: 5)
                    .scaleEffect(i == phase ? 1.3 : 1)
                    .animation(.easeInOut(duration: 0.28), value: phase)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
