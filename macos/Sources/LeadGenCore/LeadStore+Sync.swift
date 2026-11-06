import Foundation
import LeadCloud

/// Журнал изменений для облачной синхронизации и применение изменений с сервера.
///
/// Что синхронизируется: лиды (данные и отметки пользователя: избранное, архив, удаление,
/// просмотр, заметка), исключения и настройки из `syncedKeys`. Что остаётся на этом Mac:
/// память источников поиска, журнал поиска, история действий, пути к файлам, ключ VK,
/// оформление.
extension LeadStore: SyncLocalStore {
    /// Ключи kv, которые уходят в облако. Значения — JSON-текст.
    public static let syncedKeys: Set<String> = ["search.settings", "draft.signature", "search.auto"]

    static let leadFields = ["data", "favorite", "archived", "deleted", "seen", "note"]

    static let syncSchema = """
    CREATE TABLE IF NOT EXISTS sync_dirty (
        entity TEXT NOT NULL,
        key TEXT NOT NULL,
        field TEXT NOT NULL,
        changed_at TEXT NOT NULL,
        PRIMARY KEY (entity, key, field)
    );
    """

    /// Время с миллисекундами: два изменения в одну секунду различаются.
    static func stamp(_ d: Date = Date()) -> String { ISODate.formatPrecise(d) }

    func markDirty(_ entity: String, _ key: String, _ fields: [String], at: String = LeadStore.stamp()) throws {
        guard syncTracking else { return }
        for f in fields {
            try db.run("""
                INSERT INTO sync_dirty(entity, key, field, changed_at) VALUES(?,?,?,?)
                ON CONFLICT(entity, key, field) DO UPDATE SET changed_at=excluded.changed_at
                """, [.text(entity), .text(key), .text(f), .text(at)])
        }
    }

    /// Отметить все данные как изменённые — для первой выгрузки (перенос локальной базы в облако).
    /// `at` — время изменения: при переносе передаётся раннее время, чтобы уже существующие в
    /// облаке более свежие изменения не затирались.
    public func markEverythingDirty(at: Date) throws {
        let ts = Self.stamp(at)
        try db.transaction {
            for row in try db.query("SELECT lead_id FROM leads") {
                if let id = row["lead_id"]?.string { try markDirty("lead", id, Self.leadFields, at: ts) }
            }
            for e in try exclusions() { try markDirty("exclusion", "\(e.kind.rawValue)|\(e.value)", ["deleted"], at: ts) }
            for k in Self.syncedKeys where value(k) != nil { try markDirty("setting", k, ["value"], at: ts) }
        }
    }

    public var pendingSyncCount: Int { Int((try? db.scalar("SELECT COUNT(DISTINCT entity || key) FROM sync_dirty"))?.int ?? 0) }

    // MARK: SyncLocalStore

    public func pendingChanges(limit: Int) throws -> PendingChanges {
        var out = PendingChanges()
        let rows = try db.query("""
            SELECT entity, key, field, changed_at FROM sync_dirty
            WHERE (entity, key) IN (SELECT entity, key FROM sync_dirty GROUP BY entity, key ORDER BY MIN(changed_at) LIMIT ?)
            """, [.int(Int64(limit))])
        var grouped: [String: [String: [String: String]]] = [:]
        for r in rows {
            guard let e = r["entity"]?.string, let k = r["key"]?.string, let f = r["field"]?.string,
                  let at = r["changed_at"]?.string else { continue }
            grouped[e, default: [:]][k, default: [:]][f] = at
        }
        for (id, ts) in grouped["lead"] ?? [:] {
            guard let r = try db.query("""
                SELECT lead_id, fingerprint, kind, source, title, score, relevance, discovered_at, data_json,
                       favorite, archived, deleted, seen, note FROM leads WHERE lead_id=?
                """, [.text(id)]).first, let data = JSONValue.parse(r["data_json"]?.string ?? "") else {
                // Лида больше нет локально — изменение отправлять некуда.
                try db.run("DELETE FROM sync_dirty WHERE entity='lead' AND key=?", [.text(id)])
                continue
            }
            out.leads.append(LeadChange(
                lead_id: id, fingerprint: r["fingerprint"]?.string ?? "", kind: r["kind"]?.string ?? "order",
                source: r["source"]?.string ?? "", title: r["title"]?.string ?? "", score: r["score"]?.double ?? 0,
                relevance: r["relevance"]?.string ?? "rejected",
                discovered_at: ISODate.format(ISODate.parse(r["discovered_at"]?.string)) ?? ISODate.now(),
                data: data, favorite: r["favorite"]?.bool ?? false, archived: r["archived"]?.bool ?? false,
                deleted: r["deleted"]?.bool ?? false, seen: r["seen"]?.bool ?? false, note: r["note"]?.string ?? "",
                ts: ts))
        }
        for (key, ts) in grouped["exclusion"] ?? [:] {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let at = ts["deleted"] else { continue }
            let exists = try !db.query("SELECT 1 FROM exclusions WHERE kind=? AND value=?", [.text(parts[0]), .text(parts[1])]).isEmpty
            out.exclusions.append(ExclusionChange(kind: parts[0], value: parts[1], deleted: !exists, changed_at: at))
        }
        for (key, ts) in grouped["setting"] ?? [:] {
            guard let at = ts["value"] else { continue }
            let v = value(key).flatMap(JSONValue.parse) ?? .null
            out.settings.append(SettingChange(key: key, value: v, changed_at: at))
        }
        out.leads.sort { $0.lead_id < $1.lead_id }
        return out
    }

    public func markPushed(_ c: PendingChanges) throws {
        try db.transaction {
            func clear(_ entity: String, _ key: String, _ field: String, _ at: String) throws {
                try db.run("DELETE FROM sync_dirty WHERE entity=? AND key=? AND field=? AND changed_at=?",
                           [.text(entity), .text(key), .text(field), .text(at)])
            }
            for l in c.leads { for (f, at) in l.ts { try clear("lead", l.lead_id, f, at) } }
            for e in c.exclusions { try clear("exclusion", "\(e.kind)|\(e.value)", "deleted", e.changed_at) }
            for s in c.settings { try clear("setting", s.key, "value", s.changed_at) }
        }
    }

    private func dirtyAt(_ entity: String, _ key: String) throws -> [String: Date] {
        var out: [String: Date] = [:]
        for r in try db.query("SELECT field, changed_at FROM sync_dirty WHERE entity=? AND key=?", [.text(entity), .text(key)]) {
            if let f = r["field"]?.string, let d = ISODate.parse(r["changed_at"]?.string) { out[f] = d }
        }
        return out
    }

    /// Применяет изменения с сервера. Поле, изменённое здесь позже серверного, не трогается:
    /// оно уйдёт на сервер при следующей выгрузке. Применённые изменения в журнал не пишутся,
    /// поэтому эхо-цикла «загрузил → выгрузил» не возникает.
    public func applyRemote(leads: [RemoteLead], exclusions: [RemoteExclusion], settings: [RemoteSetting]) throws {
        let decoder = JSONDecoder()
        try db.transaction {
            for r in leads {
                let local = try dirtyAt("lead", r.lead_id)
                func remoteWins(_ f: String) -> Bool {
                    guard let mine = local[f] else { return true }
                    let theirs = ISODate.parse(r.field_ts[f]) ?? .distantPast
                    return theirs > mine
                }
                // Данные лида храним в том же стабильном виде, что и поиск.
                let lead = try? decoder.decode(LeadData.self, from: Data(r.data.text.utf8))
                let json = lead.flatMap { try? Self.encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? r.data.text
                let discovered = ISODate.format(ISODate.parse(r.discovered_at)) ?? ISODate.now()
                let exists = try !db.query("SELECT 1 FROM leads WHERE lead_id=?", [.text(r.lead_id)]).isEmpty
                if !exists {
                    try db.run("""
                        INSERT INTO leads(lead_id, fingerprint, kind, source, title, score, relevance, discovered_at, updated_at,
                                          data_json, imported_at, favorite, archived, deleted, seen, note)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, [.text(r.lead_id), .text(r.fingerprint), .text(r.kind), .text(r.source), .text(r.title),
                              .double(r.score), .text(r.relevance), .text(discovered), .text(ISODate.now()), .text(json),
                              .text(ISODate.now()), .of(r.favorite), .of(r.archived), .of(r.deleted), .of(r.seen), .text(r.note)])
                    continue
                }
                if remoteWins("data") {
                    try db.run("""
                        UPDATE leads SET fingerprint=?, kind=?, source=?, title=?, score=?, relevance=?, data_json=?,
                            discovered_at=MIN(discovered_at, ?) WHERE lead_id=?
                        """, [.text(r.fingerprint), .text(r.kind), .text(r.source), .text(r.title), .double(r.score),
                              .text(r.relevance), .text(json), .text(discovered), .text(r.lead_id)])
                }
                for (f, v) in [("favorite", SQLValue.of(r.favorite)), ("archived", .of(r.archived)), ("deleted", .of(r.deleted)),
                               ("seen", .of(r.seen)), ("note", .text(r.note))] where remoteWins(f) {
                    try db.run("UPDATE leads SET \(f)=? WHERE lead_id=?", [v, .text(r.lead_id)])
                }
            }
            for e in exclusions {
                let key = "\(e.kind)|\(e.value)"
                if let mine = try dirtyAt("exclusion", key)["deleted"], mine >= (ISODate.parse(e.changed_at) ?? .distantPast) { continue }
                if e.deleted {
                    try db.run("DELETE FROM exclusions WHERE kind=? AND value=?", [.text(e.kind), .text(e.value)])
                } else if ExclusionKind(rawValue: e.kind) != nil {
                    try db.run("INSERT OR IGNORE INTO exclusions(kind, value, created_at) VALUES(?,?,?)",
                               [.text(e.kind), .text(e.value), .text(ISODate.now())])
                }
            }
            for s in settings where Self.syncedKeys.contains(s.key) {
                if let mine = try dirtyAt("setting", s.key)["value"], mine >= (ISODate.parse(s.changed_at) ?? .distantPast) { continue }
                try db.run("INSERT INTO kv(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           [.text(s.key), .text(s.value.text)])
            }
        }
        if !exclusions.isEmpty || !leads.isEmpty { try applyExclusions() }
    }

    public func syncCursor(_ table: String) -> Int64 { Int64(value("sync.cursor.\(table)") ?? "") ?? 0 }

    public func setSyncCursor(_ table: String, _ value: Int64) throws {
        try db.run("INSERT INTO kv(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text("sync.cursor.\(table)"), .text(String(value))])
    }

    /// Начать синхронизацию заново (например, после восстановления из резервной копии).
    public func resetSyncCursors() throws {
        try db.run("DELETE FROM kv WHERE key LIKE 'sync.cursor.%'")
    }

    // MARK: Настройки в облаке

    /// Записать синхронизируемую настройку (JSON-текст) и отметить её для выгрузки.
    public func setSyncedValue(_ key: String, _ json: String) throws {
        try db.transaction {
            try db.run("INSERT INTO kv(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       [.text(key), .text(json)])
            if Self.syncedKeys.contains(key) { try markDirty("setting", key, ["value"]) }
        }
    }
}
