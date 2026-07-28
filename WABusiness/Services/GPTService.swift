import Foundation

// Appended when a stream ends on finish_reason "length" — AppViewModel detects
// this and auto-continues the answer until it's complete.
let kTruncationMarker = "⟨…truncated⟩"

// Any OpenAI-compatible chat-completions endpoint: OpenAI, OpenRouter, Groq,
// Cloudflare Workers AI. System prompt, model, and max_tokens are supplied
// per call by ModelRouter.
class GPTService {
    let apiKey: String
    let baseURL: String
    let model: String

    init(apiKey: String, baseURL: String = "https://api.openai.com/v1", model: String = "gpt-4o") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    // MARK: - Text streaming
    func stream(system: String, userText: String, history: [ConversationTurn],
                maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in history {
            messages.append(["role": "user",      "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": userText])
        return streamMessages(messages, maxTokens: maxTokens)
    }

    // MARK: - Vision streaming
    func streamVision(system: String, prompt: String, imageData: Data,
                      history: [ConversationTurn], maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        let base64 = imageData.base64EncodedString()
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in history {
            messages.append(["role": "user",      "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append([
            "role": "user",
            "content": [
                ["type": "image_url",
                 "image_url": ["url": "data:image/jpeg;base64,\(base64)", "detail": "high"]],
                ["type": "text", "text": prompt]
            ]
        ])
        return streamMessages(messages, maxTokens: maxTokens)
    }

    // MARK: - Non-streaming health probe (max_tokens: 1)
    func probe() async throws {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8)?.prefix(120) ?? "unknown"
            throw NSError(domain: "GPTService", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(msg)"])
        }
    }

    // MARK: - Shared streaming core
    private func streamMessages(_ messages: [[String: Any]], maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model":  self.model,
                        "stream": true,
                        "max_tokens": maxTokens,
                        "messages": messages,
                    ]

                    var request = URLRequest(url: URL(string: "\(self.baseURL)/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line; if errBody.count > 300 { break } }
                        throw NSError(domain: "GPTService", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errBody.prefix(200))"])
                    }

                    var truncated = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                        let json = String(line.dropFirst(6))
                        guard let data = json.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let first = choices.first else { continue }
                        if let delta = first["delta"] as? [String: Any],
                           let text = delta["content"] as? String {
                            continuation.yield(text)
                        }
                        if first["finish_reason"] as? String == "length" { truncated = true }
                    }
                    // A mid-sentence cutoff must never be mistaken for a complete answer
                    if truncated { continuation.yield(kTruncationMarker) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
