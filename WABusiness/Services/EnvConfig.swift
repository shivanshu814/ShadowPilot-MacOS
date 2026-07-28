import Foundation

struct EnvConfig {
    // Computed each time so no stale cache across rebuilds
    static var bedrockKey: String    { load("BEDROCK_API_KEY") }
    static var bedrockRegion: String { let r = load("BEDROCK_REGION"); return r.isEmpty ? "us-east-1" : r }
    static var openRouterKey: String { load("OPENROUTER_API_KEY") }
    static var openAIKey: String     { load("OPENAI_API_KEY") }
    static var groqKey: String       { load("GROQ_API_KEY") }
    static var cloudflareAccountId: String { load("ACCOUNT_ID") }
    static var cloudflareToken: String     { load("API_TOKEN") }
    static var neonDatabaseURL: String     { load("NEON_DATABASE_URL") }

    // Personal access token for cloning private repos in repo mode.
    // GITHUB_TOKEN preferred; GIT_TOKEN accepted for non-GitHub hosts.
    static var gitToken: String {
        let t = load("GITHUB_TOKEN")
        return t.isEmpty ? load("GIT_TOKEN") : t
    }

    // Cursor Cloud Agents — whole-repo review in the cloud (/cloud command).
    // Not an LLM endpoint: it can't serve live answers, only written reports.
    // The agent runs on Cursor's own default model — nothing to configure.
    static var cursorKey: String { load("CURSOR_API_KEY") }

    // Optional model-id overrides so a renamed/failed model is fixable without recompiling
    static func modelOverride(_ key: String) -> String? {
        let v = load(key)
        return v.isEmpty ? nil : v
    }

    private static func load(_ key: String) -> String {
        // 1. Process env (Xcode scheme)
        if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty { return val }

        let home   = FileManager.default.homeDirectoryForCurrentUser.path
        let bundle = Bundle.main.bundlePath

        // Priority order — most reliable first
        var candidates = [
            home + "/.wabusiness.env",               // ~/.wabusiness.env  ← most reliable
            home + "/.shadowpilot.env",              // former name, kept for existing installs
            home + "/.env",
            bundle + "/Contents/Resources/.env",
        ]
        // Walk up from the app bundle (covers /Applications, DerivedData, and
        // local `build/Build/Products/Debug` — project root is several levels up)
        var dir = (bundle as NSString).deletingLastPathComponent
        for _ in 0..<8 {
            candidates.append(dir + "/.env")
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }

        for path in candidates {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let value = parse(contents, key: key), !value.isEmpty { return value }
        }
        return ""
    }

    private static func parse(_ contents: String, key: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.contains("=") else { continue }
            let parts = t.components(separatedBy: "=")
            guard parts.count >= 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes — supports KEY = "value" style lines
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}
