import Foundation

/// Локальная база приложения. Данные конвейера и действия пользователя хранятся рядом,
/// но синхронизация никогда не затирает избранное, архив, заметки и удаления.
public final class LeadStore {
    public private(set) var db: SQLiteDB
    public var path: String { db.path }

    static let schema = """
    CREATE TABLE IF NOT EXISTS leads (
        lead_id TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL,
        source TEXT NOT NULL,
        title TEXT NOT NULL,
        score REAL NOT NULL DEFAULT 0,
        relevance TEXT NOT NULL DEFAULT 'rejected',
        discovered_at TEXT NOT NULL,
        updated_at TEXT,
        data_json TEXT NOT NULL,
        imported_at TEXT NOT NULL,
        favorite INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        excluded INTEGER NOT NULL DEFAULT 0,
        seen INTEGER NOT NULL DEFAULT 0,
        note TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS ix_leads_discovered ON leads(discovered_at);
    CREATE TABLE IF NOT EXISTS source_state (
        source TEXT PRIMARY KEY,
        last_success_at TEXT,
        last_attempt_at TEXT,
        consecutive_failures INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'ok',
        last_error TEXT
    );
    CREATE TABLE IF NOT EXISTS pipeline_errors (
        id INTEGER PRIMARY KEY,
        at TEXT,
        module TEXT NOT NULL,
        message TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS exclusions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        value TEXT NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(kind, value)
    );
    CREATE TABLE IF NOT EXISTS lead_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        lead_id TEXT NOT NULL,
        at TEXT NOT NULL,
        action TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ix_events_lead ON lead_events(lead_id);
    CREATE TABLE IF NOT EXISTS sync_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at TEXT NOT NULL,
        ok INTEGER NOT NULL,
        added INTEGER NOT NULL DEFAULT 0,
        updated INTEGER NOT NULL DEFAULT 0,
        message TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """

    public init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        db = try SQLiteDB(path: path)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec(Self.schema)
        try db.run("INSERT OR IGNORE INTO kv(key, value) VALUES('schema_version', '1')")
    }

    // MARK: - Импорт состояния конвейера

    /// Импортирует расшифрованную базу конвейера (SQLite из GitHub Actions).
    @discardableResult
    public func importPipelineDatabase(at remotePath: String) throws -> ImportResult {
        let remote = try SQLiteDB(path: remotePath, readOnly: true)
        defer { remote.close() }
        guard try remote.tableExists("leads") else {
            throw SQLiteError(message: "в файле состояния нет таблицы leads")
        }
        let rows = try remote.query("""
            SELECT lead_id, fingerprint, kind, source, data_json, score, relevance, discovered_at, updated_at
            FROM leads
            """)
        var externals: [String: [ExternalResult]] = [:]
        if try remote.tableExists("external_results") {
            for r in try remote.query("SELECT lead_id, service, processed_at, ok, score, label, error FROM external_results ORDER BY id") {
                guard let id = r["lead_id"]?.string else { continue }
                externals[id, default: []].append(ExternalResult(
                    service: r["service"]?.string ?? "", processedAt: ISODate.parse(r["processed_at"]?.string),
                    ok: r["ok"]?.bool ?? false, score: r["score"]?.double, label: r["label"]?.string,
                    error: r["error"]?.string))
            }
        }
        let sources = try remote.tableExists("source_state")
            ? try remote.query("SELECT source, last_success_at, last_attempt_at, consecutive_failures, status, last_error FROM source_state")
            : []
        let errors = try remote.tableExists("errors")
            ? try remote.query("SELECT id, at, module, message FROM errors ORDER BY id DESC LIMIT 300")
            : []

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let now = ISODate.now()
        var added = 0, updated = 0

        try db.transaction {
            for r in rows {
                guard let id = r["lead_id"]?.string, let json = r["data_json"]?.string,
                      var data = try? decoder.decode(LeadData.self, from: Data(json.utf8)) else { continue }
                if let ext = externals[id], !ext.isEmpty {
                    // Внешние результаты в отдельной таблице — источник истины.
                    data.externalResults = ext
                }
                let dataJSON = String(data: try encoder.encode(data), encoding: .utf8) ?? json
                let discovered = r["discovered_at"]?.string ?? ISODate.format(data.discoveredAt) ?? now
                let exists = try !db.query("SELECT 1 FROM leads WHERE lead_id=?", [.text(id)]).isEmpty
                if exists {
                    updated += try db.run("""
                        UPDATE leads SET fingerprint=?, kind=?, source=?, title=?, score=?, relevance=?,
                            updated_at=?, data_json=?
                        WHERE lead_id=? AND (updated_at IS NOT ?  OR data_json <> ?)
                        """, [.of(r["fingerprint"]?.string ?? ""), .text(data.kind.rawValue), .text(data.source),
                              .text(data.title), .double(data.score), .text(data.relevance.rawValue),
                              .of(r["updated_at"]?.string), .text(dataJSON), .text(id),
                              .of(r["updated_at"]?.string), .text(dataJSON)])
                } else {
                    try db.run("""
                        INSERT INTO leads(lead_id, fingerprint, kind, source, title, score, relevance,
                            discovered_at, updated_at, data_json, imported_at)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """, [.text(id), .of(r["fingerprint"]?.string ?? ""), .text(data.kind.rawValue),
                              .text(data.source), .text(data.title), .double(data.score),
                              .text(data.relevance.rawValue), .text(discovered), .of(r["updated_at"]?.string),
                              .text(dataJSON), .text(now)])
                    try logEvent(id, "Получен из поиска (\(SourceCatalog.title(data.source)))")
                    added += 1
                }
            }
            for s in sources {
                guard let name = s["source"]?.string else { continue }
                try db.run("""
                    INSERT INTO source_state(source, last_success_at, last_attempt_at, consecutive_failures, status, last_error)
                    VALUES(?,?,?,?,?,?)
                    ON CONFLICT(source) DO UPDATE SET last_success_at=excluded.last_success_at,
                        last_attempt_at=excluded.last_attempt_at, consecutive_failures=excluded.consecutive_failures,
                        status=excluded.status, last_error=excluded.last_error
                    """, [.text(name), .of(s["last_success_at"]?.string), .of(s["last_attempt_at"]?.string),
                          .int(s["consecutive_failures"]?.int ?? 0), .text(s["status"]?.string ?? "ok"),
                          .of(s["last_error"]?.string)])
            }
            if !errors.isEmpty {
                try db.run("DELETE FROM pipeline_errors")
                for e in errors {
                    try db.run("INSERT INTO pipeline_errors(id, at, module, message) VALUES(?,?,?,?)",
                               [.int(e["id"]?.int ?? 0), .of(e["at"]?.string),
                                .text(e["module"]?.string ?? ""), .text(e["message"]?.string ?? "")])
                }
            }
        }
        try applyExclusions()
        return ImportResult(added: added, updated: updated, sources: sources.count)
    }

    // MARK: - Чтение

    public func allLeads(includeDeleted: Bool = false) throws -> [LeadItem] {
        let decoder = JSONDecoder()
        let rows = try db.query("""
            SELECT lead_id, data_json, discovered_at, favorite, archived, excluded, seen, note
            FROM leads \(includeDeleted ? "" : "WHERE deleted=0") ORDER BY discovered_at DESC
            """)
        return rows.compactMap { r in
            guard let id = r["lead_id"]?.string, let json = r["data_json"]?.string,
                  let data = try? decoder.decode(LeadData.self, from: Data(json.utf8)) else { return nil }
            return LeadItem(id: id, data: data,
                            discoveredAt: ISODate.parse(r["discovered_at"]?.string) ?? data.discoveredAt ?? Date(),
                            favorite: r["favorite"]?.bool ?? false, archived: r["archived"]?.bool ?? false,
                            excluded: r["excluded"]?.bool ?? false, seen: r["seen"]?.bool ?? false,
                            note: r["note"]?.string ?? "")
        }
    }

    public func sourceStates() throws -> [SourceState] {
        try db.query("SELECT * FROM source_state ORDER BY source").map { r in
            SourceState(source: r["source"]?.string ?? "", lastSuccessAt: ISODate.parse(r["last_success_at"]?.string),
                        lastAttemptAt: ISODate.parse(r["last_attempt_at"]?.string),
                        consecutiveFailures: Int(r["consecutive_failures"]?.int ?? 0),
                        status: r["status"]?.string ?? "ok", lastError: r["last_error"]?.string)
        }
    }

    public func pipelineErrors(limit: Int = 100) throws -> [PipelineError] {
        try db.query("SELECT id, at, module, message FROM pipeline_errors ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).map {
            PipelineError(id: $0["id"]?.int ?? 0, at: ISODate.parse($0["at"]?.string),
                          module: $0["module"]?.string ?? "", message: $0["message"]?.string ?? "")
        }
    }

    public func events(for leadId: String) throws -> [LeadEvent] {
        try db.query("SELECT id, at, action FROM lead_events WHERE lead_id=? ORDER BY id DESC LIMIT 100", [.text(leadId)]).map {
            LeadEvent(id: $0["id"]?.int ?? 0, at: ISODate.parse($0["at"]?.string), action: $0["action"]?.string ?? "")
        }
    }

    public func syncLog(limit: Int = 50) throws -> [SyncLogEntry] {
        try db.query("SELECT * FROM sync_log ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).map {
            SyncLogEntry(id: $0["id"]?.int ?? 0, at: ISODate.parse($0["at"]?.string), ok: $0["ok"]?.bool ?? false,
                         added: Int($0["added"]?.int ?? 0), updated: Int($0["updated"]?.int ?? 0),
                         message: $0["message"]?.string ?? "")
        }
    }

    public func exclusions() throws -> [Exclusion] {
        try db.query("SELECT * FROM exclusions ORDER BY id DESC").compactMap { r in
            guard let kind = ExclusionKind(rawValue: r["kind"]?.string ?? "") else { return nil }
            return Exclusion(id: r["id"]?.int ?? 0, kind: kind, value: r["value"]?.string ?? "",
                             createdAt: ISODate.parse(r["created_at"]?.string))
        }
    }

    public func value(_ key: String) -> String? { try? db.scalar("SELECT value FROM kv WHERE key=?", [.text(key)]).string }

    public func setValue(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO kv(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }

    // MARK: - Действия пользователя

    private func update(_ ids: [String], _ sql: String, _ args: [SQLValue], event: String?) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try db.run(sql, args + [.text(id)])
                if let event { try logEvent(id, event) }
            }
        }
    }

    public func setFavorite(_ ids: [String], _ on: Bool) throws {
        try update(ids, "UPDATE leads SET favorite=? WHERE lead_id=?", [.of(on)],
                   event: on ? "Добавлен в избранное" : "Убран из избранного")
    }

    public func setArchived(_ ids: [String], _ on: Bool) throws {
        try update(ids, "UPDATE leads SET archived=? WHERE lead_id=?", [.of(on)],
                   event: on ? "Перенесён в архив" : "Возвращён из архива")
    }

    /// Удалённые лиды остаются в базе скрытыми, чтобы следующая синхронизация не вернула их.
    public func delete(_ ids: [String]) throws {
        try update(ids, "UPDATE leads SET deleted=1 WHERE lead_id=?", [], event: "Удалён")
    }

    public func markSeen(_ ids: [String]) throws {
        try update(ids, "UPDATE leads SET seen=1 WHERE lead_id=? AND seen=0", [], event: nil)
    }

    public func markAllSeen() throws { try db.run("UPDATE leads SET seen=1 WHERE seen=0") }

    public func setNote(_ id: String, _ note: String) throws {
        try db.run("UPDATE leads SET note=? WHERE lead_id=?", [.text(note), .text(id)])
    }

    public func logEvent(_ id: String, _ action: String) throws {
        try db.run("INSERT INTO lead_events(lead_id, at, action) VALUES(?,?,?)", [.text(id), .text(ISODate.now()), .text(action)])
    }

    public func addSyncLog(ok: Bool, added: Int = 0, updated: Int = 0, message: String) throws {
        try db.run("INSERT INTO sync_log(at, ok, added, updated, message) VALUES(?,?,?,?,?)",
                   [.text(ISODate.now()), .of(ok), .int(Int64(added)), .int(Int64(updated)), .text(message)])
    }

    // MARK: - Исключения

    public func addExclusion(_ kind: ExclusionKind, _ raw: String) throws {
        let value = Normalize.value(raw, kind: kind)
        guard !value.isEmpty else { return }
        try db.run("INSERT OR IGNORE INTO exclusions(kind, value, created_at) VALUES(?,?,?)",
                   [.text(kind.rawValue), .text(value), .text(ISODate.now())])
        try applyExclusions()
    }

    public func removeExclusion(_ id: Int64) throws {
        try db.run("DELETE FROM exclusions WHERE id=?", [.int(id)])
        try applyExclusions()
    }

    /// Пересчитывает флаг «исключён» у всех лидов.
    public func applyExclusions() throws {
        let rules = try exclusions()
        let byKind = Dictionary(grouping: rules, by: \.kind).mapValues { Set($0.map(\.value)) }
        let leads = try allLeads(includeDeleted: true)
        try db.transaction {
            for lead in leads {
                let hit = Self.matches(lead.data, byKind)
                if hit != lead.excluded {
                    try db.run("UPDATE leads SET excluded=? WHERE lead_id=?", [.of(hit), .text(lead.id)])
                }
            }
        }
    }

    static func matches(_ d: LeadData, _ rules: [ExclusionKind: Set<String>]) -> Bool {
        if let set = rules[.domain] {
            var domains: [String] = []
            if let dm = d.domain { domains.append(dm) }
            for e in d.emails { if let at = e.split(separator: "@").last { domains.append(Normalize.domain(String(at))) } }
            if domains.contains(where: { dom in set.contains(where: { dom == $0 || dom.hasSuffix("." + $0) }) }) { return true }
        }
        if let set = rules[.phone], d.phones.contains(where: { set.contains(Normalize.phone($0)) }) { return true }
        if let set = rules[.email], d.emails.contains(where: { set.contains(Normalize.email($0)) }) { return true }
        if let set = rules[.name] {
            let names = [d.title, d.customerName ?? ""].map(Normalize.name).filter { !$0.isEmpty }
            if names.contains(where: set.contains) { return true }
        }
        return false
    }

    // MARK: - Импорт своих баз (CSV) как исключений

    /// Импорт базы существующих клиентов: каждая ячейка с доменом, телефоном или email становится исключением.
    @discardableResult
    public func importExclusions(csv text: String) throws -> Int {
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            for cell in CSV.parseLine(String(line)) {
                let v = cell.trimmingCharacters(in: .whitespaces)
                guard !v.isEmpty else { continue }
                let kind: ExclusionKind?
                if v.contains("@") { kind = .email }
                else if v.filter(\.isNumber).count >= 10 && v.allSatisfy({ $0.isNumber || " +-()".contains($0) }) { kind = .phone }
                else if v.contains(".") && !v.contains(" ") { kind = .domain }
                else { kind = nil }
                if let kind {
                    count += try db.run("INSERT OR IGNORE INTO exclusions(kind, value, created_at) VALUES(?,?,?)",
                                        [.text(kind.rawValue), .text(Normalize.value(v, kind: kind)), .text(ISODate.now())])
                }
            }
        }
        try applyExclusions()
        return count
    }

    // MARK: - Резервные копии

    /// Консистентная копия базы через VACUUM INTO.
    public func backup(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try db.run("VACUUM INTO ?", [.text(url.path)])
    }

    /// Заменяет базу копией. Текущая база перед этим сохраняется рядом.
    public func restore(from url: URL) throws {
        let probe = try SQLiteDB(path: url.path, readOnly: true)
        let valid = try probe.tableExists("leads")
        probe.close()
        guard valid else { throw SQLiteError(message: "это не резервная копия Lead Generator") }
        let current = URL(fileURLWithPath: path)
        let safety = current.deletingLastPathComponent().appendingPathComponent("before-restore.db")
        try backup(to: safety)
        db.close()
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
        try fm.copyItem(at: url, to: current)
        db = try SQLiteDB(path: current.path)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec(Self.schema)
    }

    /// Переносит базу в другую папку.
    public func move(toDirectory dir: URL) throws -> String {
        let target = dir.appendingPathComponent("leads.db")
        guard target.path != path else { return path }
        try backup(to: target)
        let old = path
        db.close()
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: old + suffix) }
        db = try SQLiteDB(path: target.path)
        try db.exec("PRAGMA journal_mode=WAL")
        return target.path
    }

    public var fileSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
