import SwiftUI

// Splits markdown into text and fenced code block segments
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments(text).enumerated()), id: \.offset) { _, seg in
                if seg.isCode {
                    CodeBlockView(code: seg.content, lang: seg.lang)
                } else if !seg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inlineMarkdown(seg.content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Inline markdown via AttributedString
    @ViewBuilder
    private func inlineMarkdown(_ raw: String) -> some View {
        if let attr = try? AttributedString(markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr)
                .font(.system(size: 13))
                .foregroundColor(.spText)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(raw)
                .font(.system(size: 13))
                .foregroundColor(.spText)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Segment parser
    private struct Segment {
        let content: String
        let isCode: Bool
        let lang: String
    }

    private func segments(_ input: String) -> [Segment] {
        var result: [Segment] = []
        let pattern = #"```([a-zA-Z0-9+#]*)\n?([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [Segment(content: input, isCode: false, lang: "")]
        }
        let ns = input as NSString
        var cursor = 0
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let preRange = NSRange(location: cursor, length: match.range.location - cursor)
            if preRange.length > 0 {
                result.append(Segment(content: ns.substring(with: preRange), isCode: false, lang: ""))
            }
            let lang = match.numberOfRanges > 1 ? ns.substring(with: match.range(at: 1)) : ""
            let code = match.numberOfRanges > 2 ? ns.substring(with: match.range(at: 2)) : ""
            result.append(Segment(content: code, isCode: true, lang: lang))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(Segment(content: ns.substring(from: cursor), isCode: false, lang: ""))
        }
        return result.isEmpty ? [Segment(content: input, isCode: false, lang: "")] : result
    }
}

// MARK: - Code block
struct CodeBlockView: View {
    let code: String
    let lang: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                if !lang.isEmpty {
                    Text(lang.lowercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.spAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.spAmberDim)
                        .clipShape(Capsule())
                }
                Spacer()
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(copied ? .spAmber : .spSubtext)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06))

            Divider().opacity(0.12)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.85, green: 0.93, blue: 0.82))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.trimmingCharacters(in: .newlines), forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}
