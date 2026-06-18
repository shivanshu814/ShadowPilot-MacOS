import Foundation

class GPTService {
    private let apiKey: String
    private let baseURL: String
    private let model: String

    init(apiKey: String, baseURL: String = "https://api.openai.com/v1", model: String = "gpt-4o") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    // MARK: - Audio transcript answer (with conversation history for follow-up mode)
    func stream(transcript: String, jd: String, resume: String,
                history: [ConversationTurn] = []) -> AsyncThrowingStream<String, Error> {

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt(jd: jd, resume: resume)]
        ]

        // inject prior turns for follow-up context (last 6 turns max)
        for turn in history.suffix(6) {
            messages.append(["role": "user",      "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }

        let userContent = "Interview question:\n\(transcript)"
        messages.append(["role": "user", "content": userContent])

        return streamMessages(messages)
    }

    // MARK: - Screenshot / vision analysis
    func streamVision(imageData: Data, jd: String, resume: String,
                      history: [ConversationTurn] = []) -> AsyncThrowingStream<String, Error> {
        let base64 = imageData.base64EncodedString()

        var messages: [[String: Any]] = [
            ["role": "system", "content": """
You are ShadowPilot, a Principal Engineer with 15+ years of experience. Analyze the screenshot and answer as the candidate (first person).
Use the resume and job description context to make answers personal and specific.
Respond in clean markdown. For code problems: correct solution first with fenced code blocks, then O(n) complexity note.
Speak with the confidence of someone who has solved this problem before.
"""]
        ]

        for turn in history.suffix(4) {
            messages.append(["role": "user",      "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }

        var prompt = """
        Analyze this screenshot carefully.

        If it contains a **coding problem or algorithm question**:
        - Provide a complete, correct solution
        - Use proper markdown code blocks with the language tag (e.g. ```python)
        - Add brief inline comments for clarity
        - Then give a short time/space complexity note

        If it contains a **system design or conceptual question**:
        - Give a structured markdown answer with headings and bullets

        If it contains a **multiple choice or quiz question**:
        - State the correct answer clearly, then explain why

        Otherwise describe what you see and how to answer it.
        """
        if !jd.isEmpty     { prompt += "\n\nJob Description context:\n\(jd)" }
        if !resume.isEmpty { prompt += "\n\nCandidate Resume:\n\(resume)" }

        messages.append([
            "role": "user",
            "content": [
                ["type": "image_url",
                 "image_url": ["url": "data:image/jpeg;base64,\(base64)", "detail": "high"]],
                ["type": "text", "text": prompt]
            ]
        ])

        return streamMessages(messages)
    }

    // MARK: - Shared streaming core
    private func streamMessages(_ messages: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let body: [String: Any] = [
                        "model":  self.model,
                        "stream": true,
                        "messages": messages,
                    ]

                    var request = URLRequest(url: URL(string: "\(self.baseURL)/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await URLSession.shared.bytes(for: request)

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                        let json = String(line.dropFirst(6))
                        if let data = json.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = obj["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func systemPrompt(jd: String, resume: String) -> String {
        var s = """
You are ShadowPilot, an invisible interview co-pilot acting as a Principal Engineer with 15+ years of experience based in the United States.

ALWAYS answer as if YOU are the candidate — first person, confident, authoritative.
Use natural American English — contractions (I've, we'd, that's), American idioms, and a casual-professional tone like a senior engineer at a top US tech company.
Avoid British spellings or overly formal phrasing. Sound like a native American speaker.

Draw directly from the resume and job description provided. If resume mentions specific technologies, projects, or achievements, weave them naturally into answers.

Answer style:
- Think and respond like a Principal Engineer: system-level thinking, trade-offs, impact at scale
- Lead with the most impressive/relevant point first
- Use concise markdown bullets — readable at a glance during a live call
- For technical questions: give the correct answer first, then brief explanation
- For behavioral (STAR): Situation (1 line) → Action (2-3 lines) → Result (metric if possible)
- Never say "I think" or "maybe" — speak with conviction
- Keep total response under 150 words unless it's a coding question
"""
        if !jd.isEmpty     { s += "\n\nJob Description:\n\(jd)" }
        if !resume.isEmpty { s += "\n\nResume:\n\(resume)" }
        return s
    }
}

