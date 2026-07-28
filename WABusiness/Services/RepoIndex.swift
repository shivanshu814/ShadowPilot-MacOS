import Foundation

// Local codebase index — points WA Business at a cloned repo so answers can cite
// real files and real line numbers instead of guessing.
//
// Everything is local and offline: a lexical BM25 index over line-windows. No
// embeddings, no upload of the whole repo — only the handful of retrieved
// windows travel to the model, which keeps latency interview-fast.

// MARK: - Indexed model

struct IndexedFile: Sendable {
    let path: String        // repo-relative, e.g. "internal/auth/token.go"
    let lines: [String]
    let symbols: [String]   // declared funcs/types — feeds the repo map
    let isSource: Bool      // source code vs config/docs
}

struct RepoChunk: Sendable {
    let fileIndex: Int
    let startLine: Int      // 1-based, inclusive
    let endLine: Int        // 1-based, inclusive
    let terms: [String: Int]
    let length: Int
    let pathTerms: Set<String>
    let isSource: Bool
}

struct RepoSnapshot: Sendable {
    let rootPath: String
    let rootName: String
    let files: [IndexedFile]
    let chunks: [RepoChunk]
    let df: [String: Int]           // document (chunk) frequency per term
    let avgChunkLength: Double
    let symbolIndex: Set<String>    // every declared symbol + file basename, lowercased
    let skippedCount: Int
}

enum RepoBuildOutcome: Sendable {
    case ok(RepoSnapshot)
    case failed(String)
}

// MARK: - Index

@MainActor
final class RepoIndex: ObservableObject {
    static let shared = RepoIndex()

    @Published private(set) var isIndexing = false
    @Published private(set) var progress = ""
    @Published private(set) var indexError: String?
    @Published private(set) var snapshot: RepoSnapshot?

    var isReady: Bool { snapshot != nil }
    var rootName: String { snapshot?.rootName ?? "" }
    var rootPath: String { snapshot?.rootPath ?? "" }
    var fileCount: Int { snapshot?.files.count ?? 0 }
    var chunkCount: Int { snapshot?.chunks.count ?? 0 }

    private init() {}

    // MARK: Build

    func load(path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue else {
            indexError = "Folder not found: \(trimmed)"
            snapshot = nil
            return
        }

        isIndexing = true
        indexError = nil
        progress = "Scanning \((trimmed as NSString).lastPathComponent)…"

        let built = await Task.detached(priority: .userInitiated) {
            RepoIndexBuilder.build(rootPath: trimmed)
        }.value

        isIndexing = false
        switch built {
        case .ok(let snap):
            snapshot = snap
            progress = "\(snap.files.count) files · \(snap.chunks.count) chunks"
        case .failed(let err):
            snapshot = nil
            progress = ""
            indexError = err
        }
    }

    func unload() {
        snapshot = nil
        progress = ""
        indexError = nil
    }

    // MARK: Retrieval

    // True when the question is plausibly about the loaded repo — either it uses
    // repo language, or it names something that actually exists in the index.
    func looksRepoScoped(_ question: String) -> Bool {
        guard let snap = snapshot else { return false }
        let lower = question.lowercased()

        let repoWords = ["this repo", "this code", "this codebase", "this project", "this file",
                         "the codebase", "the repo", "our code", "which file", "what file",
                         "where is", "where do", "where does", "walk me through", "find the bug",
                         "fix this", "fix the", "refactor", "what does this", "how does this",
                         "in the code", "code base"]
        if repoWords.contains(where: { lower.contains($0) }) { return true }

        // Names a real file or symbol → almost certainly about the repo
        let tokens = Set(RepoIndexBuilder.tokenize(question)).subtracting(RepoIndexBuilder.stopwords)
        for t in tokens where t.count >= 4 {
            if snap.symbolIndex.contains(t) { return true }
        }
        return false
    }

    // The context block injected ahead of the interviewer's question.
    func context(for question: String, snippetBudget: Int = 46_000, mapBudget: Int = 11_000) -> String {
        guard let snap = snapshot else { return "" }
        let hits = rank(question: question, in: snap, limit: 14)

        var out = "=== REPO: \(snap.rootName) (\(snap.files.count) files indexed) ===\n"
        out += "\n=== REPO MAP — files and what each declares ===\n"
        out += repoMap(snap, focus: hits.map { snap.files[$0.fileIndex].path }, budget: mapBudget)

        if hits.isEmpty {
            out += "\n=== RELEVANT CODE ===\n(no strong match — pick the likely file from the map above and say which file you'd open.)\n"
            return out
        }

        out += """

        === RELEVANT CODE — these are the REAL line numbers in the files. \
        Cite them exactly. The "NNN |" gutter is display only: never copy it into a diff. ===

        """
        var used = 0
        for hit in hits {
            let file = snap.files[hit.fileIndex]
            let block = render(file: file, from: hit.startLine, to: hit.endLine)
            if used + block.count > snippetBudget { break }
            used += block.count
            out += block
        }
        return out
    }

    // Merged, de-duplicated top windows.
    private struct Hit {
        let fileIndex: Int
        var startLine: Int
        var endLine: Int
        var score: Double
    }

    private func rank(question: String, in snap: RepoSnapshot, limit: Int) -> [Hit] {
        let qTerms = Array(Set(RepoIndexBuilder.tokenize(question))
            .subtracting(RepoIndexBuilder.stopwords)
            .filter { $0.count >= 2 })
        guard !qTerms.isEmpty, !snap.chunks.isEmpty else { return [] }

        let n = Double(snap.chunks.count)
        let k1 = 1.4, b = 0.72
        var idf: [String: Double] = [:]
        for t in qTerms {
            let dfc = Double(snap.df[t] ?? 0)
            idf[t] = log(1 + (n - dfc + 0.5) / (dfc + 0.5))
        }

        var scored: [(Int, Double)] = []
        scored.reserveCapacity(snap.chunks.count)
        for (i, chunk) in snap.chunks.enumerated() {
            var s = 0.0
            let lenNorm = k1 * (1 - b + b * Double(chunk.length) / max(snap.avgChunkLength, 1))
            for t in qTerms {
                guard let w = idf[t], w > 0 else { continue }
                if let f = chunk.terms[t] {
                    let tf = Double(f)
                    s += w * (tf * (k1 + 1)) / (tf + lenNorm)
                }
                // A term in the file path is a strong signal ("auth", "payments")
                if chunk.pathTerms.contains(t) { s += w * 2.2 }
            }
            // READMEs and configs restate the same words as the code they describe.
            // They're useful backup, never the thing to cite — hold them below source.
            if !chunk.isSource { s *= 0.5 }
            if s > 0 { scored.append((i, s)) }
        }
        guard !scored.isEmpty else { return [] }
        scored.sort { $0.1 > $1.1 }

        // Keep at most 3 windows per file so one big file can't crowd out the rest
        var perFile: [Int: Int] = [:]
        var hits: [Hit] = []
        for (idx, score) in scored {
            let c = snap.chunks[idx]
            let count = perFile[c.fileIndex] ?? 0
            if count >= 3 { continue }
            perFile[c.fileIndex] = count + 1
            hits.append(Hit(fileIndex: c.fileIndex, startLine: c.startLine, endLine: c.endLine, score: score))
            if hits.count >= limit * 2 { break }
        }

        // Merge overlapping/adjacent windows from the same file into one block
        hits.sort { $0.fileIndex == $1.fileIndex ? $0.startLine < $1.startLine : $0.fileIndex < $1.fileIndex }
        var merged: [Hit] = []
        for h in hits {
            if var last = merged.last, last.fileIndex == h.fileIndex, h.startLine <= last.endLine + 8 {
                last.endLine = max(last.endLine, h.endLine)
                last.score = max(last.score, h.score)
                merged[merged.count - 1] = last
            } else {
                merged.append(h)
            }
        }
        merged.sort { $0.score > $1.score }
        return Array(merged.prefix(limit))
    }

    private func render(file: IndexedFile, from: Int, to: Int) -> String {
        let start = max(1, from), end = min(file.lines.count, to)
        guard start <= end else { return "" }
        var s = "\n--- \(file.path)  L\(start)-L\(end) ---\n"
        for i in start...end {
            s += String(format: "%5d | %@\n", i, file.lines[i - 1])
        }
        return s
    }

    // Focused files listed first and in full; the rest compressed to fit the budget.
    private func repoMap(_ snap: RepoSnapshot, focus: [String], budget: Int) -> String {
        let focusSet = Set(focus)
        var lines: [String] = []
        var rest: [String] = []
        for f in snap.files {
            let syms = f.symbols.isEmpty ? "" : " — " + f.symbols.prefix(10).joined(separator: ", ")
            let entry = "\(f.path) (\(f.lines.count)L)\(syms)"
            if focusSet.contains(f.path) { lines.append(entry) } else { rest.append(entry) }
        }
        var out = ""
        for l in lines + rest {
            if out.count + l.count + 1 > budget {
                out += "… (\(snap.files.count - (out.components(separatedBy: "\n").count - 1)) more files not listed)\n"
                break
            }
            out += l + "\n"
        }
        return out
    }

    // MARK: Bug scan

    // Files worth a defect sweep, packed into model-sized batches.
    // Returns rendered, line-numbered batches ready to paste into a prompt.
    func reviewBatches(maxBatches: Int = 8, batchChars: Int = 26_000) -> [String] {
        guard let snap = snapshot else { return [] }

        // Real source only: skip tests, generated code, and trivially short files
        let candidates = snap.files.filter { f in
            guard f.isSource, f.lines.count >= 20 else { return false }
            let p = f.path.lowercased()
            let skip = ["test", "spec", "mock", "fixture", "generated", ".pb.", "migrations/"]
            return !skip.contains { p.contains($0) }
        }
        // Bug density lives in the substantial files — biggest first, huge ones last
        .sorted { a, b in
            let sa = a.lines.count > 1500 ? 0 : a.lines.count
            let sb = b.lines.count > 1500 ? 0 : b.lines.count
            return sa > sb
        }

        var batches: [String] = []
        var current = ""
        for f in candidates {
            var block = "\n--- \(f.path) ---\n"
            let cap = min(f.lines.count, 900)
            for i in 1...cap {
                block += String(format: "%5d | %@\n", i, f.lines[i - 1])
            }
            if cap < f.lines.count { block += "… (file continues past L\(cap))\n" }

            if block.count > batchChars {           // one oversized file gets its own batch
                if !current.isEmpty { batches.append(current); current = "" }
                batches.append(String(block.prefix(batchChars)))
            } else if current.count + block.count > batchChars {
                batches.append(current)
                current = block
            } else {
                current += block
            }
            if batches.count >= maxBatches { break }
        }
        if !current.isEmpty && batches.count < maxBatches { batches.append(current) }
        return Array(batches.prefix(maxBatches))
    }
}

// MARK: - Builder (off the main actor)

enum RepoIndexBuilder {

    static let stopwords: Set<String> = [
        "the","a","an","is","are","was","were","be","been","do","does","did","of","in","on","at","to",
        "for","with","and","or","but","if","then","this","that","these","those","it","its","as","by",
        "from","how","what","why","when","where","which","who","can","could","would","should","will",
        "we","you","i","me","my","our","your","here","there","about","into","so","not","no","yes",
        "code","file","files","line","lines","please","tell","show","explain","give"
    ]

    private static let skipDirs: Set<String> = [
        ".git", "node_modules", ".next", "dist", "build", "out", "vendor", "Pods", ".venv", "venv",
        "__pycache__", "target", ".build", "DerivedData", "coverage", ".idea", ".vscode", ".gradle",
        "bin", "obj", ".terraform", "Carthage", ".yarn", "bower_components", ".cache", ".turbo",
        "Godeps", "third_party", ".pytest_cache", ".mypy_cache", "site-packages",
    ]

    private static let sourceExts: Set<String> = [
        "swift","go","js","jsx","mjs","cjs","ts","tsx","py","rb","java","kt","kts","rs","c","h","cc",
        "cpp","hpp","cs","php","scala","m","mm","sh","bash","zsh","sql","proto","tf","vue","svelte",
        "dart","ex","exs","erl","lua","pl","r","gradle","groovy",
    ]
    private static let configExts: Set<String> = ["yaml","yml","toml","json","md","cfg","ini","env","conf"]

    private static let skipNames: Set<String> = [
        "package-lock.json","yarn.lock","pnpm-lock.yaml","go.sum","Cargo.lock","composer.lock",
        "Podfile.lock","poetry.lock","Gemfile.lock",
    ]

    private static let maxFiles = 3000
    private static let maxChunks = 24_000
    private static let maxFileBytes = 400_000
    private static let windowLines = 60
    private static let windowStride = 44

    static func build(rootPath: String) -> RepoBuildOutcome {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return .failed("Can't read \(rootPath)")
        }

        var files: [IndexedFile] = []
        var skipped = 0
        let prefixLen = root.path.hasSuffix("/") ? root.path.count : root.path.count + 1

        while let url = walker.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])

            if values?.isDirectory == true {
                if skipDirs.contains(name) { walker.skipDescendants() }
                continue
            }
            if files.count >= maxFiles { break }
            if skipNames.contains(name) { continue }

            let ext = url.pathExtension.lowercased()
            let isSource = sourceExts.contains(ext)
            guard isSource || configExts.contains(ext) else { continue }
            if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.contains(".pb.") { continue }
            if let size = values?.fileSize, size > maxFileBytes { skipped += 1; continue }

            guard let text = try? String(contentsOf: url, encoding: .utf8) else { skipped += 1; continue }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            guard !lines.isEmpty else { continue }

            // Minified / bundled output — huge average line length, worthless to cite
            let avgLen = text.count / max(lines.count, 1)
            if avgLen > 300 { skipped += 1; continue }

            let rel = url.path.count > prefixLen ? String(url.path.dropFirst(prefixLen)) : name
            files.append(IndexedFile(path: rel,
                                     lines: lines,
                                     symbols: isSource ? symbols(in: lines) : [],
                                     isSource: isSource))
        }

        guard !files.isEmpty else {
            return .failed("No source files found in \((rootPath as NSString).lastPathComponent)")
        }

        // Chunk into overlapping line-windows and accumulate document frequencies
        var chunks: [RepoChunk] = []
        var df: [String: Int] = [:]
        var totalLength = 0
        var symbolIndex = Set<String>()

        for (fi, file) in files.enumerated() {
            let pathTerms = Set(tokenize(file.path))
            symbolIndex.formUnion(pathTerms)
            for s in file.symbols { symbolIndex.formUnion(tokenize(s)) }

            var start = 0
            while start < file.lines.count {
                if chunks.count >= maxChunks { break }
                let end = min(start + windowLines, file.lines.count)
                var terms: [String: Int] = [:]
                var length = 0
                for i in start..<end {
                    for t in tokenize(file.lines[i]) where !t.isEmpty {
                        terms[t, default: 0] += 1
                        length += 1
                    }
                }
                if !terms.isEmpty {
                    for t in terms.keys { df[t, default: 0] += 1 }
                    totalLength += length
                    chunks.append(RepoChunk(fileIndex: fi,
                                            startLine: start + 1,
                                            endLine: end,
                                            terms: terms,
                                            length: length,
                                            pathTerms: pathTerms,
                                            isSource: file.isSource))
                }
                if end == file.lines.count { break }
                start += windowStride
            }
            if chunks.count >= maxChunks { break }
        }

        let snap = RepoSnapshot(
            rootPath: rootPath,
            rootName: (rootPath as NSString).lastPathComponent,
            files: files,
            chunks: chunks,
            df: df,
            avgChunkLength: chunks.isEmpty ? 1 : Double(totalLength) / Double(chunks.count),
            symbolIndex: symbolIndex,
            skippedCount: skipped
        )
        return .ok(snap)
    }

    // MARK: Tokenizer

    // Splits on non-alphanumerics, then splits camelCase/PascalCase so a question
    // about "validate token" still hits `validateAccessToken`.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                current.unicodeScalars.append(ch)
            } else if !current.isEmpty {
                emit(current, into: &out)
                current = ""
            }
        }
        if !current.isEmpty { emit(current, into: &out) }
        return out
    }

    private static func emit(_ word: String, into out: inout [String]) {
        guard word.count > 1, word.count < 40 else { return }
        let lower = word.lowercased()
        out.append(lower)
        // camelCase / PascalCase split — only when it actually has a hump
        var part = ""
        var parts: [String] = []
        for ch in word {
            if ch.isUppercase, !part.isEmpty {
                parts.append(part.lowercased())
                part = String(ch)
            } else {
                part.append(ch)
            }
        }
        if !part.isEmpty { parts.append(part.lowercased()) }
        if parts.count > 1 {
            out.append(contentsOf: parts.filter { $0.count > 1 })
        }
    }

    // MARK: Symbols

    private static let symbolRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*(?:export\s+|public\s+|private\s+|internal\s+|protected\s+|static\s+|final\s+|open\s+|async\s+|pub\s+)*"# +
                 #"(?:func|function|def|class|struct|interface|type|enum|protocol|extension|impl|fn|trait|module)\s+"# +
                 #"([A-Za-z_][A-Za-z0-9_]*)"#,
        options: [])

    private static func symbols(in lines: [String]) -> [String] {
        guard let re = symbolRegex else { return [] }
        var found: [String] = []
        var seen = Set<String>()
        for line in lines.prefix(1200) {
            guard line.count < 300 else { continue }
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1 else { continue }
            let name = ns.substring(with: m.range(at: 1))
            if seen.insert(name).inserted { found.append(name) }
            if found.count >= 14 { break }
        }
        return found
    }
}
