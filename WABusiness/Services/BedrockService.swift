import Foundation

// AWS Bedrock Converse API using long-lived API key (Authorization: Bearer).
// NOT OpenAI-compatible — has its own request shape and its own health probe.
// Non-streaming endpoint: yields the full answer as one chunk.
class BedrockService {
    let apiKey: String
    let region: String
    let modelId: String

    init(apiKey: String, region: String = "us-east-1",
         modelId: String = "us.meta.llama3-3-70b-instruct-v1:0") {
        self.apiKey = apiKey
        self.region = region
        self.modelId = modelId
    }

    // MARK: - Text (router-facing)
    func stream(system: String, userText: String, history: [ConversationTurn],
                maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages: [[String: Any]] = []
                    for turn in history {
                        messages.append(["role": "user",      "content": [["text": turn.question]]])
                        messages.append(["role": "assistant", "content": [["text": turn.answer]]])
                    }
                    messages.append(["role": "user", "content": [["text": userText]]])

                    let text = try await self.converse(system: system, messages: messages, maxTokens: maxTokens)
                    try Task.checkCancellation()
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Vision (router-facing)
    func streamVision(system: String, prompt: String, imageData: Data,
                      history: [ConversationTurn], maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages: [[String: Any]] = []
                    for turn in history {
                        messages.append(["role": "user",      "content": [["text": turn.question]]])
                        messages.append(["role": "assistant", "content": [["text": turn.answer]]])
                    }
                    let imageContent: [String: Any] = [
                        "image": [
                            "format": "jpeg",
                            "source": ["bytes": imageData.base64EncodedString()]
                        ]
                    ]
                    messages.append(["role": "user", "content": [imageContent, ["text": prompt]]])

                    let text = try await self.converse(system: system, messages: messages, maxTokens: maxTokens)
                    try Task.checkCancellation()
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Health probe (Bedrock-shaped, NOT the shared chat-completions probe)
    func probe() async throws {
        _ = try await converse(system: "reply ok",
                               messages: [["role": "user", "content": [["text": "hi"]]]],
                               maxTokens: 1,
                               timeout: 8)
    }

    // MARK: - Core Converse call
    private func converse(system: String, messages: [[String: Any]],
                          maxTokens: Int, timeout: TimeInterval = 60) async throws -> String {
        let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(modelId)/converse")!

        let body: [String: Any] = [
            "system": [["text": system]],
            "messages": messages,
            "inferenceConfig": ["maxTokens": maxTokens, "temperature": 0.7]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "BedrockService", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Bedrock error \(httpResponse.statusCode): \(errMsg.prefix(200))"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output  = json["output"]  as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let text    = content.first?["text"] as? String else {
            throw URLError(.cannotParseResponse)
        }

        if json["stopReason"] as? String == "max_tokens" { return text + kTruncationMarker }
        return text
    }
}
