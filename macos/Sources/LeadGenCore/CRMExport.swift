import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Экспорт лидов во внешние сервисы: Bitrix24 (входящий вебхук), Notion (интеграция и база данных)
// и любой JSON-вебхук (Make, n8n, Zapier, свой сервер). Только Foundation: ключи хранит приложение
// в Связке ключей, сюда они приходят параметрами и никуда не записываются.

/// Куда отправлять лиды.
public enum CRMKind: String, CaseIterable, Identifiable, Sendable {
    case bitrix, notion, webhook
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bitrix: return "Bitrix24"
        case .notion: return "Notion"
        case .webhook: return "Вебхук"
        }
    }
    /// Счёт в Связке ключей, где лежит секрет назначения.
    public var keychainAccount: String { "export.\(rawValue).secret" }
}

/// Значение JSON без `Any`: собирается в коде, проверяется в тестах, кодируется JSONEncoder.
public enum JSONValue: Encodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public func data() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// Понятные ошибки. Секреты в текст не попадают.
public enum CRMError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress(String)
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    case rateLimited
    case server(Int, String)
    case badResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let s): return s
        case .unauthorized(let s): return "Доступ не подтверждён: \(s)"
        case .forbidden(let s): return "Недостаточно прав: \(s)"
        case .notFound(let s): return "Не найдено: \(s)"
        case .rateLimited: return "Сервис просит подождать: слишком много запросов. Повторите экспорт через минуту."
        case .server(let code, let s): return s.isEmpty ? "Сервис ответил ошибкой \(code)" : "Ошибка \(code): \(s)"
        case .badResponse(let s): return "Непонятный ответ сервиса: \(s)"
        case .network(let s): return "Нет связи с сервисом: \(s)"
        }
    }

    /// Ошибка, после которой нет смысла отправлять остальные лиды.
    public var stopsExport: Bool {
        switch self {
        case .unauthorized, .forbidden, .notFound, .invalidAddress, .network: return true
        default: return false
        }
    }
}

// MARK: - Журнал отправленных (защита от дублей)

/// Какие лиды уже ушли в конкретное назначение: id лида → id записи на стороне сервиса.
/// Хранится в локальной базе (kv), в облако не синхронизируется.
public struct ExportLedger: Codable, Equatable, Sendable {
    public var sent: [String: String] = [:]
    public init(sent: [String: String] = [:]) { self.sent = sent }

    public static func decode(_ raw: String?) -> ExportLedger {
        guard let raw, let data = raw.data(using: .utf8),
              let v = try? JSONDecoder().decode(ExportLedger.self, from: data) else { return ExportLedger() }
        return v
    }

    public func encoded() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Ключ kv для назначения. Адрес вебхука содержит секрет, поэтому в ключ идёт только хэш.
    public static func storageKey(kind: CRMKind, target: String) -> String {
        "export.ledger.\(kind.rawValue).\(fnv1a(target.lowercased()))"
    }

    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Итог экспорта.
public struct CRMReport: Equatable, Sendable {
    public var exported = 0
    public var skipped = 0
    public var failures: [Failure] = []
    public var stoppedEarly = false

    public struct Failure: Equatable, Sendable {
        public var title: String
        public var message: String
    }

    public init() {}

    public var summary: String {
        var parts = ["Отправлено: \(exported)"]
        if skipped > 0 { parts.append("пропущено как уже отправленные: \(skipped)") }
        if !failures.isEmpty { parts.append("с ошибкой: \(failures.count)") }
        return parts.joined(separator: ", ")
    }
}

/// Одно назначение экспорта.
public protocol CRMDestination: Sendable {
    var kind: CRMKind { get }
    /// Что-то, однозначно определяющее место назначения (портал, база, адрес). Идёт в ключ журнала.
    var target: String { get }
    /// Пауза между запросами, чтобы уложиться в лимиты сервиса.
    var pause: TimeInterval { get }
    /// Отправить один лид. Возвращает id записи на стороне сервиса.
    func send(_ item: LeadItem, session: URLSession) async throws -> String
}

public enum CRMExporter {
    /// Отправляет лиды по одному. Уже отправленные (по журналу) пропускаются, если не `resend`.
    public static func run(_ items: [LeadItem], to destination: CRMDestination, ledger: ExportLedger,
                           resend: Bool = false, session: URLSession = .shared,
                           progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> (CRMReport, ExportLedger) {
        var report = CRMReport()
        var ledger = ledger
        var first = true
        for (i, item) in items.enumerated() {
            progress(i, items.count)
            if Task.isCancelled { report.stoppedEarly = true; break }
            if !resend, ledger.sent[item.id] != nil { report.skipped += 1; continue }
            if !first, destination.pause > 0 { try? await Task.sleep(nanoseconds: UInt64(destination.pause * 1_000_000_000)) }
            first = false
            do {
                let remote = try await sendRetrying(item, destination, session)
                ledger.sent[item.id] = remote
                report.exported += 1
            } catch {
                let e = (error as? CRMError) ?? .network(error.localizedDescription)
                report.failures.append(.init(title: item.data.title, message: e.errorDescription ?? "\(e)"))
                if e.stopsExport { report.stoppedEarly = true; break }
            }
        }
        progress(items.count, items.count)
        return (report, ledger)
    }

    /// Один повтор после «слишком много запросов».
    static func sendRetrying(_ item: LeadItem, _ d: CRMDestination, _ session: URLSession) async throws -> String {
        do { return try await d.send(item, session: session) } catch CRMError.rateLimited {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return try await d.send(item, session: session)
        }
    }

    static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, resp) = try await session.data(for: request)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw CRMError.network((error as NSError).localizedDescription)
        }
    }

    /// Число или строка из JSONSerialization (на Linux числа приходят как Int/Double, а не NSNumber).
    static func idString(_ v: Any) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double, d.rounded() == d { return String(Int(d)) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Текст лида для поля «Комментарий» / тела страницы.
    public static func comment(for item: LeadItem) -> String {
        let d = item.data
        var lines: [String] = []
        if !d.description.isEmpty { lines.append(d.description) }
        if !d.url.isEmpty { lines.append("Ссылка: \(d.url)") }
        lines.append("Источник: \(SourceCatalog.title(d.source))")
        lines.append("Оценка: \(Int(d.score.rounded())) (\(d.relevance.title))")
        if let b = ExportField.budget.value(item).nilIfEmpty { lines.append("Бюджет: \(b)") }
        if !d.scoreReasons.isEmpty { lines.append("Почему: " + d.scoreReasons.joined(separator: "; ")) }
        if !item.note.isEmpty { lines.append("Заметка: \(item.note)") }
        return lines.joined(separator: "\n")
    }
}

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Bitrix24

/// Bitrix24 через входящий вебхук (бесплатный тариф тоже). Создаёт лиды методом `crm.lead.add`.
public struct Bitrix24Destination: CRMDestination {
    public let kind = CRMKind.bitrix
    /// Адрес вида `https://portal.bitrix24.ru/rest/1/abc123/` (с завершающим `/`).
    public let base: URL
    public var target: String { base.host ?? base.absoluteString }
    /// Лимит Bitrix24: около 2 запросов в секунду.
    public let pause: TimeInterval = 0.6

    public init(webhook: String) throws { base = try Self.normalize(webhook) }

    /// Проверяет и приводит адрес вебхука к виду `https://host/rest/<user>/<code>/`.
    /// Вставленный вместе с методом адрес (`.../crm.lead.add.json`) тоже принимается.
    public static func normalize(_ raw: String) throws -> URL {
        let bad = CRMError.invalidAddress("Вставьте адрес входящего вебхука целиком, например https://ваш-портал.bitrix24.ru/rest/1/abc123def456/")
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: s), comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty else { throw bad }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard let rest = parts.firstIndex(of: "rest"), parts.count >= rest + 3,
              Int(parts[rest + 1]) != nil, !parts[rest + 2].isEmpty else { throw bad }
        let path = "/" + parts[...(rest + 2)].joined(separator: "/") + "/"
        var out = URLComponents()
        out.scheme = "https"
        out.host = host
        out.port = comps.port
        out.path = path
        guard let url = out.url else { throw bad }
        return url
    }

    /// Поля лида для `crm.lead.add`.
    public static func fields(for item: LeadItem) -> JSONValue {
        let d = item.data
        var f: [String: JSONValue] = [
            "TITLE": .string(String(d.title.prefix(250))),
            "SOURCE_ID": .string("OTHER"),
            "SOURCE_DESCRIPTION": .string("Lead Generator: \(SourceCatalog.title(d.source))"),
            "COMMENTS": .string(CRMExporter.comment(for: item)),
            "OPENED": .string("Y"),
            // Связь с исходной записью: по ней видно, откуда пришёл лид.
            "ORIGINATOR_ID": .string("lead-generator"),
            "ORIGIN_ID": .string(item.id),
        ]
        if let name = d.customerName?.nilIfEmpty ?? (d.kind == .organization ? d.title.nilIfEmpty : nil) {
            f["COMPANY_TITLE"] = .string(name)
        }
        if !d.phones.isEmpty {
            f["PHONE"] = .array(d.phones.map { JSONValue.object(["VALUE": .string($0), "VALUE_TYPE": .string("WORK")]) })
        }
        if !d.emails.isEmpty {
            f["EMAIL"] = .array(d.emails.map { JSONValue.object(["VALUE": .string($0), "VALUE_TYPE": .string("WORK")]) })
        }
        if let w = d.website?.nilIfEmpty {
            f["WEB"] = .array([.object(["VALUE": .string(w), "VALUE_TYPE": .string("WORK")])])
        }
        if let a = d.address?.nilIfEmpty { f["ADDRESS"] = .string(a) }
        if let region = d.region?.nilIfEmpty { f["ADDRESS_CITY"] = .string(region) }
        if let b = d.budget {
            f["OPPORTUNITY"] = .number(b)
            if let c = d.currency?.nilIfEmpty { f["CURRENCY_ID"] = .string(c == "₽" ? "RUB" : c.uppercased()) }
        }
        return .object(f)
    }

    public func request(method: String, body: JSONValue) throws -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent("\(method).json"), timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try body.data()
        return r
    }

    /// Разбор ответа Bitrix24: `{"result": 123}` или `{"error": "...", "error_description": "..."}`.
    public static func parse(_ data: Data, status: Int) throws -> Any {
        let obj = CRMExporter.object(data)
        if let err = obj?["error"] as? String {
            let text = (obj?["error_description"] as? String)?.nilIfEmpty ?? err
            switch err.uppercased() {
            case "QUERY_LIMIT_EXCEEDED": throw CRMError.rateLimited
            case "INVALID_CREDENTIALS", "WRONG_AUTH_TYPE", "NO_AUTH_FOUND", "EXPIRED_TOKEN", "INVALID_TOKEN":
                throw CRMError.unauthorized("Bitrix24 не принял вебхук. Проверьте адрес или создайте вебхук заново. (\(text))")
            case "INSUFFICIENT_SCOPE", "ACCESS_DENIED":
                throw CRMError.forbidden("у вебхука нет права «CRM (crm)». Откройте его настройки в Bitrix24 и отметьте CRM. (\(text))")
            case "ERROR_METHOD_NOT_FOUND":
                throw CRMError.notFound("метод не найден. Возможно, у вебхука нет права «CRM (crm)». (\(text))")
            default: throw CRMError.server(status, text)
            }
        }
        if status == 429 || status == 503 { throw CRMError.rateLimited }
        if status == 401 { throw CRMError.unauthorized("Bitrix24 не принял вебхук.") }
        if status == 404 { throw CRMError.notFound("портал или вебхук. Проверьте адрес.") }
        guard (200..<300).contains(status) else { throw CRMError.server(status, "") }
        guard let result = obj?["result"] else { throw CRMError.badResponse("нет поля result") }
        return result
    }

    /// Проверка подключения: вебхук действует и у него есть доступ к CRM.
    public func check(session: URLSession = .shared) async throws {
        let (data, code) = try await CRMExporter.perform(try request(method: "crm.lead.fields", body: .object([:])), session: session)
        _ = try Self.parse(data, status: code)
    }

    public func send(_ item: LeadItem, session: URLSession) async throws -> String {
        let body: JSONValue = .object(["fields": Self.fields(for: item),
                                       "params": .object(["REGISTER_SONET_EVENT": .string("N")])])
        let (data, code) = try await CRMExporter.perform(try request(method: "crm.lead.add", body: body), session: session)
        let result = try Self.parse(data, status: code)
        if let id = CRMExporter.idString(result) { return id }
        throw CRMError.badResponse("в ответе нет номера лида")
    }
}

// MARK: - Notion

/// Свойство базы Notion.
public struct NotionProperty: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var id: String { name }
    public init(name: String, type: String) { self.name = name; self.type = type }

    /// Типы, в которые экспорт умеет писать.
    public static let writable: Set<String> = ["title", "rich_text", "url", "email", "phone_number", "number",
                                               "select", "multi_select", "checkbox", "date"]
    public var isWritable: Bool { Self.writable.contains(type) }

    public var typeTitle: String {
        switch type {
        case "title": return "заголовок"
        case "rich_text": return "текст"
        case "url": return "ссылка"
        case "email": return "email"
        case "phone_number": return "телефон"
        case "number": return "число"
        case "select": return "выбор"
        case "multi_select": return "теги"
        case "checkbox": return "флажок"
        case "date": return "дата"
        default: return type
        }
    }
}

/// Схема базы Notion.
public struct NotionDatabase: Equatable, Sendable {
    public var id: String
    public var title: String
    public var properties: [NotionProperty]
    public init(id: String, title: String, properties: [NotionProperty]) {
        self.id = id; self.title = title; self.properties = properties
    }
}

/// Notion через внутреннюю интеграцию (бесплатно на любом тарифе): каждая страница базы — один лид.
public struct NotionDestination: CRMDestination {
    public let kind = CRMKind.notion
    public static let api = URL(string: "https://api.notion.com/v1/")!
    public static let version = "2022-06-28"
    public let token: String
    public let databaseID: String
    /// Свойство базы → поле лида.
    public let mapping: [String: ExportField]
    public let properties: [NotionProperty]
    public var target: String { databaseID }
    /// Лимит Notion: в среднем 3 запроса в секунду.
    public let pause: TimeInterval = 0.4

    public init(token: String, databaseID: String, properties: [NotionProperty], mapping: [String: ExportField]) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.databaseID = databaseID
        self.properties = properties
        self.mapping = mapping
    }

    /// ID базы из ссылки (`https://www.notion.so/workspace/Leads-0123…?v=…`) или из самого ID.
    public static func databaseID(from raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URLComponents(string: s)?.path ?? s
        let hex = Set("0123456789abcdefABCDEF")
        // Ищем последнюю группу из 32 шестнадцатеричных знаков (дефисы допускаются).
        let compact = path.replacingOccurrences(of: "-", with: "")
        let chars = Array(compact)
        var run = 0
        var end: Int?
        for (i, c) in chars.enumerated() {
            run = hex.contains(c) ? run + 1 : 0
            if run >= 32 { end = i }
        }
        guard let end else {
            throw CRMError.invalidAddress("Вставьте ссылку на базу данных Notion (Поделиться → Скопировать ссылку) или её ID из 32 символов.")
        }
        let id = String(chars[(end - 31)...end]).lowercased()
        let a = Array(id)
        return [a[0..<8], a[8..<12], a[12..<16], a[16..<20], a[20..<32]].map { String($0) }.joined(separator: "-")
    }

    static func request(_ path: String, token: String, method: String = "GET", body: JSONValue? = nil) throws -> URLRequest {
        var r = URLRequest(url: api.appendingPathComponent(path), timeoutInterval: 30)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(version, forHTTPHeaderField: "Notion-Version")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try body.data()
        }
        return r
    }

    /// Ошибки Notion: `{"object":"error","status":401,"code":"unauthorized","message":"..."}`.
    public static func check(_ data: Data, status: Int) throws -> [String: Any] {
        let obj = CRMExporter.object(data) ?? [:]
        if (200..<300).contains(status), obj["object"] as? String != "error" { return obj }
        let code = obj["code"] as? String ?? ""
        let message = (obj["message"] as? String) ?? ""
        switch (status, code) {
        case (401, _), (_, "unauthorized"):
            throw CRMError.unauthorized("Notion не принял ключ интеграции. Скопируйте его заново на notion.so/my-integrations.")
        case (403, _), (_, "restricted_resource"):
            throw CRMError.forbidden("у интеграции нет доступа к базе. Откройте базу в Notion → ••• → Подключения → добавьте интеграцию.")
        case (404, _), (_, "object_not_found"):
            throw CRMError.notFound("база не найдена или к ней не подключена интеграция. Откройте базу → ••• → Подключения → добавьте интеграцию.")
        case (429, _), (_, "rate_limited"): throw CRMError.rateLimited
        case (400, _), (_, "validation_error"):
            throw CRMError.server(400, "Notion отклонил данные: \(message). Проверьте сопоставление полей.")
        default: throw CRMError.server(status, message)
        }
    }

    /// Схема базы: название и свойства.
    public static func fetchDatabase(token: String, id: String, session: URLSession = .shared) async throws -> NotionDatabase {
        let r = try request("databases/\(id)", token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let (data, code) = try await CRMExporter.perform(r, session: session)
        return try parseDatabase(try check(data, status: code), id: id)
    }

    public static func parseDatabase(_ obj: [String: Any], id: String) throws -> NotionDatabase {
        guard let props = obj["properties"] as? [String: Any] else { throw CRMError.badResponse("в базе нет свойств") }
        let title = ((obj["title"] as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
        let list = props.compactMap { name, v -> NotionProperty? in
            guard let type = (v as? [String: Any])?["type"] as? String else { return nil }
            return NotionProperty(name: name, type: type)
        }
        // Заголовок первым, остальные по имени.
        let sorted = list.sorted { ($0.type == "title" ? 0 : 1, $0.name) < ($1.type == "title" ? 0 : 1, $1.name) }
        return NotionDatabase(id: id, title: title.isEmpty ? "Без названия" : title, properties: sorted)
    }

    /// Сопоставление по умолчанию: заголовок ← название, остальные — по похожему имени свойства.
    public static func autoMapping(_ properties: [NotionProperty]) -> [String: ExportField] {
        var out: [String: ExportField] = [:]
        var used = Set<ExportField>()
        let synonyms: [ExportField: [String]] = [
            .title: ["название", "name", "title", "имя", "лид"],
            .url: ["ссылка", "url", "link", "источник ссылка"],
            .phone: ["телефон", "phone", "тел"],
            .emails: ["email", "e-mail", "почта", "mail"],
            .website: ["сайт", "website", "web", "site"],
            .address: ["адрес", "address"],
            .region: ["регион", "город", "region", "city"],
            .category: ["категория", "category", "тип проекта"],
            .source: ["источник", "source"],
            .score: ["оценка", "score", "балл"],
            .relevance: ["релевантность", "relevance", "приоритет"],
            .kind: ["тип", "kind", "type"],
            .budget: ["бюджет", "budget", "сумма"],
            .discoveredAt: ["обнаружен", "дата", "date", "найден"],
            .description: ["описание", "description"],
            .note: ["заметка", "note", "комментарий"],
            .reasons: ["причины оценки", "причины", "reasons"],
            .favorite: ["избранное", "favorite"],
        ]
        for p in properties where p.type == "title" {
            out[p.name] = .title; used.insert(.title)
        }
        for p in properties where p.isWritable && out[p.name] == nil {
            let n = p.name.lowercased().trimmingCharacters(in: .whitespaces)
            let match = ExportField.allCases.first { f in
                !used.contains(f) && ((synonyms[f] ?? []).contains(n) || f.title.lowercased() == n)
            }
            if let f = match {
                out[p.name] = f; used.insert(f)
            }
        }
        return out
    }

    /// Значение свойства Notion из поля лида. `nil` — пропустить (пустое или неподходящее).
    public static func value(_ field: ExportField, of item: LeadItem, type: String) -> JSONValue? {
        let raw: String
        switch field {
        case .phone: raw = item.data.phones.first ?? ""
        case .emails: raw = item.data.emails.first ?? ""
        default: raw = field.value(item)
        }
        if type == "checkbox" { return .bool(field == .favorite ? item.favorite : !raw.isEmpty) }
        let text = String(raw.prefix(2000))
        guard !text.isEmpty else { return nil }
        func rich(_ s: String) -> JSONValue { .array([.object(["text": .object(["content": .string(s)])])]) }
        switch type {
        case "title": return .object(["title": rich(text)])
        case "rich_text": return .object(["rich_text": rich(field == .phone ? item.data.phones.joined(separator: ", ") : field == .emails ? item.data.emails.joined(separator: ", ") : text)])
        case "url":
            let u = field == .emails ? "mailto:\(text)" : field == .phone ? "tel:\(text.filter { $0.isNumber || $0 == "+" })" : text
            return .object(["url": .string(u)])
        case "email": return text.contains("@") ? .object(["email": .string(text)]) : nil
        case "phone_number": return .object(["phone_number": .string(text)])
        case "number":
            let n: Double?
            switch field {
            case .score: n = item.data.score.rounded()
            case .budget: n = item.data.budget
            default: n = Double(text.replacingOccurrences(of: ",", with: "."))
            }
            guard let n else { return nil }
            return .object(["number": .number(n)])
        case "select":
            return .object(["select": .object(["name": .string(String(text.prefix(100)).replacingOccurrences(of: ",", with: " "))])])
        case "multi_select":
            let tags = text.split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(100)) }.filter { !$0.isEmpty }
            guard !tags.isEmpty else { return nil }
            return .object(["multi_select": .array(tags.prefix(20).map { JSONValue.object(["name": .string($0)]) })])
        case "date":
            let date: Date? = field == .discoveredAt ? item.discoveredAt : ISODate.parse(text)
            guard let start = ISODate.format(date) else { return nil }
            return .object(["date": .object(["start": .string(start)])])
        default: return nil
        }
    }

    public func pageBody(for item: LeadItem) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for p in properties {
            guard let field = mapping[p.name], let v = Self.value(field, of: item, type: p.type) else { continue }
            props[p.name] = v
        }
        // Текст лида — в тело страницы, абзацами по 2000 символов (лимит Notion).
        let text = CRMExporter.comment(for: item)
        var chunks: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty && chunks.count < 20 { chunks.append(String(rest.prefix(2000))); rest = rest.dropFirst(2000) }
        let children: [JSONValue] = chunks.map {
            .object(["object": .string("block"), "type": .string("paragraph"),
                     "paragraph": .object(["rich_text": .array([.object(["text": .object(["content": .string($0)])])])])])
        }
        return .object(["parent": .object(["database_id": .string(databaseID)]),
                        "properties": .object(props), "children": .array(children)])
    }

    public func send(_ item: LeadItem, session: URLSession) async throws -> String {
        let r = try Self.request("pages", token: token, method: "POST", body: pageBody(for: item))
        let (data, code) = try await CRMExporter.perform(r, session: session)
        let obj = try Self.check(data, status: code)
        guard let id = obj["id"] as? String else { throw CRMError.badResponse("в ответе нет id страницы") }
        return id
    }
}

// MARK: - Вебхук

/// Любой адрес, принимающий JSON методом POST: сценарии Make, n8n, Zapier, Pipedream или свой сервер.
/// Через них лиды попадают в amoCRM, Google Таблицы, Airtable и т. д.
public struct WebhookDestination: CRMDestination {
    public let kind = CRMKind.webhook
    public let url: URL
    public var target: String { url.absoluteString }
    public let pause: TimeInterval = 0.25

    public init(url raw: String) throws { url = try Self.normalize(raw) }

    public static func normalize(_ raw: String) throws -> URL {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", let host = u.host, !host.isEmpty else {
            throw CRMError.invalidAddress("Нужен адрес вебхука, начинающийся с https://")
        }
        return u
    }

    /// Тело запроса: один лид, все поля экспорта, плюс телефоны и email списками.
    public static func payload(for item: LeadItem) -> JSONValue {
        var lead: [String: JSONValue] = [:]
        for f in ExportField.allCases { lead[f.rawValue] = .string(f.value(item)) }
        lead["phones"] = .array(item.data.phones.map { JSONValue.string($0) })
        lead["email_list"] = .array(item.data.emails.map { JSONValue.string($0) })
        lead["score"] = .number(item.data.score.rounded())
        lead["favorite"] = .bool(item.favorite)
        return .object(["event": .string("lead.exported"), "source": .string("lead-generator"),
                        "lead_id": .string(item.id), "lead": .object(lead)])
    }

    public func send(_ item: LeadItem, session: URLSession) async throws -> String {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(item.id, forHTTPHeaderField: "X-LeadGen-Lead-Id")
        r.httpBody = try Self.payload(for: item).data()
        let (data, code) = try await CRMExporter.perform(r, session: session)
        switch code {
        case 200..<300:
            if let obj = CRMExporter.object(data), let id = obj["id"].flatMap(CRMExporter.idString) { return id }
            return item.id
        case 401: throw CRMError.unauthorized("адрес вебхука отклонил запрос.")
        case 403: throw CRMError.forbidden("адрес вебхука отклонил запрос.")
        case 404, 410: throw CRMError.notFound("адрес вебхука не существует или сценарий выключен.")
        case 429: throw CRMError.rateLimited
        default:
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw CRMError.server(code, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
