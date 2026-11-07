import Foundation

/// Локальная база пользователя. Результаты поиска и действия пользователя хранятся рядом,
/// но поиск никогда не затирает избранное, архив, заметки и удаления.
/// Соединения SQLite открыты в режиме FULLMUTEX, поиск работает через своё соединение.
public final class LeadStore: @unchecked Sendable {
    public private(set) var db: SQLiteDB
    public var path: String { db.path }
    /// Ключ шифрования базы (SQLCipher). nil — база без шифрования (только тесты и старый код).
    public let key: DatabaseKey?
    public var isEncrypted: Bool { key != nil }
    /// Записывать изменения в журнал синхронизации (включено для облачных учётных записей).
    public internal(set) var syncTracking = false

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

    /// `key` — ключ шифрования. С ключом база хранится зашифрованной; если по этому пути лежит
    /// незашифрованная база прежней версии, она переписывается в зашифрованную без потери данных.
    public init(path: String, key: DatabaseKey? = nil) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        self.key = key
        db = try Self.openFile(path, key: key)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec(Self.schema)
        try db.run("INSERT OR IGNORE INTO kv(key, value) VALUES('schema_version', '1')")
        try migrate()
        syncTracking = value("sync.enabled") == "1"
    }

    /// Открывает файл базы: с ключом — через шифрование (и перевод старой базы), без ключа — как есть.
    static func openFile(_ path: String, key: DatabaseKey?) throws -> SQLiteDB {
        guard let key else { return try SQLiteDB(path: path) }
        return try EncryptedDatabase.open(path: path, key: key)
    }

    /// Включить журнал изменений для облака. Флаг хранится в самой базе, поэтому его видят
    /// все соединения (поиск работает через своё).
    public func enableSyncTracking() throws {
        try setValue("sync.enabled", "1")
        syncTracking = true
    }

    /// Миграции схемы старых баз (версия 1.0.x хранила результаты поиска из GitHub Actions).
    func migrate() throws {
        let cols = try db.query("PRAGMA table_info(source_state)").compactMap { $0["name"]?.string }
        if !cols.contains("cursor_json") { try db.exec("ALTER TABLE source_state ADD COLUMN cursor_json TEXT") }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS search_queries (
            qhash TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            label TEXT NOT NULL,
            last_run_at TEXT NOT NULL,
            results INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS seen_objects (
            source TEXT NOT NULL,
            object_id TEXT NOT NULL,
            checked_at TEXT NOT NULL,
            PRIMARY KEY (source, object_id)
        );
        CREATE INDEX IF NOT EXISTS ix_leads_fingerprint ON leads(fingerprint);
        """)
        try db.exec(Self.syncSchema)
        try db.run("INSERT INTO kv(key, value) VALUES('schema_version', '2') ON CONFLICT(key) DO UPDATE SET value='2'")
    }

    // MARK: - Результаты поиска

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]  // стабильный JSON: иначе каждый лид считался бы изменённым
        return e
    }()

    /// Сохраняет найденный лид. Избранное, архив, заметки и удаления пользователя не трогаются.
    @discardableResult
    public func save(_ lead: LeadData, id: String, fingerprint: String) throws -> SaveOutcome {
        var data = lead
        let now = ISODate.now()
        if let row = try db.query("SELECT discovered_at, data_json FROM leads WHERE lead_id=?", [.text(id)]).first {
            // Дата обнаружения — первая, а не последняя.
            let discovered = row["discovered_at"]?.string
            data.discoveredAt = ISODate.parse(discovered) ?? data.discoveredAt
            let json = String(data: try Self.encoder.encode(data), encoding: .utf8) ?? "{}"
            guard json != row["data_json"]?.string else { return .unchanged }
            try db.run("""
                UPDATE leads SET fingerprint=?, kind=?, source=?, title=?, score=?, relevance=?, updated_at=?, data_json=?
                WHERE lead_id=?
                """, [.text(fingerprint), .text(data.kind.rawValue), .text(data.source), .text(data.title),
                      .double(data.score), .text(data.relevance.rawValue), .text(now), .text(json), .text(id)])
            try markDirty("lead", id, ["data"])
            return .updated
        }
        if !fingerprint.isEmpty,
           try !db.query("SELECT 1 FROM leads WHERE fingerprint=? LIMIT 1", [.text(fingerprint)]).isEmpty {
            return .duplicate  // та же заявка или организация уже есть из другого места
        }
        let json = String(data: try Self.encoder.encode(data), encoding: .utf8) ?? "{}"
        try db.run("""
            INSERT INTO leads(lead_id, fingerprint, kind, source, title, score, relevance, discovered_at, updated_at, data_json, imported_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(id), .text(fingerprint), .text(data.kind.rawValue), .text(data.source), .text(data.title),
                  .double(data.score), .text(data.relevance.rawValue), .of(ISODate.format(data.discoveredAt) ?? now),
                  .text(now), .text(json), .text(now)])
        try logEvent(id, "Найден поиском (\(SourceCatalog.title(data.source)))")
        try markDirty("lead", id, ["data"])
        return .added
    }

    /// После поиска: применить исключения к новым лидам и запомнить время.
    public func searchFinished() throws {
        try applyExclusions()
        try setValue("last_search_at", ISODate.now())
    }

    public func sourceCursor(_ source: String) -> String? {
        try? db.scalar("SELECT cursor_json FROM source_state WHERE source=?", [.text(source)]).string
    }

    public func lastSuccess(_ source: String) -> Date? {
        ISODate.parse(try? db.scalar("SELECT last_success_at FROM source_state WHERE source=?", [.text(source)]).string)
    }

    public func markAttempt(_ source: String) {
        _ = try? db.run("""
            INSERT INTO source_state(source, last_attempt_at) VALUES(?,?)
            ON CONFLICT(source) DO UPDATE SET last_attempt_at=excluded.last_attempt_at
            """, [.text(source), .text(ISODate.now())])
    }

    public func finishSource(_ source: String, ok: Bool, partial: Bool, error: String?, cursor: String?) {
        let now = ISODate.now()
        if ok {
            _ = try? db.run("""
                UPDATE source_state SET last_success_at=?, consecutive_failures=0, status=?, last_error=?,
                    cursor_json=COALESCE(?, cursor_json)
                WHERE source=?
                """, [.text(now), .text(partial ? "partial" : "ok"), .of(error), .of(cursor), .text(source)])
        } else {
            _ = try? db.run("""
                UPDATE source_state SET consecutive_failures=consecutive_failures+1, status='error', last_error=?,
                    cursor_json=COALESCE(?, cursor_json)
                WHERE source=?
                """, [.of(error), .of(cursor), .text(source)])
        }
    }

    public func logError(module: String, message: String) {
        _ = try? db.run("INSERT INTO pipeline_errors(at, module, message) VALUES(?,?,?)",
                        [.text(ISODate.now()), .text(module), .text(message)])
        _ = try? db.run("DELETE FROM pipeline_errors WHERE id NOT IN (SELECT id FROM pipeline_errors ORDER BY id DESC LIMIT 500)")
    }

    public func logRun(ok: Bool, added: Int, updated: Int, message: String) {
        try? addSyncLog(ok: ok, added: added, updated: updated, message: message)
    }

    public func queryLastRun(_ hash: String) -> Date? {
        ISODate.parse(try? db.scalar("SELECT last_run_at FROM search_queries WHERE qhash=?", [.text(hash)]).string)
    }

    public func recordQuery(_ hash: String, source: String, label: String, results: Int) {
        _ = try? db.run("""
            INSERT INTO search_queries(qhash, source, label, last_run_at, results) VALUES(?,?,?,?,?)
            ON CONFLICT(qhash) DO UPDATE SET last_run_at=excluded.last_run_at, results=excluded.results
            """, [.text(hash), .text(source), .text(label), .text(ISODate.now()), .int(Int64(results))])
    }

    public func forgetQuery(_ hash: String) {
        _ = try? db.run("DELETE FROM search_queries WHERE qhash=?", [.text(hash)])
    }

    public func objectCheckedAt(source: String, objectId: String) -> Date? {
        ISODate.parse(try? db.scalar("SELECT checked_at FROM seen_objects WHERE source=? AND object_id=?",
                                     [.text(source), .text(objectId)]).string)
    }

    public func markObjectChecked(source: String, objectId: String) {
        _ = try? db.run("""
            INSERT INTO seen_objects(source, object_id, checked_at) VALUES(?,?,?)
            ON CONFLICT(source, object_id) DO UPDATE SET checked_at=excluded.checked_at
            """, [.text(source), .text(objectId), .text(ISODate.now())])
    }

    /// Сбросить память источника (курсоры, историю запросов): следующий поиск начнёт заново.
    public func resetSourceMemory(_ source: String) throws {
        try db.run("UPDATE source_state SET cursor_json=NULL WHERE source=?", [.text(source)])
        try db.run("DELETE FROM search_queries WHERE source=?", [.text(source)])
        try db.run("DELETE FROM seen_objects WHERE source=?", [.text(source)])
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

    private func update(_ ids: [String], _ sql: String, _ args: [SQLValue], event: String?, field: String) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                if try db.run(sql, args + [.text(id)]) > 0 { try markDirty("lead", id, [field]) }
                if let event { try logEvent(id, event) }
            }
        }
    }

    public func setFavorite(_ ids: [String], _ on: Bool) throws {
        try update(ids, "UPDATE leads SET favorite=? WHERE lead_id=?", [.of(on)],
                   event: on ? "Добавлен в избранное" : "Убран из избранного", field: "favorite")
    }

    public func setArchived(_ ids: [String], _ on: Bool) throws {
        try update(ids, "UPDATE leads SET archived=? WHERE lead_id=?", [.of(on)],
                   event: on ? "Перенесён в архив" : "Возвращён из архива", field: "archived")
    }

    /// Удалённые лиды остаются в базе скрытыми, чтобы следующий поиск не вернул их.
    public func delete(_ ids: [String]) throws {
        try update(ids, "UPDATE leads SET deleted=1 WHERE lead_id=?", [], event: "Удалён", field: "deleted")
    }

    public func markSeen(_ ids: [String]) throws {
        try update(ids, "UPDATE leads SET seen=1 WHERE lead_id=? AND seen=0", [], event: nil, field: "seen")
    }

    public func markAllSeen() throws {
        let ids = try db.query("SELECT lead_id FROM leads WHERE seen=0").compactMap { $0["lead_id"]?.string }
        try update(ids, "UPDATE leads SET seen=1 WHERE lead_id=? AND seen=0", [], event: nil, field: "seen")
    }

    public func setNote(_ id: String, _ note: String) throws {
        try db.transaction {
            if try db.run("UPDATE leads SET note=? WHERE lead_id=? AND note<>?", [.text(note), .text(id), .text(note)]) > 0 {
                try markDirty("lead", id, ["note"])
            }
        }
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
        if try db.run("INSERT OR IGNORE INTO exclusions(kind, value, created_at) VALUES(?,?,?)",
                      [.text(kind.rawValue), .text(value), .text(ISODate.now())]) > 0 {
            try markDirty("exclusion", "\(kind.rawValue)|\(value)", ["deleted"])
        }
        try applyExclusions()
    }

    public func removeExclusion(_ id: Int64) throws {
        if let r = try db.query("SELECT kind, value FROM exclusions WHERE id=?", [.int(id)]).first,
           let k = r["kind"]?.string, let v = r["value"]?.string {
            try markDirty("exclusion", "\(k)|\(v)", ["deleted"])
        }
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
        if let set = rules[.email], d.emails.contains(where: { set.contains(Normalize.emailToken($0)) }) { return true }
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
                    let norm = (kind == .email) ? Normalize.emailToken(v) : Normalize.value(v, kind: kind)
                    let added = try db.run("INSERT OR IGNORE INTO exclusions(kind, value, created_at) VALUES(?,?,?)",
                                           [.text(kind.rawValue), .text(norm), .text(ISODate.now())])
                    if added > 0 { try markDirty("exclusion", "\(kind.rawValue)|\(norm)", ["deleted"]) }
                    count += added
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
        // Копия зашифрованной базы шифруется тем же ключом. Незашифрованную копию не оставляем.
        if key != nil && EncryptedDatabase.state(of: url.path) != .encrypted {
            try? FileManager.default.removeItem(at: url)
            throw SQLiteError(message: "резервная копия получилась незашифрованной и удалена")
        }
    }

    /// Заменяет базу копией. Текущая база перед этим сохраняется рядом.
    public func restore(from url: URL) throws {
        // Копии прежних версий не зашифрованы, новые — зашифрованы ключом этого Mac.
        let probeKey = EncryptedDatabase.state(of: url.path) == .encrypted ? key : nil
        let probe = try SQLiteDB(path: url.path, readOnly: true, key: probeKey)
        let valid = try probe.tableExists("leads")
        probe.close()
        guard valid else { throw SQLiteError(message: "это не резервная копия Customers") }
        let current = URL(fileURLWithPath: path)
        guard url.standardizedFileURL.resolvingSymlinksInPath() != current.standardizedFileURL.resolvingSymlinksInPath() else {
            throw SQLiteError(message: "это текущая база, восстанавливать из неё нечего")
        }
        let fm = FileManager.default
        // Сначала копируем выбранный файл рядом, и только потом убираем текущую базу.
        let staged = current.deletingLastPathComponent().appendingPathComponent("restore-\(UUID().uuidString).db")
        try fm.copyItem(at: url, to: staged)
        defer { try? fm.removeItem(at: staged) }
        let safety = current.deletingLastPathComponent().appendingPathComponent("before-restore.db")
        try backup(to: safety)
        db.close()
        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
        do {
            try fm.moveItem(at: staged, to: current)
        } catch {
            try? fm.copyItem(at: safety, to: current)
            db = try Self.openFile(current.path, key: key)
            throw error
        }
        // Незашифрованная копия прежней версии здесь же переписывается в зашифрованную.
        db = try Self.openFile(current.path, key: key)
        try db.exec("PRAGMA journal_mode=WAL")
        try db.exec(Self.schema)
        try migrate()
        // Восстановленная копия — осознанный выбор пользователя: её состояние уходит в облако
        // как новое изменение, а всё, что появилось в облаке позже, загрузится заново.
        if syncTracking {
            try setValue("sync.enabled", "1")
            try markEverythingDirty(at: Date())
            try resetSyncCursors()
        }
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
        db = try Self.openFile(target.path, key: key)
        try db.exec("PRAGMA journal_mode=WAL")
        return target.path
    }

    public var fileSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
