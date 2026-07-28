import Foundation

// Background cloud backup of session logs to Neon Postgres (SQL-over-HTTP).
// Local SQLite stays the source of truth; this only pushes. Never runs while
// an answer stream is active. Network failure = silent retry next cycle.
@MainActor
final class NeonSync: ObservableObject {
    static let shared = NeonSync()

    @Published var pendingCount = 0
    @Published var lastStatus = "idle"
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "sp.cloudSyncEnabled") }
    }

    // Set by AppViewModel — sync never runs mid-answer-stream
    var isBusy: () -> Bool = { false }

    var isConfigured: Bool { !EnvConfig.neonDatabaseURL.isEmpty }

    private var timer: Timer?
    private var schemaEnsured = false
    private var syncing = false

    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "sp.deviceId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "sp.deviceId")
        return id
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: "sp.cloudSyncEnabled") as? Bool ?? true
    }

    func start() {
        refreshPendingCount()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
    }

    func refreshPendingCount() {
        let store = SessionStore.shared
        Task.detached {
            let count = store.pendingSyncCount()
            await MainActor.run { NeonSync.shared.pendingCount = count }
        }
    }

    func syncNow() async {
        guard enabled, isConfigured, !syncing, !isBusy() else { refreshPendingCount(); return }
        syncing = true
        defer { syncing = false; refreshPendingCount() }

        do {
            try await ensureSchema()

            // 1. Tombstones — deleted history must never resurrect
            let tombs = SessionStore.shared.tombstones()
            if !tombs.isEmpty {
                let entryIds   = tombs.filter { $0.kind == "entry" }.map { $0.targetId }
                let sessionIds = tombs.filter { $0.kind == "session" }.map { $0.targetId }
                if !entryIds.isEmpty {
                    try await sql("DELETE FROM sp_entries WHERE id = ANY($1)", [entryIds])
                }
                if !sessionIds.isEmpty {
                    try await sql("DELETE FROM sp_entries WHERE session_id = ANY($1)", [sessionIds])
                    try await sql("DELETE FROM sp_sessions WHERE id = ANY($1)", [sessionIds])
                }
                SessionStore.shared.clearTombstones(tombs.map { $0.id })
            }

            // 2. Push unsynced entries in batches
            while true {
                let batch = SessionStore.shared.unsyncedEntries(limit: 25)
                guard !batch.isEmpty else { break }

                let sessions = SessionStore.shared.sessionsFor(ids: Set(batch.map { $0.sessionId }))
                for s in sessions {
                    try await sql("""
                    INSERT INTO sp_sessions(id, started_at, title, device_id)
                    VALUES($1, to_timestamp($2::double precision), $3, $4)
                    ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title
                    """, [s.id, String(s.startedAt.timeIntervalSince1970), s.title, deviceId])
                }
                for e in batch {
                    try await sql("""
                    INSERT INTO sp_entries(id, session_id, ts, question, answer, mode, model, device_id)
                    VALUES($1, $2, to_timestamp($3::double precision), $4, $5, $6, $7, $8)
                    ON CONFLICT (id) DO NOTHING
                    """, [e.id, e.sessionId, String(e.ts.timeIntervalSince1970),
                          e.question, e.answer, e.mode, e.model, deviceId])
                }
                SessionStore.shared.markSynced(batch.map { $0.id })
                if isBusy() { break }   // an answer started streaming — stop immediately
            }
            lastStatus = "synced"
        } catch {
            // Invisible failure — retry next cycle
            lastStatus = "retrying"
        }
    }

    private func ensureSchema() async throws {
        guard !schemaEnsured else { return }
        try await sql("""
        CREATE TABLE IF NOT EXISTS sp_sessions(
            id TEXT PRIMARY KEY, started_at TIMESTAMPTZ, title TEXT, device_id TEXT)
        """, [])
        try await sql("""
        CREATE TABLE IF NOT EXISTS sp_entries(
            id TEXT PRIMARY KEY, session_id TEXT, ts TIMESTAMPTZ,
            question TEXT, answer TEXT, mode TEXT, model TEXT, device_id TEXT)
        """, [])
        schemaEnsured = true
    }

    // MARK: - Neon SQL-over-HTTP (serverless driver protocol)

    private func sql(_ query: String, _ params: [Any]) async throws {
        let connString = EnvConfig.neonDatabaseURL
        guard let host = URLComponents(string: connString)?.host,
              let url = URL(string: "https://\(host)/sql") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(connString, forHTTPHeaderField: "Neon-Connection-String")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "params": params])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8)?.prefix(150) ?? ""
            throw NSError(domain: "NeonSync", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Neon HTTP \(code): \(msg)"])
        }
    }
}
