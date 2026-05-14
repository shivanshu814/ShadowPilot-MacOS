import SwiftUI

struct SetupView: View {
    @AppStorage("jd") var jd = ""
    @AppStorage("resume") var resume = ""
    @Binding var isSetupDone: Bool

    private var hasKeys: Bool {
        !EnvConfig.openAIKey.isEmpty || !EnvConfig.openRouterKey.isEmpty
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.spAmber)
                            .frame(width: 4, height: 20)
                        Text("SHADOWPILOT")
                            .font(.system(size: 10, weight: .black))
                            .tracking(3)
                            .foregroundColor(.spAmber)
                    }
                    Text("Session Setup")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                    Text("Paste context so every answer is tailored to this role.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 24)

                // API key status
                HStack(spacing: 8) {
                    Circle()
                        .fill(hasKeys ? Color.green : Color.spRed)
                        .frame(width: 7, height: 7)
                    Text(hasKeys ? "API keys loaded from .env" : "No API keys — check /Applications/.env")
                        .font(.system(size: 12))
                        .foregroundColor(hasKeys ? .secondary : Color.spRed)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hasKeys ? Color.primary.opacity(0.04) : Color.spRed.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(hasKeys ? Color.primary.opacity(0.1) : Color.spRed.opacity(0.3), lineWidth: 1))
                )
                .padding(.bottom, 22)

                ContextField(label: "JOB DESCRIPTION", placeholder: "Paste the job posting here…", text: $jd, height: 120)
                    .padding(.bottom, 14)

                ContextField(label: "YOUR RESUME", placeholder: "Paste your resume here…", text: $resume, height: 120)
                    .padding(.bottom, 26)

                Button(action: { isSetupDone = true }) {
                    HStack(spacing: 8) {
                        Text("Begin Session")
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(hasKeys ? Color.black.opacity(0.85) : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(hasKeys ? Color.spAmber : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(!hasKeys)

                if !hasKeys {
                    Text("Add OPENAI_API_KEY or OPENROUTER_API_KEY to /Applications/.env and relaunch.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(28)
        }
        .background(.ultraThinMaterial)
        .frame(width: 460)
    }
}

struct ContextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundColor(.secondary)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1))
            )
        }
    }
}
