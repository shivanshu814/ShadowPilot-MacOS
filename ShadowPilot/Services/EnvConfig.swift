import Foundation

struct EnvConfig {
    // Computed each time so no stale cache across rebuilds
    static var bedrockKey: String    { load("BEDROCK_API_KEY") }
    static var bedrockRegion: String { let r = load("BEDROCK_REGION"); return r.isEmpty ? "us-east-1" : r }
    static var openRouterKey: String { load("OPENROUTER_API_KEY") }
    static var openAIKey: String     { load("OPENAI_API_KEY") }

    private static func load(_ key: String) -> String {
        // 1. Process env (Xcode scheme)
        if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty { return val }

        let home   = FileManager.default.homeDirectoryForCurrentUser.path
        let bundle = Bundle.main.bundlePath
        let parent = (bundle as NSString).deletingLastPathComponent

        // Priority order — most reliable first
        let candidates = [
            home + "/.shadowpilot.env",              // ~/.shadowpilot.env  ← most reliable
            home + "/.env",
            parent + "/.env",                         // /Applications/.env
            bundle + "/Contents/Resources/.env",
            bundle + "/../../../.env",                // DerivedData project root
        ]

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
            return parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
