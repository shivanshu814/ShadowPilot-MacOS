import Foundation

// Health check for every configured provider: tiny concurrent probes at launch
// and on demand, with measured latency. Failed providers are skipped by the
// router; users can persistently disable a provider.
@MainActor
final class ProviderHealth: ObservableObject {
    static let shared = ProviderHealth()

    enum Status: Equatable {
        case unknown, checking
        case ok(latencyMs: Int)
        case failed(String)
        case notConfigured
        case disabled
    }

    @Published var status: [Provider: Status] = [:]
    @Published var isChecking = false

    private let disabledKey = "sp.disabledProviders"

    private init() {
        for p in Provider.allCases {
            status[p] = disabledProviders.contains(p.rawValue) ? .disabled : .unknown
        }
    }

    private var disabledProviders: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: disabledKey) }
    }

    // Router gate: usable unless it failed a check or is disabled.
    // (.unknown is usable so the app works before the first check completes.)
    func isUsable(_ p: Provider) -> Bool {
        switch status[p] ?? .unknown {
        case .failed, .disabled, .notConfigured: return false
        default: return true
        }
    }

    func disable(_ p: Provider) {
        disabledProviders.insert(p.rawValue)
        status[p] = .disabled
    }

    func enable(_ p: Provider) {
        disabledProviders.remove(p.rawValue)
        status[p] = .unknown
    }

    func modelLabel(_ p: Provider) -> String {
        switch p {
        case .groq:       return ModelConfig.groqFast
        case .cloudflare: return ModelConfig.cloudflareFast
        case .bedrock:    return ModelConfig.bedrockModel
        case .openRouter: return ModelConfig.openRouterSmart
        case .openAI:     return ModelConfig.openAIModel
        }
    }

    // MARK: - Probing

    func checkAll() async {
        isChecking = true
        await withTaskGroup(of: (Provider, Status).self) { group in
            for p in Provider.allCases where status[p] != .disabled {
                group.addTask { await Self.probe(p) }
            }
            for await (p, s) in group { status[p] = s }
        }
        isChecking = false
    }

    private nonisolated static func probe(_ p: Provider) async -> (Provider, Status) {
        let start = Date()
        do {
            switch p {
            case .groq:
                guard !EnvConfig.groqKey.isEmpty else { return (p, .notConfigured) }
                try await GPTService(apiKey: EnvConfig.groqKey,
                                     baseURL: "https://api.groq.com/openai/v1",
                                     model: ModelConfig.groqFast).probe()
            case .cloudflare:
                guard !EnvConfig.cloudflareAccountId.isEmpty, !EnvConfig.cloudflareToken.isEmpty else { return (p, .notConfigured) }
                try await GPTService(apiKey: EnvConfig.cloudflareToken,
                                     baseURL: "https://api.cloudflare.com/client/v4/accounts/\(EnvConfig.cloudflareAccountId)/ai/v1",
                                     model: ModelConfig.cloudflareFast).probe()
            case .bedrock:
                guard !EnvConfig.bedrockKey.isEmpty else { return (p, .notConfigured) }
                // Bedrock is NOT OpenAI-compatible — Bedrock-shaped probe
                try await BedrockService(apiKey: EnvConfig.bedrockKey,
                                         region: EnvConfig.bedrockRegion,
                                         modelId: ModelConfig.bedrockModel).probe()
            case .openRouter:
                guard !EnvConfig.openRouterKey.isEmpty else { return (p, .notConfigured) }
                try await GPTService(apiKey: EnvConfig.openRouterKey,
                                     baseURL: "https://openrouter.ai/api/v1",
                                     model: ModelConfig.openRouterSmart).probe()
            case .openAI:
                guard !EnvConfig.openAIKey.isEmpty else { return (p, .notConfigured) }
                try await GPTService(apiKey: EnvConfig.openAIKey,
                                     model: ModelConfig.openAIModel).probe()
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return (p, .ok(latencyMs: ms))
        } catch {
            return (p, .failed(error.localizedDescription))
        }
    }
}
