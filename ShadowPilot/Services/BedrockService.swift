import Foundation

// AWS Bedrock Converse API using x-amzn-api-key authentication
class BedrockService {
    private let apiKey: String
    private let region: String
    private let modelId: String

    init(apiKey: String, region: String = "us-east-1",
         modelId: String = "us.meta.llama3-3-70b-instruct-v1:0") {
        self.apiKey = apiKey
        self.region = region
        self.modelId = modelId
    }

    // MARK: - Audio transcript answer
    func stream(transcript: String, jd: String, resume: String,
                history: [ConversationTurn] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var messages: [[String: Any]] = []
                    for turn in history.suffix(6) {
                        messages.append(["role": "user",      "content": [["text": turn.question]]])
                        messages.append(["role": "assistant", "content": [["text": turn.answer]]])
                    }
                    messages.append(["role": "user", "content": [["text": "Interview question:\n\(transcript)"]]])

                    let text = try await self.converse(
                        system: self.systemPrompt(jd: jd, resume: resume),
                        messages: messages
                    )
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Screenshot / vision analysis
    func streamVision(imageData: Data, jd: String, resume: String,
                      history: [ConversationTurn] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var messages: [[String: Any]] = []
                    for turn in history.suffix(4) {
                        messages.append(["role": "user",      "content": [["text": turn.question]]])
                        messages.append(["role": "assistant", "content": [["text": turn.answer]]])
                    }

                    var prompt = """
                    Analyze this screenshot carefully.

                    If it contains a **coding problem or algorithm question**:
                    - Provide a complete, correct solution
                    - Use proper markdown code blocks with the language tag
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

                    let imageContent: [String: Any] = [
                        "image": [
                            "format": "jpeg",
                            "source": ["bytes": imageData.base64EncodedString()]
                        ]
                    ]
                    messages.append(["role": "user", "content": [imageContent, ["text": prompt]]])

                    let text = try await self.converse(
                        system: "You are ShadowPilot, a Principal Engineer with 15+ years of experience. Analyze the screenshot and answer as the candidate (first person). Respond in clean markdown.",
                        messages: messages
                    )
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Core Converse call
    private func converse(system: String, messages: [[String: Any]]) async throws -> String {
        let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(modelId)/converse")!

        let body: [String: Any] = [
            "system": [["text": system]],
            "messages": messages,
            "inferenceConfig": ["maxTokens": 1500, "temperature": 0.7]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-amzn-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "BedrockService", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Bedrock error \(httpResponse.statusCode): \(errMsg)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output  = json["output"]  as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let text    = content.first?["text"] as? String else {
            throw URLError(.cannotParseResponse)
        }

        return text
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
