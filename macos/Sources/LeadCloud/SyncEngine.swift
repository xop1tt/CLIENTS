import Foundation

// Формат обмена — тот же, что у SQL-функции sync_push и таблиц public.leads / exclusions /
// user_settings (см. docs/cloud.md). Его может реализовать любой клиент, в том числе Windows.

/// Изменение лида для выгрузки. `ts` — время изменения только тех полей, что менялись на
/// этом устройстве; остальные поля сервер использует лишь при создании строки.
public struct LeadChange: Codable, Equatable, Sendable {
    public var lead_id: String
    public var fingerprint: String
    public var kind: String
    public var source: String
    public var title: String
    public var score: Double
    public var relevance: String
    public var discovered_at: String
    public var data: JSONValue
    public var favorite: Bool
    public var archived: Bool
    public var deleted: Bool
    public var seen: Bool
    public var note: String
    public var ts: [String: String]

    public init(lead_id: String, fingerprint: String, kind: String, source: String, title: String, score: Double,
                relevance: String, discovered_at: String, data: JSONValue, favorite: Bool, archived: Bool,
                deleted: Bool, seen: Bool, note: String, ts: [String: String]) {
        self.lead_id = lead_id; self.fingerprint = fingerprint; self.kind = kind; self.source = source
        self.title = title; self.score = score; self.relevance = relevance; self.discovered_at = discovered_at
        self.data = data; self.favorite = favorite; self.archived = archived; self.deleted = deleted
        self.seen = seen; self.note = note; self.ts = ts
    }
}

public struct ExclusionChange: Codable, Equatable, Sendable {
    public var kind: String
    public var value: String
    public var deleted: Bool
    public var changed_at: String
    public init(kind: String, value: String, deleted: Bool, changed_at: String) {
        self.kind = kind; self.value = value; self.deleted = deleted; self.changed_at = changed_at
    }
}

public struct SettingChange: Codable, Equatable, Sendable {
    public var key: String
    public var value: JSONValue
    public var changed_at: String
    public init(key: String, value: JSONValue, changed_at: String) {
        self.key = key; self.value = value; self.changed_at = changed_at
    }
}

public struct PendingChanges: Equatable, Sendable {
    public var leads: [LeadChange] = []
    public var exclusions: [ExclusionChange] = []
    public var settings: [SettingChange] = []
    public init(leads: [LeadChange] = [], exclusions: [ExclusionChange] = [], settings: [SettingChange] = []) {
        self.leads = leads; self.exclusions = exclusions; self.settings = settings
    }
    public var isEmpty: Bool { leads.isEmpty && exclusions.isEmpty && settings.isEmpty }
    public var count: Int { leads.count + exclusions.count + settings.count }
}

public struct RemoteLead: Codable, Equatable, Sendable {
    public var lead_id: String
    public var fingerprint: String
    public var kind: String
    public var source: String
    public var title: String
    public var score: Double
    public var relevance: String
    public var discovered_at: String
    public var data: JSONValue
    public var favorite: Bool
    public var archived: Bool
    public var deleted: Bool
    public var seen: Bool
    public var note: String
    public var field_ts: [String: String]
    public var server_seq: Int64
}

public struct RemoteExclusion: Codable, Equatable, Sendable {
    public var kind: String
    public var value: String
    public var deleted: Bool
    public var changed_at: String
    public var server_seq: Int64
}

public struct RemoteSetting: Codable, Equatable, Sendable {
    public var key: String
    public var value: JSONValue
    public var changed_at: String
    public var server_seq: Int64
}

/// Локальное хранилище с журналом несинхронизированных изменений.
/// Изменения записываются в журнал в той же транзакции SQLite, что и сами данные, поэтому
/// переживают аварийное завершение приложения и уходят в облако при следующей синхронизации.
public protocol SyncLocalStore: AnyObject, Sendable {
    func pendingChanges(limit: Int) throws -> PendingChanges
    /// Убрать из журнала отправленные изменения (только если поле не менялось снова).
    func markPushed(_ changes: PendingChanges) throws
    func applyRemote(leads: [RemoteLead], exclusions: [RemoteExclusion], settings: [RemoteSetting]) throws
    func syncCursor(_ table: String) -> Int64
    func setSyncCursor(_ table: String, _ value: Int64) throws
}

public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    public var finishedAt = Date()
    public init(pushed: Int = 0, pulled: Int = 0) { self.pushed = pushed; self.pulled = pulled }
}

/// Двусторонняя синхронизация: сначала выгрузка журнала, затем загрузка всего, что новее
/// локальных курсоров. Конфликты решает сервер по времени изменения каждого поля.
public actor SyncEngine {
    let auth: CloudAuth
    let store: SyncLocalStore
    let deviceID: String
    let batch: Int
    let pageSize: Int

    public init(auth: CloudAuth, store: SyncLocalStore, deviceID: String, batch: Int = 200, pageSize: Int = 500) {
        self.auth = auth
        self.store = store
        self.deviceID = deviceID
        self.batch = batch
        self.pageSize = pageSize
    }

    public func sync() async throws -> SyncReport {
        var report = SyncReport()
        report.pushed = try await push()
        report.pulled = try await pull()
        // Изменения, сделанные во время загрузки, уходят сразу же.
        report.pushed += try await push()
        report.finishedAt = Date()
        return report
    }

    func push() async throws -> Int {
        var total = 0
        for _ in 0..<1000 {  // защита от бесконечного цикла
            let pending = try store.pendingChanges(limit: batch)
            if pending.isEmpty { break }
            let body: [String: Any] = [
                "p_device": deviceID,
                "p_changes": [
                    "leads": try Self.jsonArray(pending.leads),
                    "exclusions": try Self.jsonArray(pending.exclusions),
                    "settings": try Self.jsonArray(pending.settings),
                ],
            ]
            let (data, res) = try await auth.authorized("POST", "/rest/v1/rpc/sync_push", body: body)
            guard (200..<300).contains(res.statusCode) else { throw Self.restError(res.statusCode, data) }
            try store.markPushed(pending)
            total += pending.count
            if pending.count < batch { break }
        }
        return total
    }

    func pull() async throws -> Int {
        var total = 0
        total += try await pullTable("leads", RemoteLead.self) { try self.store.applyRemote(leads: $0, exclusions: [], settings: []) }
        total += try await pullTable("exclusions", RemoteExclusion.self) { try self.store.applyRemote(leads: [], exclusions: $0, settings: []) }
        total += try await pullTable("user_settings", RemoteSetting.self) { try self.store.applyRemote(leads: [], exclusions: [], settings: $0) }
        return total
    }

    private func pullTable<T: Decodable & SeqRow>(_ table: String, _: T.Type, apply: ([T]) throws -> Void) async throws -> Int {
        var total = 0
        for _ in 0..<10_000 {
            let cursor = store.syncCursor(table)
            let path = "/rest/v1/\(table)?select=*&server_seq=gt.\(cursor)&order=server_seq.asc&limit=\(pageSize)"
            let (data, res) = try await auth.authorized("GET", path)
            guard (200..<300).contains(res.statusCode) else { throw Self.restError(res.statusCode, data) }
            let rows = try JSONDecoder().decode([T].self, from: data)
            if rows.isEmpty { break }
            try apply(rows)
            try store.setSyncCursor(table, rows.map(\.server_seq).max() ?? cursor)
            total += rows.count
            if rows.count < pageSize { break }
        }
        return total
    }

    /// Сводка в облаке — для проверки первоначального переноса.
    public func remoteStats() async throws -> [String: Int] {
        let (data, res) = try await auth.authorized("POST", "/rest/v1/rpc/sync_stats", body: [String: Any]())
        guard (200..<300).contains(res.statusCode) else { throw Self.restError(res.statusCode, data) }
        let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return obj.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    static func jsonArray<T: Encodable>(_ items: [T]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(items))
    }

    static func restError(_ status: Int, _ data: Data) -> CloudError {
        if status == 401 || status == 403 { return .sessionExpired }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return .server((obj?["message"] as? String).map { String($0.prefix(200)) } ?? "HTTP \(status)")
    }
}

protocol SeqRow { var server_seq: Int64 { get } }
extension RemoteLead: SeqRow {}
extension RemoteExclusion: SeqRow {}
extension RemoteSetting: SeqRow {}
