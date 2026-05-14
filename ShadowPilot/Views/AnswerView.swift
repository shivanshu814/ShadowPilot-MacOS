import SwiftUI

struct AnswerView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Heard strip
            if !vm.transcript.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text("Q")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(.spAmber)
                        .frame(width: 17, height: 17)
                        .background(Color.spAmberDim)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(vm.transcript)
                        .font(.system(size: 12))
                        .foregroundColor(.spSubtext)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                Divider().opacity(0.15)
            }

            // Answer
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if vm.isLoadingAnswer {
                        LoadingDots()
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !vm.answer.isEmpty {
                        MarkdownView(text: vm.answer)
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
                .opacity(vm.isLoadingAnswer ? 0.4 : 1)
        }
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
