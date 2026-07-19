import Foundation
import SQLite3

// Persistent session logging — separate layer from the in-memory LLM context history.
// Local SQLite is the source of truth; all app reads/writes go through here.
// Writes are fire-and-forget on a serial background queue: logging adds 0ms
// to transcription, silence-fire, or answer streaming.

struct SessionRow: Identifiable, Equatable {
    let id: String
    let startedAt: Date
    let title: String
    let entryCount: Int
}

struct EntryRow: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let ts: Date
    let question: String
    let answer: String
    let mode: String
    let model: String
}

final class SessionStore {
    static let shared = SessionStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "sp.sessionstore", qos: .utility)
    private var currentSessionId: String?

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        queue.sync { openAndMigrate() }
    }

    private func openAndMigrate() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShadowPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("sessions.sqlite").path

        guard sqlite3_open(path, &db) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY, started_at REAL NOT NULL, title TEXT NOT NULL DEFAULT '')
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS entries(
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, ts REAL NOT NULL,
            question TEXT NOT NULL, answer TEXT NOT NULL,
            mode TEXT NOT NULL, model TEXT NOT NULL, synced_at REAL)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS tombstones(
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, target_id TEXT NOT NULL)
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entries_session ON entries(session_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_entries_unsynced ON entries(synced_at) WHERE synced_at IS NULL")
    }

    // MARK: - Session lifecycle

    func beginSessionIfNeeded() {
        queue.async { [self] in
            guard currentSessionId == nil else { return }
            let id = UUID().uuidString
            currentSessionId = id
            run("INSERT INTO sessions(id, started_at, title) VALUES(?,?,?)",
                [.text(id), .real(Date().timeIntervalSince1970), .text(sessionTitle())])
        }
    }

    func endSession() {
        queue.async { [self] in currentSessionId = nil }
    }

    // MARK: - Logging (fire-and-forget)

    func append(question: String, answer: String, mode: String, model: String) {
        guard !question.isEmpty, !answer.isEmpty else { return }   // no noise entries
        queue.async { [self] in
            if currentSessionId == nil {
                let id = UUID().uuidString
                currentSessionId = id
                run("INSERT INTO sessions(id, started_at, title) VALUES(?,?,?)",
                    [.text(id), .real(Date().timeIntervalSince1970), .text(sessionTitle())])
            }
            guard let sid = currentSessionId else { return }
            // First real question names the session
            run("UPDATE sessions SET title=? WHERE id=? AND title=?",
                [.text(String(question.prefix(48))), .text(sid), .text(sessionTitle())])
            run("""
            INSERT INTO entries(id, session_id, ts, question, answer, mode, model, synced_at)
            VALUES(?,?,?,?,?,?,?,NULL)
            """, [.text(UUID().uuidString), .text(sid), .real(Date().timeIntervalSince1970),
                  .text(question), .text(answer), .text(mode), .text(model)])
        }
    }

    private func sessionTitle() -> String { "Session" }

    // MARK: - Reads (HistoryView)

    func fetchSessions() -> [SessionRow] {
        queue.sync {
            query("""
            SELECT s.id, s.started_at, s.title, COUNT(e.id)
            FROM sessions s LEFT JOIN entries e ON e.session_id = s.id
            GROUP BY s.id HAVING COUNT(e.id) > 0 ORDER BY s.started_at DESC
            """, []) { stmt in
                SessionRow(id: column(stmt, 0),
                           startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                           title: column(stmt, 2),
                           entryCount: Int(sqlite3_column_int(stmt, 3)))
            }
        }
    }

    func fetchEntries(sessionId: String) -> [EntryRow] {
        queue.sync {
            query("SELECT id, session_id, ts, question, answer, mode, model FROM entries WHERE session_id=? ORDER BY ts ASC",
                  [.text(sessionId)]) { entryRow($0) }
        }
    }

    func search(_ text: String) -> [EntryRow] {
        let like = "%\(text)%"
        return queue.sync {
            query("""
            SELECT id, session_id, ts, question, answer, mode, model FROM entries
            WHERE question LIKE ? OR answer LIKE ? ORDER BY ts DESC LIMIT 200
            """, [.text(like), .text(like)]) { entryRow($0) }
        }
    }

    // MARK: - Deletes (hard delete + tombstone so Neon rows never resurrect)

    func deleteEntry(_ id: String) {
        queue.async { [self] in
            run("INSERT OR REPLACE INTO tombstones(id, kind, target_id) VALUES(?,?,?)",
                [.text(UUID().uuidString), .text("entry"), .text(id)])
            run("DELETE FROM entries WHERE id=?", [.text(id)])
        }
    }

    func deleteSession(_ id: String) {
        queue.async { [self] in
            run("INSERT OR REPLACE INTO tombstones(id, kind, target_id) VALUES(?,?,?)",
                [.text(UUID().uuidString), .text("session"), .text(id)])
            run("DELETE FROM entries WHERE session_id=?", [.text(id)])
            run("DELETE FROM sessions WHERE id=?", [.text(id)])
            if currentSessionId == id { currentSessionId = nil }
        }
    }

    func deleteAll() {
        queue.async { [self] in
            let ids = query("SELECT id FROM sessions", []) { column($0, 0) }
            for id in ids {
                run("INSERT OR REPLACE INTO tombstones(id, kind, target_id) VALUES(?,?,?)",
                    [.text(UUID().uuidString), .text("session"), .text(id)])
            }
            run("DELETE FROM entries", [])
            run("DELETE FROM sessions", [])
            currentSessionId = nil
        }
    }

    // MARK: - Sync support (NeonSync)

    func unsyncedEntries(limit: Int = 50) -> [EntryRow] {
        queue.sync {
            query("SELECT id, session_id, ts, question, answer, mode, model FROM entries WHERE synced_at IS NULL ORDER BY ts ASC LIMIT ?",
                  [.int(limit)]) { entryRow($0) }
        }
    }

    func sessionsFor(ids: Set<String>) -> [SessionRow] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return queue.sync {
            query("SELECT id, started_at, title, 0 FROM sessions WHERE id IN (\(placeholders))",
                  ids.map { .text($0) }) { stmt in
                SessionRow(id: column(stmt, 0),
                           startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                           title: column(stmt, 2), entryCount: 0)
            }
        }
    }

    func markSynced(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        queue.async { [self] in
            var params: [Param] = [.real(Date().timeIntervalSince1970)]
            params.append(contentsOf: ids.map { .text($0) })
            run("UPDATE entries SET synced_at=? WHERE id IN (\(placeholders))", params)
        }
    }

    func pendingSyncCount() -> Int {
        queue.sync {
            query("SELECT COUNT(*) FROM entries WHERE synced_at IS NULL", []) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        }
    }

    func tombstones() -> [(id: String, kind: String, targetId: String)] {
        queue.sync {
            query("SELECT id, kind, target_id FROM tombstones", []) { (column($0, 0), column($0, 1), column($0, 2)) }
        }
    }

    func clearTombstones(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        queue.async { [self] in
            run("DELETE FROM tombstones WHERE id IN (\(placeholders))", ids.map { .text($0) })
        }
    }

    // MARK: - Export

    func exportMarkdown(sessionId: String) -> String {
        let entries = fetchEntries(sessionId: sessionId)
        let session = fetchSessions().first { $0.id == sessionId }
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
        var md = "# \(session?.title ?? "Session")\n\n_\(fmt.string(from: session?.startedAt ?? Date()))_\n\n"
        for e in entries {
            md += "## Q: \(e.question)\n\n_\(e.mode) · \(e.model) · \(fmt.string(from: e.ts))_\n\n\(e.answer)\n\n---\n\n"
        }
        return md
    }

    // MARK: - SQLite plumbing

    enum Param { case text(String), real(Double), int(Int) }

    private func entryRow(_ stmt: OpaquePointer?) -> EntryRow {
        EntryRow(id: column(stmt, 0), sessionId: column(stmt, 1),
                 ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                 question: column(stmt, 3), answer: column(stmt, 4),
                 mode: column(stmt, 5), model: column(stmt, 6))
    }

    private func column(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    private func run(_ sql: String, _ params: [Param]) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func query<T>(_ sql: String, _ params: [Param], map: (OpaquePointer?) -> T) -> [T] {
        guard db != nil else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(map(stmt)) }
        return rows
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [Param]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n):  sqlite3_bind_int64(stmt, idx, Int64(n))
            }
        }
    }
}
