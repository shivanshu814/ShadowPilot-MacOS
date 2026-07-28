import Foundation

// Cursor Cloud Agents — the slow, thorough half of repo mode.
//
// An agent is launched against the GitHub repo, reads the whole codebase in
// Cursor's cloud, and returns a written report. It runs for minutes and has no
// streaming endpoint, so it is NOT a live-answer path: run it before the
// interview, and its findings are kept as context for the instant local answers.
//
// API: https://api.cursor.com/v1 — POST /agents starts a run,
// GET /agents/{id}/runs/{runId} polls it, `result` carries the agent's output.

struct CursorRun: Sendable {
    let agentId: String
    let runId: String
}

enum CursorRunState: Sendable {
    case pending(String)       // CREATING / RUNNING — raw status for the UI
    case finished(String)      // the agent's report
    case failed(String)
}

enum CursorAgentError: LocalizedError {
    case noKey
    case noRepo
    case http(Int, String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No Cursor key — add CURSOR_API_KEY to ~/.wabusiness.env (cursor.com → Integrations → API Keys)."
        case .noRepo:
            return "Cloud review needs a GitHub URL. Load the repo with /repo github.com/owner/name, or make sure the local folder has an origin remote."
        case .http(let code, let body):
            if code == 401 || code == 403 { return "Cursor rejected the key (HTTP \(code)). Check CURSOR_API_KEY." }
            if code == 404 || body.contains("default branch") || body.contains("repository") {
                return """
                Cursor can't read that repository (HTTP \(code)).

                Cloud review runs inside Cursor, so Cursor's own GitHub connection needs access to the repo — your GITHUB_TOKEN is not used for this.

                Fix it at cursor.com → Dashboard → Integrations → GitHub, install the Cursor app on the account or org that owns the repo, and grant it access to that repo. Private repos are not visible until you do.
                """
            }
            return "Cursor API error \(code): \(body.prefix(300))"
        case .malformed(let what):
            return "Unexpected Cursor API response: \(what)"
        }
    }
}

struct CursorAgentService {
    private static let base = "https://api.cursor.com/v1"

    private var key: String { EnvConfig.cursorKey }
    var isConfigured: Bool { !key.isEmpty }

    // MARK: - Key check

    // GET /v1/me — cheap validation so Setup can show a real status.
    func validate() async throws -> String {
        let json = try await send("GET", "/me", body: nil)
        let name = json["apiKeyName"] as? String
        let email = json["userEmail"] as? String
        return [name, email].compactMap { $0 }.first ?? "key ok"
    }

    // MARK: - Launch

    func startReview(repoURL: String, ref: String?, prompt: String, name: String) async throws -> CursorRun {
        var repo: [String: Any] = ["url": repoURL]
        if let ref, !ref.isEmpty { repo["startingRef"] = ref }

        // No "model" field — Cursor picks its own default, so a renamed or retired
        // model id can never break the request.
        let body: [String: Any] = [
            "prompt": ["text": prompt],
            "repos": [repo],
            "name": name,
            "autoCreatePR": false,           // review only — never open a PR
        ]

        let json = try await send("POST", "/agents", body: body)
        // Response: { agent: { id, status }, run: { id, status } }
        guard let agent = json["agent"] as? [String: Any], let agentId = agent["id"] as? String else {
            throw CursorAgentError.malformed("missing agent.id")
        }
        guard let run = json["run"] as? [String: Any], let runId = run["id"] as? String else {
            throw CursorAgentError.malformed("missing run.id")
        }
        return CursorRun(agentId: agentId, runId: runId)
    }

    // MARK: - Poll

    func state(of run: CursorRun) async throws -> CursorRunState {
        let json = try await send("GET", "/agents/\(run.agentId)/runs/\(run.runId)", body: nil)
        let status = (json["status"] as? String ?? "UNKNOWN").uppercased()
        switch status {
        case "FINISHED":
            let result = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return result.isEmpty
                ? .failed("The agent finished without writing a report.")
                : .finished(result)
        case "ERROR", "CANCELLED", "EXPIRED":
            let detail = json["error"] as? String ?? json["result"] as? String ?? ""
            return .failed("Cursor agent \(status.lowercased())\(detail.isEmpty ? "" : ": \(detail)")")
        default:
            return .pending(status)
        }
    }

    // MARK: - Transport

    private func send(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard !key.isEmpty else { throw CursorAgentError.noKey }
        guard let url = URL(string: Self.base + path) else { throw CursorAgentError.malformed("bad path \(path)") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CursorAgentError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorAgentError.malformed("body was not a JSON object")
        }
        return json
    }

    // MARK: - Prompt

    // Read-only brief: the agent must report, never patch. Findings feed the
    // local index's answers, so file paths and line numbers matter.
    static func reviewPrompt(focus: String) -> String {
        let scope = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = """
        Review this repository for an engineer who has to discuss and defend it in a technical interview.

        HARD CONSTRAINTS:
        - Do NOT modify, create or delete any file. Do NOT commit, branch, or open a pull request.
        - Do NOT write implementation code. Describe changes in words; a 1-3 line snippet is the maximum, only when words alone are unclear.
        - Every claim must point at a real path and line range, e.g. `internal/auth/token.go:L88-L104`. Never invent one.

        Read broadly across the codebase first, then write a report in exactly these sections:

        ## Architecture
        How the system fits together — the main modules, and how one real request or job flows through them end to end. Name the actual files it passes through.

        ## Defects
        Concrete bugs, ordered most severe first. For each: the `path:Lx-Ly`, what goes wrong and the input or interleaving that triggers it, then one sentence on what the fix would be. Logic errors, nil/bounds crashes, races and unsynchronised shared state, leaks, unhandled errors, auth and injection holes, N+1 queries. No style opinions, no "add tests" filler.

        ## Weak spots
        The parts a reviewer would push on — tight coupling, missing tests, performance traps, anything fragile. One line each, with the file.

        ## Talking points
        6-8 single-sentence things worth saying out loud about this codebase: decisions that look deliberate, tradeoffs made, what you would change first and why.
        """
        if !scope.isEmpty {
            p += "\n\nWeight the whole review toward this in particular: \(scope)"
        }
        return p
    }
}
