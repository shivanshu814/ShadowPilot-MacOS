import Foundation

// MARK: - Providers

enum Provider: String, CaseIterable, Identifiable {
    case groq, cloudflare, bedrock, openRouter, openAI
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq:       return "Groq"
        case .cloudflare: return "Cloudflare"
        case .bedrock:    return "Bedrock"
        case .openRouter: return "OpenRouter"
        case .openAI:     return "OpenAI"
        }
    }
}

// MARK: - Answer modes

enum AnswerMode: String, CaseIterable, Identifiable {
    case auto, interview, coding, codeReview, systemDesign
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:         return "Auto"
        case .interview:    return "Q&A"
        case .coding:       return "Code"
        case .codeReview:   return "Review"
        case .systemDesign: return "Design"
        }
    }

    var maxTokens: Int {
        switch self {
        case .interview, .auto: return 512
        case .codeReview:       return 4096
        case .coding:           return 8192
        case .systemDesign:     return 8192
        }
    }
}

// MARK: - Model config (SINGLE source of truth for every model id)

struct ModelConfig {
    // Overridable via .env so a renamed/failed id is fixable without recompiling
    static var groqFast: String       { EnvConfig.modelOverride("GROQ_MODEL") ?? "llama-3.3-70b-versatile" }
    static var cloudflareFast: String { EnvConfig.modelOverride("CF_MODEL") ?? "@cf/meta/llama-3.3-70b-instruct-fp8-fast" }
    static var bedrockModel: String   { EnvConfig.modelOverride("BEDROCK_MODEL") ?? "us.meta.llama3-3-70b-instruct-v1:0" }
    static var openRouterSmart: String { EnvConfig.modelOverride("OPENROUTER_SMART_MODEL") ?? "anthropic/claude-sonnet-4.5" }
    static var openRouterFallback: String { EnvConfig.modelOverride("OPENROUTER_FALLBACK_MODEL") ?? "openai/gpt-4o" }
    static var openAIModel: String    { EnvConfig.modelOverride("OPENAI_MODEL") ?? "gpt-4o" }
}

// MARK: - A routed, ready-to-call service

struct RoutedService {
    let provider: Provider
    let modelLabel: String   // short label for statusText, e.g. "Groq·Llama-3.3"
    let supportsVision: Bool
    let stream: (_ system: String, _ userText: String, _ history: [ConversationTurn], _ maxTokens: Int) -> AsyncThrowingStream<String, Error>
    let streamVision: ((_ system: String, _ prompt: String, _ image: Data, _ history: [ConversationTurn], _ maxTokens: Int) -> AsyncThrowingStream<String, Error>)?
}

// MARK: - Router

@MainActor
struct ModelRouter {

    // MARK: Service builders (nil when key missing or provider unhealthy/disabled)

    static func groq() -> RoutedService? {
        guard !EnvConfig.groqKey.isEmpty, ProviderHealth.shared.isUsable(.groq) else { return nil }
        let svc = GPTService(apiKey: EnvConfig.groqKey,
                             baseURL: "https://api.groq.com/openai/v1",
                             model: ModelConfig.groqFast)
        return wrap(svc, provider: .groq, label: "Groq·Llama-3.3", vision: false)
    }

    static func cloudflare() -> RoutedService? {
        guard !EnvConfig.cloudflareAccountId.isEmpty, !EnvConfig.cloudflareToken.isEmpty,
              ProviderHealth.shared.isUsable(.cloudflare) else { return nil }
        let svc = GPTService(apiKey: EnvConfig.cloudflareToken,
                             baseURL: "https://api.cloudflare.com/client/v4/accounts/\(EnvConfig.cloudflareAccountId)/ai/v1",
                             model: ModelConfig.cloudflareFast)
        return wrap(svc, provider: .cloudflare, label: "CF·Llama-3.3", vision: false)
    }

    static func bedrock() -> RoutedService? {
        guard !EnvConfig.bedrockKey.isEmpty, ProviderHealth.shared.isUsable(.bedrock) else { return nil }
        let svc = BedrockService(apiKey: EnvConfig.bedrockKey,
                                 region: EnvConfig.bedrockRegion,
                                 modelId: ModelConfig.bedrockModel)
        return RoutedService(
            provider: .bedrock, modelLabel: "Bedrock·Llama-3.3", supportsVision: true,
            stream: { sys, text, hist, max in svc.stream(system: sys, userText: text, history: hist, maxTokens: max) },
            streamVision: { sys, prompt, img, hist, max in svc.streamVision(system: sys, prompt: prompt, imageData: img, history: hist, maxTokens: max) }
        )
    }

    static func openRouterSmart() -> RoutedService? {
        guard !EnvConfig.openRouterKey.isEmpty, ProviderHealth.shared.isUsable(.openRouter) else { return nil }
        let svc = GPTService(apiKey: EnvConfig.openRouterKey,
                             baseURL: "https://openrouter.ai/api/v1",
                             model: ModelConfig.openRouterSmart)
        return wrap(svc, provider: .openRouter, label: "OR·Sonnet-4.5", vision: true)
    }

    static func openRouterFallback() -> RoutedService? {
        guard !EnvConfig.openRouterKey.isEmpty, ProviderHealth.shared.isUsable(.openRouter) else { return nil }
        let svc = GPTService(apiKey: EnvConfig.openRouterKey,
                             baseURL: "https://openrouter.ai/api/v1",
                             model: ModelConfig.openRouterFallback)
        return wrap(svc, provider: .openRouter, label: "OR·GPT-4o", vision: true)
    }

    static func openAI() -> RoutedService? {
        guard !EnvConfig.openAIKey.isEmpty, ProviderHealth.shared.isUsable(.openAI) else { return nil }
        let svc = GPTService(apiKey: EnvConfig.openAIKey, model: ModelConfig.openAIModel)
        return wrap(svc, provider: .openAI, label: "OpenAI·GPT-4o", vision: true)
    }

    private static func wrap(_ svc: GPTService, provider: Provider, label: String, vision: Bool) -> RoutedService {
        RoutedService(
            provider: provider, modelLabel: label, supportsVision: vision,
            stream: { sys, text, hist, max in svc.stream(system: sys, userText: text, history: hist, maxTokens: max) },
            streamVision: vision
                ? { sys, prompt, img, hist, max in svc.streamVision(system: sys, prompt: prompt, imageData: img, history: hist, maxTokens: max) }
                : nil
        )
    }

    // MARK: Fallback chains — fastest-first within acceptable quality

    static func chain(for mode: AnswerMode) -> [RoutedService] {
        let candidates: [RoutedService?]
        switch mode {
        case .interview, .auto:
            candidates = [groq(), cloudflare(), bedrock(), openAI(), openRouterFallback()]
        case .codeReview:
            candidates = [openRouterSmart(), openAI(), openRouterFallback(), groq(), bedrock()]
        case .systemDesign:
            candidates = [openRouterSmart(), openAI(), groq(), bedrock(), cloudflare()]
        case .coding:
            candidates = [openRouterSmart(), openAI(), openRouterFallback(), groq(), bedrock()]
        }
        return candidates.compactMap { $0 }
    }

    static func visionChain() -> [RoutedService] {
        [openRouterSmart(), openAI(), openRouterFallback()].compactMap { $0 }.filter { $0.supportsVision }
    }

    // MARK: Classification

    // Follow-up detection runs BEFORE classification: short questions or anaphora
    // without a new subject inherit the previous turn's resolved mode.
    static func resolveMode(question: String, selected: AnswerMode, previous: AnswerMode?) -> AnswerMode {
        if selected != .auto { return selected }
        if let previous, isFollowUp(question) { return previous }
        return classify(question)
    }

    static func isFollowUp(_ q: String) -> Bool {
        // Normalize: lowercase, strip punctuation, pad — so "of that?" matches "that"
        let cleaned = q.lowercased().replacingOccurrences(of: "[.,!?;:]", with: " ", options: .regularExpression)
        let padded = " " + cleaned.split(separator: " ").joined(separator: " ") + " "
        let words = cleaned.split(separator: " ").count
        let anaphora = ["that", "this", "there", "why is the", "why did", "what about", "how about",
                        "tell me more", "the first", "the second", "the third", "now", "also", "instead"]
        let hasAnaphora = anaphora.contains { padded.contains(" \($0) ") }
            || padded.contains(" it ")
        // A long question that introduces its own subject is not a follow-up
        if words < 12 && hasAnaphora { return true }
        if words < 6 { return true }   // very short — almost certainly refers to prior context
        return false
    }

    static func classify(_ q: String) -> AnswerMode {
        let lower = q.lowercased()

        let codeEvidence = ["```", "diff --", "+++", "---", "func ", "def ", "class ", "();", "=>", "public ", "return "]
            .contains { lower.contains($0) }
        let reviewIntent = ["review", "pull request", " pr ", "refactor", "code smell", "lgtm"]
            .contains { lower.contains($0) }
        if reviewIntent && (codeEvidence || lower.contains("code review") || lower.contains("pull request") || lower.contains(" pr ")) {
            return .codeReview
        }

        let designWords = ["design", "architect", "architecture", " scale ", "scalab", " hld", " lld", "high level design", "low level design"]
            .contains { lower.contains($0) }
        let systemNouns = ["system", "service", "api", "platform", "application", " app ", "pipeline", "feed",
                           "queue", "cache", "storage", "database", "million", "billion", "users", "traffic",
                           "distributed", "microservice", "shortener", "chat", "notification"]
            .contains { lower.contains($0) }
        let smallScopeWords = ["function", "method", "algorithm", "array", "string", "loop", "regex", "linked list", "binary tree"]
            .contains { lower.contains($0) }
        if designWords && systemNouns && !smallScopeWords { return .systemDesign }

        let codingIntent = ["write a function", "implement", "algorithm", "leetcode", "time complexity",
                            "write code", "solve", "two sum", "sorted array"]
            .contains { lower.contains($0) }
        if codingIntent || (codeEvidence && !reviewIntent) { return .coding }

        return .interview
    }

    // MARK: - Prompts

    // Shared persona — prepended to every mode prompt. Most of "not AI-sounding"
    // comes from REMOVING AI tells, not adding flourishes.
    private static let persona = """
You are answering AS the candidate — a principal-level engineer with 10+ years of hands-on experience building and scaling production systems. Voice rules, non-negotiable:
- Speak with the quiet confidence of experience: have opinions, commit to a recommendation, and mention tradeoffs like someone who has been burned by them in production ("I'd avoid X here — we tried it and it fell over once traffic got spiky").
- Sound like natural fluent spoken English, not written prose. Contractions always (I'd, we'd, that's). Occasional natural starters are fine ("So the way I think about it...", "Honestly, I'd keep it simple here...").
- BANNED — these instantly sound like AI: "Great question", "Certainly", "I'd be happy to", "It's important to note", "delve", "leverage" (as a verb), "robust and scalable" as a stock phrase, starting an answer by restating the question, symmetric three-point answers, exhaustive coverage of every angle. Real engineers go deep on the ONE thing that matters and mention the rest in passing, if at all.
- Ground claims in experience, not textbook framing: prefer "in my last project we hit exactly this" (drawing on the resume) over "generally, one should consider".
- It's fine to briefly acknowledge uncertainty like a senior person does ("I'd want to measure before committing, but my instinct is X") — that reads as experience, not weakness.
- SCOPE — the most important rule: answer EXACTLY what was asked, nothing more. Never pad with extra sections, never volunteer unrequested information, never follow a fixed answer template. The question's scope decides the answer's scope and length. A narrow question gets a narrow answer.
"""

    private static let incrementalRule = """

If the question is a follow-up modifying or querying your previous answer (visible in the conversation history), respond INCREMENTALLY — address only the change or the specific part asked about. Do NOT restate or regenerate the full design/review. E.g. "now add multi-region" → describe only what changes in the existing design.
"""

    static func systemPrompt(for mode: AnswerMode, jd: String, resume: String) -> String {
        var s = persona + "\n\n"
        switch mode {
        case .interview, .auto:
            s += """
Here is my job description and resume below. Pretend you ARE me and answer in a humanized, natural spoken way in 3-5 sentences. Never use bullet points or lists — flowing conversational prose only, first person, drawing from my resume. Answer ONLY what was asked — no extra info, no padding.
"""
        case .codeReview:
            s += """
You are reviewing code like a senior engineer reviewing a colleague's PR — direct but collegial ("this will bite us when X"). Review ONLY the code and aspects the question points at — if asked about one function or one concern (e.g. just security), stay on that. For each issue you raise: what is wrong, where (file/line), and exactly what to change (before → after in fenced code). Order most-severe first. Nothing generic — every point must name a concrete defect and its concrete fix. No summary sections or checklists unless asked.
""" + incrementalRule
        case .systemDesign:
            s += """
SCOPE DISCIPLINE — answer EXACTLY what was asked, nothing more:
- First identify what the question actually emphasizes, and structure the answer around THAT.
- A focused scenario question (a specific workflow like "camera reads plate → calculate fee → pay → exit") gets an answer built around that end-to-end flow: the flow, the components that serve it, the one hard problem in it, and the data/fee logic. NOT the full generic template.
- Only a broad "design X for N million users" question gets the full treatment: requirements, capacity estimates, architecture, data model, API sketch, bottlenecks, trade-offs, scaling path.
- Include a section ONLY if it earns its place for THIS question. A single parking garage does not need 5-year storage math or planet-scale capacity analysis — 2-3 lines of estimates at most. Never pad, never show off with unasked-for sections.
- If the interviewer asks a narrow follow-up ("how would you handle payment?"), answer ONLY that.

For whatever sections you do include: be opinionated, not a menu of options — pick an architecture, defend it, name the ONE bottleneck that matters most, and say what you'd explicitly NOT build in v1.

SPEAKABILITY — this is read aloud in a live interview:
- Short, crisp bullets. No rambling paragraphs, no filler sentences, no "let's say" hedging chains.
- Most important decision FIRST in every section.
- Total length: deliverable aloud in ~5 minutes. Depth over breadth.

MATH CORRECTNESS — the interviewer WILL check the arithmetic:
- State assumptions once, then derive every number step by step: "1M users → 10% concurrently playing = 100K players → 2 players/game = 50K games".
- Every derived number must be consistent with every other number in the answer. NEVER contradict an earlier figure. Re-verify each calculation before writing it.
- Use the same component names and numbers in the text, the diagram, and the estimates.

MANDATORY — Architecture diagram, immediately after the architecture heading, in a fenced code block (```):
- Simple VERTICAL layered layout: clients on top, gateways/services in the middle, data stores at the bottom.
- Maximum 8 boxes, maximum ~60 characters wide.
- Every box must be a perfectly closed rectangle using ┌─┐ │ └─┘ with aligned corners. Label arrows with the protocol (WS/HTTP/pub-sub). NO dangling lines, NO half-drawn boxes, NO crossing arrows — when in doubt, simplify the layout.
- Verify each line of the diagram is the same visual width before moving on. Example style:

```
        ┌─────────────────────┐
        │  Client (web/mobile)│
        └──────────┬──────────┘
              WS   │   HTTP
        ┌──────────▼──────────┐
        │      WS Gateway     │
        └──────────┬──────────┘
                   │ route
        ┌──────────▼──────────┐     ┌──────────────────┐
        │     Game Service    │◄───►│  Matchmaking Svc │
        └──────┬───────┬──────┘     └──────────────────┘
               │       │
        ┌──────▼──┐ ┌──▼───────┐
        │  Redis  │ │ Postgres │
        └─────────┘ └──────────┘
```

The diagram is required whenever you present an architecture. For a narrow follow-up that doesn't introduce an architecture ("how would you handle payment?"), skip it — scope rules win.
""" + incrementalRule
        case .coding:
            s += """
When a full solution is asked (the default for a coding problem): approach first — a short plain-language plan in your natural voice ("the trick here is...") — then the full solution code with a comment on every line, in a language-tagged fenced code block, then a short time/space complexity note.
But scope rules apply: if only the approach, only a fix, only complexity, or only one part is asked — give ONLY that. Don't dump the full solution structure for a narrow question.
"""
        }
        if !jd.isEmpty     { s += "\n\nJob Description:\n\(jd)" }
        if !resume.isEmpty { s += "\n\nMy Resume:\n\(resume)" }
        return s
    }

    static func visionPrompt(jd: String, resume: String) -> String {
        var p = """
Analyze this screenshot and answer EXACTLY what it asks — scope your answer to the question on screen, nothing extra.

If it contains a coding problem or algorithm question: give the approach first (short plain-language plan), then a complete, correct solution with a comment on every line in a language-tagged fenced code block, then a short time/space complexity note.
If it contains a system design or conceptual question: give an opinionated design scoped to what's asked, with an ASCII architecture diagram in a fenced code block when you present an architecture.
If it contains a multiple choice or quiz question: state the correct answer clearly, then explain why — briefly.
Otherwise answer only what the screenshot is asking.
"""
        if !jd.isEmpty     { p += "\n\nJob Description context:\n\(jd)" }
        if !resume.isEmpty { p += "\n\nCandidate Resume:\n\(resume)" }
        return p
    }
}
