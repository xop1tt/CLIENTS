import Foundation

public enum CSV {
    public static func escape(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Разбор одной строки CSV (запятая или точка с запятой, кавычки).
    public static func parseLine(_ line: String) -> [String] {
        let sep: Character = line.filter { $0 == ";" }.count > line.filter { $0 == "," }.count ? ";" : ","
        var out: [String] = [], cur = "", quoted = false
        var it = Array(line), i = 0
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < it.count && it[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == sep { out.append(cur); cur = "" }
            else { cur.append(c) }
            i += 1
        }
        out.append(cur)
        it.removeAll()
        return out
    }
}

/// Поля, доступные при экспорте.
public enum ExportField: String, CaseIterable, Identifiable, Sendable {
    case id, kind, title, source, score, relevance, region, category, address, phone, website, emails
    case url, discoveredAt, budget, reasons, facts, assumptions, favorite, note, description

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .id: return "ID"
        case .kind: return "Тип"
        case .title: return "Название"
        case .source: return "Источник"
        case .score: return "Оценка"
        case .relevance: return "Релевантность"
        case .region: return "Регион"
        case .category: return "Категория"
        case .address: return "Адрес"
        case .phone: return "Телефон"
        case .website: return "Сайт"
        case .emails: return "Email"
        case .url: return "Ссылка"
        case .discoveredAt: return "Обнаружен"
        case .budget: return "Бюджет"
        case .reasons: return "Причины оценки"
        case .facts: return "Факты"
        case .assumptions: return "Предположения"
        case .favorite: return "Избранное"
        case .note: return "Заметка"
        case .description: return "Описание"
        }
    }

    public static let defaults: [ExportField] = [.title, .kind, .source, .score, .relevance, .region, .category,
                                                 .address, .phone, .website, .emails, .url, .discoveredAt, .reasons]

    func value(_ l: LeadItem) -> String {
        let d = l.data
        switch self {
        case .id: return l.id
        case .kind: return d.kind.title
        case .title: return d.title
        case .source: return SourceCatalog.title(d.source)
        case .score: return String(Int(d.score.rounded()))
        case .relevance: return d.relevance.title
        case .region: return d.region ?? ""
        case .category: return d.category ?? d.projectType ?? ""
        case .address: return d.address ?? ""
        case .phone: return d.phones.joined(separator: ", ")
        case .website: return d.website ?? ""
        case .emails: return d.emails.joined(separator: ", ")
        case .url: return d.url
        case .discoveredAt: return ISODate.format(l.discoveredAt) ?? ""
        case .budget: return d.budget.map { "\(Int($0)) \(d.currency ?? "")".trimmingCharacters(in: .whitespaces) } ?? ""
        case .reasons: return d.scoreReasons.joined(separator: "; ")
        case .facts: return d.facts.joined(separator: "; ")
        case .assumptions: return d.assumptions.joined(separator: "; ")
        case .favorite: return l.favorite ? "да" : ""
        case .note: return l.note
        case .description: return d.description
        }
    }
}

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json
    public var id: String { rawValue }
    public var title: String { self == .csv ? "CSV (Excel, Numbers)" : "JSON" }
    public var fileExtension: String { rawValue }
}

public enum Exporter {
    /// CSV с BOM, чтобы Excel правильно открыл кириллицу.
    public static func csv(_ leads: [LeadItem], fields: [ExportField] = ExportField.defaults) -> Data {
        var lines = [fields.map { CSV.escape($0.title) }.joined(separator: ",")]
        for l in leads { lines.append(fields.map { CSV.escape($0.value(l)) }.joined(separator: ",")) }
        return Data("\u{FEFF}".utf8) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    public static func json(_ leads: [LeadItem], fields: [ExportField] = ExportField.allCases) throws -> Data {
        let rows: [[String: String]] = leads.map { l in
            Dictionary(uniqueKeysWithValues: fields.map { ($0.rawValue, $0.value(l)) })
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(rows)
    }

    public static func export(_ leads: [LeadItem], format: ExportFormat, fields: [ExportField]) throws -> Data {
        switch format {
        case .csv: return csv(leads, fields: fields)
        case .json: return try json(leads, fields: fields)
        }
    }
}

/// Черновик первого обращения по шаблону, без AI. Отправка только вручную.
public enum DraftWriter {
    public enum Channel: String, CaseIterable, Identifiable, Sendable {
        case message, email, call
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .message: return "Мессенджер"
            case .email: return "Email"
            case .call: return "Звонок"
            }
        }
    }

    static let services: [String: String] = [
        "site": "сайт", "telegram_bot": "Telegram-бот", "mobile_app": "мобильное приложение",
        "web_app": "веб-приложение", "automation": "автоматизацию", "crm": "CRM-систему",
        "support": "доработку существующего проекта",
    ]

    public static func draft(for lead: LeadData, channel: Channel, signature: String) -> String {
        let sign = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        let greeting = channel == .call ? "Добрый день! Меня зовут \(sign.isEmpty ? "…" : sign), я разработчик." : "Здравствуйте!"
        var body: String
        switch lead.kind {
        case .order:
            let what = lead.projectType.flatMap { services[$0] } ?? "этот проект"
            body = "Увидел вашу заявку «\(lead.title)». Делаю \(what) под ключ: могу коротко рассказать, как бы я это реализовал, и назвать срок и стоимость после пары уточняющих вопросов."
            if lead.budget != nil { body += " Бюджет вижу, предложение уложу в него." }
        case .organization:
            let name = lead.customerName ?? lead.title
            let facts = lead.facts.map { $0.lowercased() }
            let problem: String
            if lead.website == nil || lead.website?.isEmpty == true || facts.contains(where: { $0.contains("не указан сайт") }) {
                problem = "не нашёл у «\(name)» сайта, где можно посмотреть услуги и записаться онлайн"
            } else if facts.contains(where: { $0.contains("не открылся") || $0.contains("http") && $0.contains("5") }) {
                problem = "сайт «\(name)» сейчас не открывается"
            } else if facts.contains(where: { $0.contains("viewport") || $0.contains("мобильн") }) {
                problem = "сайт «\(name)» неудобно открывается с телефона"
            } else if facts.contains(where: { $0.contains("запис") }) {
                problem = "на сайте «\(name)» нет онлайн-записи"
            } else {
                problem = "у «\(name)» можно упростить работу с клиентами"
            }
            body = "Обратил внимание, что \(problem). Я делаю небольшие сайты, онлайн-запись и Telegram-ботов для бизнеса. Могу бесплатно показать, как это выглядело бы у вас, — займёт пять минут."
        }
        var text = channel == .call ? "\(greeting) \(body)" : "\(greeting)\n\n\(body)"
        if channel != .call && !sign.isEmpty { text += "\n\n\(sign)" }
        if channel == .email { text = "Тема: \(lead.kind == .order ? "Ваша заявка: " + lead.title : "Предложение для " + (lead.customerName ?? lead.title))\n\n" + text }
        return text
    }
}
