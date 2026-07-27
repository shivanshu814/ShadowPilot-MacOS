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

// MARK: - Accent / speaking-style presets

// The answer is read aloud BY the user, so it must sound natural in THEIR
// English — accent preset sets the dialect, styleSample captures their voice.
enum AccentPreset: String, CaseIterable, Identifiable {
    case indian, neutral, american, british, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .indian:   return "Indian"
        case .neutral:  return "Neutral"
        case .american: return "US"
        case .british:  return "UK"
        case .custom:   return "Custom"
        }
    }

    // Locale for transcribing the user's own voice — matching the accent
    // makes Apple Speech far more accurate.
    var speechLocale: String {
        switch self {
        case .indian:   return "en-IN"
        case .neutral:  return "en-US"
        case .american: return "en-US"
        case .british:  return "en-GB"
        case .custom:   return "en-US"
        }
    }

    // customDescription is the user's own words describing how THEY speak —
    // only used by the .custom case; presets ignore it.
    func promptDescription(customDescription: String) -> String {
        switch self {
        case .indian:
            return "I speak Indian English — the natural, fluent English of a professional engineer working in India. Use phrasing, connectors and vocabulary that sound native to Indian English (\"basically\", \"so what happens is\", \"the thing is\"), and avoid distinctly American slang or idioms I would never say (\"ballpark\", \"touch base\", \"y'all\", \"gonna\"). Keep it professional — natural accent, not caricature."
        case .neutral:
            return "I speak neutral international English. Avoid region-specific slang and idioms entirely — plain, globally natural phrasing."
        case .american:
            return "I speak American English. Natural US phrasing and idioms are fine."
        case .british:
            return "I speak British English. Use British phrasing, vocabulary and spelling (organise, whilst is fine sparingly), and avoid Americanisms."
        case .custom:
            let desc = customDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !desc.isEmpty else {
                return "I speak neutral international English. Avoid region-specific slang and idioms entirely."
            }
            return "Here is how I speak English, in my own words — follow this exactly when writing my answers:\n\(desc)"
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

    // Injected right after the persona — the accent/style shapes EVERY spoken word,
    // so it must come before mode instructions and context.
    static func speakingStyleBlock(accent: String, styleSample: String, customAccent: String) -> String {
        guard let preset = AccentPreset(rawValue: accent) else { return "" }
        var s = """


MY SPEAKING STYLE — I will read your answer aloud in my own voice, so it must sound like ME, not like a generic AI:
- \(preset.promptDescription(customDescription: customAccent))
"""
        let sample = styleSample.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sample.isEmpty {
            // Cap the sample so it never crowds out JD/resume in the context budget
            let capped = sample.count > 1500 ? String(sample.prefix(1500)) + "…" : sample
            s += """

- Below is a real transcript of me speaking. Study it and mirror MY voice: my typical sentence length and rhythm, my word choices, my connector words and habits, how I start and wrap up a thought. Mimic ONLY the style — never reuse its content or facts unless the question is actually about them.
--- MY VOICE SAMPLE ---
\(capped)
--- END SAMPLE ---
"""
        }
        return s
    }

    static func systemPrompt(for mode: AnswerMode, jd: String, resume: String,
                             accent: String = "", styleSample: String = "",
                             customAccent: String = "") -> String {
        var s = persona
        s += speakingStyleBlock(accent: accent, styleSample: styleSample, customAccent: customAccent)
        s += "\n\n"
        switch mode {
        case .interview, .auto:
            s += """
Here is my job description and resume below. Pretend you ARE me and answer in first person, drawing from my resume.

For a technical/concept question ("what is X", "how does X work", "difference between X and Y"), follow this exact flow, each part 1-2 SHORT spoken lines:
Question → Definition → Working → Example → Use Cases
Label each section on its own line (**Question:**, **Definition:**, **Working:**, **Example:**, **Use Cases:**). Keep the whole thing short — it must sound like my real spoken words, not an essay.

For a behavioral/resume question, skip the template — just answer naturally in 3-5 conversational sentences. Either way: answer ONLY what was asked, no padding.
"""
        case .codeReview:
            s += """
You are reviewing code like a senior engineer reviewing a colleague's PR — direct but collegial ("this will bite us when X"). Follow this exact flow, each section SHORT:
Code → Understanding → Issues → Suggestions → Summary
Label each section on its own line:
**Code:** one line on what code we're looking at.
**Understanding:** 1-2 lines — what this code is trying to do, in my words.
**Issues:** the concrete defects, most-severe first — what's wrong and where (file/line). Nothing generic.
**Suggestions:** exactly what to change for each issue (before → after in fenced code when it helps).
**Summary:** one spoken line — my overall take.
Review ONLY the code and aspects the question points at — if asked about one function or one concern (e.g. just security), stay on that and shrink the template to fit. Keep it short enough to say aloud naturally.
""" + incrementalRule
        case .systemDesign:
            s += """
Follow this exact flow, each section SHORT (2-4 crisp bullets max):
Problem → Requirements → Design → Components → Trade-offs
Label each section on its own line:
**Problem:** one line — what we're building, in my words.
**Requirements:** functional + the 1-2 non-functional ones that actually matter here. Brief capacity estimate ONLY if scale is part of the question.
**Design:** the chosen architecture — pick one and commit, plus the diagram (rules below).
**Components:** each key component and its one-line job.
**Trade-offs:** why this over the alternative, the ONE bottleneck that matters, and what I'd NOT build in v1.

SCOPE DISCIPLINE — answer EXACTLY what was asked:
- A narrow follow-up ("how would you handle payment?") gets ONLY that — skip the template.
- A focused scenario question gets the template scoped tightly to that flow — no planet-scale math for a single parking garage.
- Keep the whole answer deliverable aloud in ~3-4 minutes. Short sections, real spoken words, never pad.

SPEAKABILITY — this is read aloud in a live interview:
- Short, crisp bullets. No rambling paragraphs, no filler sentences, no "let's say" hedging chains.
- Most important decision FIRST in every section. Depth over breadth.

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
When a full solution is asked (the default for a coding problem), follow this exact flow, each part 1-2 SHORT spoken lines (code excepted):
Question → Approach → Data Structure → Time Complexity → Space Complexity → Go Code → What to say to interviewer
Label each section on its own line:
**Question:** one line — the problem restated in my words.
**Approach:** the trick/plan in plain spoken language ("the trick here is...").
**Data Structure:** which one and why, one line.
**Time Complexity:** e.g. O(n) — with a half-line why.
**Space Complexity:** same.
**Go Code:** the full solution in Go (unless the question demands another language), in a ```go fenced block, with a short comment on every line.
**What to say:** 2-3 natural spoken lines I can say while walking the interviewer through it.
Keep every non-code section tight — it must sound like my real words, not an article.
But scope rules win: if only the approach, only a fix, only complexity, or only one part is asked — give ONLY that, skip the rest of the template.
"""
        }
        if !jd.isEmpty     { s += "\n\nJob Description:\n\(jd)" }
        if !resume.isEmpty { s += "\n\nMy Resume:\n\(resume)" }
        return s
    }

    static func visionPrompt(jd: String, resume: String) -> String {
        var p = """
Analyze this screenshot and answer EXACTLY what it asks — scope your answer to the question on screen, nothing extra.

If it contains a coding problem or algorithm question, follow this flow with short labeled sections: Question → Approach → Data Structure → Time Complexity → Space Complexity → Go Code → What to say to interviewer. Code in Go (unless the problem demands another language), in a ```go fenced block with a short comment on every line; every other section 1-2 short spoken lines.
If it contains a system design or conceptual question: give an opinionated design scoped to what's asked (Problem → Requirements → Design → Components → Trade-offs, short sections), with an ASCII architecture diagram in a fenced code block when you present an architecture.
If it contains a multiple choice or quiz question: state the correct answer clearly, then explain why — briefly.
Otherwise answer only what the screenshot is asking.
"""
        if !jd.isEmpty     { p += "\n\nJob Description context:\n\(jd)" }
        if !resume.isEmpty { p += "\n\nCandidate Resume:\n\(resume)" }
        return p
    }
}
