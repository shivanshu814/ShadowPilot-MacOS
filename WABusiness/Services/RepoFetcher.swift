import Foundation

// Cloud side of repo mode: takes a GitHub/GitLab URL, shallow-clones it into
// Application Support, and hands the local path to RepoIndex. Everything after
// the clone is identical to the local-folder path — one index, one answer flow.
@MainActor
final class RepoFetcher: ObservableObject {
    static let shared = RepoFetcher()

    @Published private(set) var isFetching = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?

    private init() {}

    private static let gitPath = "/usr/bin/git"

    // Where clones live: ~/Library/Application Support/WA Business/repos
    static var cloneRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("WA Business/repos", isDirectory: true)
    }

    // Clone (or fast-forward an existing clone) and return the local path.
    func fetch(_ input: String) async -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let target = RemoteRepo(input: raw) else {
            error = "Can't parse that repo URL. Try https://github.com/owner/repo or owner/repo."
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: Self.gitPath) else {
            error = "git not found — run `xcode-select --install` once, then retry."
            return nil
        }

        isFetching = true
        error = nil
        status = "Cloning \(target.slug)…"

        let dest = Self.cloneRoot.appendingPathComponent(target.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: Self.cloneRoot, withIntermediateDirectories: true)

        let token = EnvConfig.gitToken
        let destPath = dest.path
        let authURL = target.cloneURL(token: token)
        let cleanURL = target.cloneURL(token: "")
        let branch = target.branch
        let alreadyCloned = FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path)

        let outcome = await Task.detached(priority: .userInitiated) { () -> GitOutcome in
            if alreadyCloned {
                // Update in place — much faster than re-cloning between sessions
                let (c1, o1) = Git.run(["-C", destPath, "remote", "set-url", "origin", authURL])
                if c1 != 0 { return .failed(Git.redact(o1, token)) }
                let (c2, o2) = Git.run(["-C", destPath, "fetch", "--depth", "1", "origin",
                                        branch ?? "HEAD"])
                if c2 != 0 { return .failed(Git.redact(o2, token)) }
                let (c3, o3) = Git.run(["-C", destPath, "reset", "--hard", "FETCH_HEAD"])
                _ = Git.run(["-C", destPath, "remote", "set-url", "origin", cleanURL])
                if c3 != 0 { return .failed(Git.redact(o3, token)) }
                return .ok
            }

            try? FileManager.default.removeItem(atPath: destPath)
            var args = ["clone", "--depth", "1", "--single-branch"]
            if let branch { args += ["--branch", branch] }
            args += [authURL, destPath]
            let (code, out) = Git.run(args)
            guard code == 0 else {
                try? FileManager.default.removeItem(atPath: destPath)
                return .failed(Git.redact(out, token))
            }
            // Never leave the token sitting in .git/config
            _ = Git.run(["-C", destPath, "remote", "set-url", "origin", cleanURL])
            return .ok
        }.value

        isFetching = false
        switch outcome {
        case .ok:
            status = "Cloned \(target.slug)"
            return destPath
        case .failed(let message):
            status = ""
            error = Self.friendly(message, slug: target.slug, hasToken: !token.isEmpty)
            return nil
        }
    }

    private static func friendly(_ raw: String, slug: String, hasToken: Bool) -> String {
        let lower = raw.lowercased()
        if lower.contains("could not read username") || lower.contains("authentication failed")
            || lower.contains("terminal prompts disabled") {
            return hasToken
                ? "Auth failed for \(slug) — the GITHUB_TOKEN in .env can't read this repo."
                : "\(slug) looks private. Add GITHUB_TOKEN=<personal access token> to .env and retry."
        }
        if lower.contains("repository not found") || lower.contains("not found") {
            return "Repo not found: \(slug). Check the URL (or the token, if it's private)."
        }
        if lower.contains("could not resolve host") || lower.contains("network") {
            return "Network error reaching \(slug)."
        }
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        return firstLine.isEmpty ? "Clone failed for \(slug)." : "Clone failed: \(firstLine)"
    }
}

private enum GitOutcome: Sendable {
    case ok
    case failed(String)
}

// MARK: - "/repo …" typed straight into the bar

// Loading a codebase mid-session shouldn't mean a trip to Setup — typing a
// folder path or a repo URL into the overlay loads it right there.
enum RepoCommand {
    case local(String)        // existing directory on disk
    case remote(String)       // clone URL
    case invalid(String)      // explicitly asked for, but unusable

    private static let prefixes = ["/repo ", "repo: ", "repo:", "load repo ", "open repo ", "use repo "]

    static func parse(_ input: String) -> RepoCommand? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        var explicit = false
        let lowerInput = s.lowercased()
        if lowerInput == "/repo" { return .invalid("") }
        for p in prefixes where lowerInput.hasPrefix(p) {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            explicit = true
            break
        }

        // A folder dragged into the field arrives quoted or backslash-escaped
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "\\ ", with: " ").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return explicit ? .invalid("") : nil }

        let lower = s.lowercased()
        let remotePrefixes = ["git@", "https://", "http://", "ssh://", "git://",
                              "github.com/", "www.github.com/", "gitlab.com/", "bitbucket.org/"]
        if remotePrefixes.contains(where: { lower.hasPrefix($0) }) {
            // Store the normalised URL, never the raw line the user typed.
            guard let parsed = RemoteRepo(input: s) else { return .invalid(s) }
            return .remote(parsed.canonical)
        }

        let isPathish = s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("./")
        if isPathish {
            var path = s
            if path.hasPrefix("~") { path = NSHomeDirectory() + String(path.dropFirst()) }
            path = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return .local(path)
            }
            // A bare path that isn't a folder is never a spoken question
            return .invalid(s)
        }

        // "owner/repo" shorthand — only when the user explicitly said /repo, so a
        // spoken phrase like "map/reduce" never gets mistaken for a repository.
        if explicit {
            let parts = s.split(separator: "/")
            if parts.count == 2, !s.contains(" "), let parsed = RemoteRepo(input: s) {
                return .remote(parsed.canonical)
            }
            return .invalid(s)
        }
        return nil
    }
}

// MARK: - Remote URL parsing

struct RemoteRepo {
    let host: String       // github.com, gitlab.com, …
    let owner: String
    let name: String
    let branch: String?

    var slug: String { "\(owner)/\(name)" }
    // Normalised form worth storing and showing back, with any prose stripped.
    var canonical: String { "\(host)/\(owner)/\(name)" }
    var folderName: String { "\(host)-\(owner)-\(name)".replacingOccurrences(of: "/", with: "-") }

    func cloneURL(token: String) -> String {
        let credential = token.isEmpty ? "" : "x-access-token:\(token)@"
        return "https://\(credential)\(host)/\(owner)/\(name).git"
    }

    // Accepts: https://github.com/o/r[.git], https://github.com/o/r/tree/branch,
    // git@github.com:o/r.git, github.com/o/r, and the bare "o/r" shorthand.
    // Repo and owner names can only contain these. Anything else means we parsed
    // prose, not a URL, and must be rejected rather than cloned.
    private static let nameAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    init?(input: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the first whitespace-delimited token can be a URL. Trailing words
        // are prose ("github.com/me/app review this code") and must never end up
        // inside the repository name.
        if let space = s.rangeOfCharacter(from: .whitespacesAndNewlines) {
            s = String(s[s.startIndex..<space.lowerBound])
        }
        guard !s.isEmpty else { return nil }
        var host = "github.com"
        var branch: String?

        if s.hasPrefix("git@") {
            // git@github.com:owner/repo.git
            let body = String(s.dropFirst(4))
            guard let colon = body.firstIndex(of: ":") else { return nil }
            host = String(body[body.startIndex..<colon])
            s = String(body[body.index(after: colon)...])
        } else {
            for scheme in ["https://", "http://", "ssh://", "git://"] where s.hasPrefix(scheme) {
                s = String(s.dropFirst(scheme.count))
            }
            let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let first = parts.first, first.contains(".") {   // leading token is a hostname
                host = first
                s = parts.dropFirst().joined(separator: "/")
            }
        }

        var comps = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count >= 2 else { return nil }

        // .../tree/<branch>/... or .../blob/<branch>/... — keep the branch, drop the rest
        if comps.count >= 4, comps[2] == "tree" || comps[2] == "blob" {
            branch = comps[3]
        }
        comps = Array(comps.prefix(2))
        var repo = comps[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !comps[0].isEmpty, !repo.isEmpty else { return nil }
        guard comps[0].unicodeScalars.allSatisfy(Self.nameAllowed.contains),
              repo.unicodeScalars.allSatisfy(Self.nameAllowed.contains),
              host.unicodeScalars.allSatisfy(Self.nameAllowed.contains) else { return nil }

        self.host = host
        self.owner = comps[0]
        self.name = repo
        self.branch = branch
    }
}

// MARK: - GitHub REST

enum GitHubAPI {
    // Cursor rejects a launch when it can't work out the default branch itself,
    // so resolve it here and hand it over explicitly.
    static func defaultBranch(owner: String, name: String, token: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(name)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["default_branch"] as? String
    }
}

// MARK: - git process runner

enum Git {
    static func run(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"   // fail fast instead of hanging on a credential prompt
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        // Drain before waiting — a full pipe buffer would deadlock the child
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // A locally-opened folder still knows where it came from — that origin is what
    // the cloud agent needs, so /cloud works without re-typing the URL.
    static func originURL(path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path + "/.git") else { return nil }
        let (code, out) = run(["-C", path, "remote", "get-url", "origin"])
        guard code == 0 else { return nil }
        let url = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, let parsed = RemoteRepo(input: url) else { return nil }
        return parsed.cloneURL(token: "")
    }

    // git echoes the remote URL on failure — strip the token before it reaches the UI
    static func redact(_ text: String, _ token: String) -> String {
        guard !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "•••")
    }
}
