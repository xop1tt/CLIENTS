import Foundation

/// Тип находки: готовый заказ или организация — потенциальный клиент.
public enum LeadKind: String, Codable, CaseIterable, Sendable {
    case order
    case organization

    public var title: String { self == .order ? "Заказ" : "Организация" }
}

/// Релевантность по оценке системы (не факт).
public enum Relevance: String, Codable, CaseIterable, Sendable {
    case high, medium, low, rejected

    public var title: String {
        switch self {
        case .high: return "Высокая"
        case .medium: return "Средняя"
        case .low: return "Низкая"
        case .rejected: return "Не подходит"
        }
    }

    public var rank: Int {
        switch self {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .rejected: return 0
        }
    }
}

/// Результат внешнего анализатора. Хранится отдельно от исходных данных.
public struct ExternalResult: Codable, Hashable, Sendable {
    public var service: String
    public var processedAt: Date?
    public var ok: Bool
    public var score: Double?
    public var label: String?
    public var error: String?

    public init(service: String, processedAt: Date?, ok: Bool, score: Double?, label: String?, error: String?) {
        self.service = service; self.processedAt = processedAt; self.ok = ok
        self.score = score; self.label = label; self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case service, ok, score, label, error
        case processedAt = "processed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        service = try c.decode(String.self, forKey: .service)
        processedAt = ISODate.parse(try c.decodeIfPresent(String.self, forKey: .processedAt))
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(service, forKey: .service)
        try c.encodeIfPresent(ISODate.format(processedAt), forKey: .processedAt)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(score, forKey: .score)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

/// Лид в том виде, в котором его сохраняет поисковый конвейер на Python (`Lead.to_json`).
public struct LeadData: Codable, Hashable, Sendable {
    public var kind: LeadKind
    public var source: String
    public var externalId: String
    public var title: String
    public var url: String
    public var description: String
    public var publishedAt: Date?
    public var discoveredAt: Date?
    public var budget: Double?
    public var currency: String?
    public var region: String?
    public var contacts: [String: String]
    public var category: String?
    public var projectType: String?
    public var customerName: String?
    public var address: String?
    public var phone: String?
    public var website: String?
    public var facts: [String]
    public var assumptions: [String]
    public var score: Double
    public var relevance: Relevance
    public var scoreReasons: [String]
    public var status: String
    public var externalResults: [ExternalResult]

    enum CodingKeys: String, CodingKey {
        case kind, source, title, url, description, budget, currency, region, contacts, category
        case address, phone, website, facts, assumptions, score, relevance, status
        case externalId = "external_id"
        case publishedAt = "published_at"
        case discoveredAt = "discovered_at"
        case projectType = "project_type"
        case customerName = "customer_name"
        case scoreReasons = "score_reasons"
        case externalResults = "external_results"
    }

    public init(kind: LeadKind, source: String, externalId: String, title: String, url: String = "",
                description: String = "", publishedAt: Date? = nil, discoveredAt: Date? = nil,
                budget: Double? = nil, currency: String? = nil, region: String? = nil,
                contacts: [String: String] = [:], category: String? = nil, projectType: String? = nil,
                customerName: String? = nil, address: String? = nil, phone: String? = nil,
                website: String? = nil, facts: [String] = [], assumptions: [String] = [],
                score: Double = 0, relevance: Relevance = .rejected, scoreReasons: [String] = [],
                status: String = "new", externalResults: [ExternalResult] = []) {
        self.kind = kind; self.source = source; self.externalId = externalId; self.title = title
        self.url = url; self.description = description; self.publishedAt = publishedAt
        self.discoveredAt = discoveredAt; self.budget = budget; self.currency = currency
        self.region = region; self.contacts = contacts; self.category = category
        self.projectType = projectType; self.customerName = customerName; self.address = address
        self.phone = phone; self.website = website; self.facts = facts; self.assumptions = assumptions
        self.score = score; self.relevance = relevance; self.scoreReasons = scoreReasons
        self.status = status; self.externalResults = externalResults
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(LeadKind.self, forKey: .kind)) ?? .order
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        externalId = (try? c.decode(String.self, forKey: .externalId)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        publishedAt = ISODate.parse(try? c.decodeIfPresent(String.self, forKey: .publishedAt))
        discoveredAt = ISODate.parse(try? c.decodeIfPresent(String.self, forKey: .discoveredAt))
        budget = try? c.decodeIfPresent(Double.self, forKey: .budget)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        region = try? c.decodeIfPresent(String.self, forKey: .region)
        contacts = (try? c.decodeIfPresent([String: String].self, forKey: .contacts)) ?? [:]
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        projectType = try? c.decodeIfPresent(String.self, forKey: .projectType)
        customerName = try? c.decodeIfPresent(String.self, forKey: .customerName)
        address = try? c.decodeIfPresent(String.self, forKey: .address)
        phone = try? c.decodeIfPresent(String.self, forKey: .phone)
        website = try? c.decodeIfPresent(String.self, forKey: .website)
        facts = (try? c.decodeIfPresent([String].self, forKey: .facts)) ?? []
        assumptions = (try? c.decodeIfPresent([String].self, forKey: .assumptions)) ?? []
        score = (try? c.decodeIfPresent(Double.self, forKey: .score)) ?? 0
        relevance = (try? c.decodeIfPresent(Relevance.self, forKey: .relevance)) ?? .rejected
        scoreReasons = (try? c.decodeIfPresent([String].self, forKey: .scoreReasons)) ?? []
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "new"
        externalResults = (try? c.decodeIfPresent([ExternalResult].self, forKey: .externalResults)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(source, forKey: .source)
        try c.encode(externalId, forKey: .externalId)
        try c.encode(title, forKey: .title)
        try c.encode(url, forKey: .url)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(ISODate.format(publishedAt), forKey: .publishedAt)
        try c.encodeIfPresent(ISODate.format(discoveredAt), forKey: .discoveredAt)
        try c.encodeIfPresent(budget, forKey: .budget)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(region, forKey: .region)
        try c.encode(contacts, forKey: .contacts)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(projectType, forKey: .projectType)
        try c.encodeIfPresent(customerName, forKey: .customerName)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encodeIfPresent(phone, forKey: .phone)
        try c.encodeIfPresent(website, forKey: .website)
        try c.encode(facts, forKey: .facts)
        try c.encode(assumptions, forKey: .assumptions)
        try c.encode(score, forKey: .score)
        try c.encode(relevance, forKey: .relevance)
        try c.encode(scoreReasons, forKey: .scoreReasons)
        try c.encode(status, forKey: .status)
        try c.encode(externalResults, forKey: .externalResults)
    }

    /// Домен сайта без протокола и www (для исключений и дедупликации).
    public var domain: String? {
        guard let website, !website.isEmpty else { return nil }
        return Normalize.domain(website)
    }

    /// Все email из контактов.
    public var emails: [String] {
        contacts.values.filter { $0.contains("@") && $0.contains(".") && !$0.hasPrefix("@") }
    }

    /// Все телефоны: поле phone и контакты.
    public var phones: [String] {
        var out: [String] = []
        if let phone, !phone.isEmpty { out.append(phone) }
        for (k, v) in contacts where k.lowercased().contains("phone") || k.contains("тел") {
            if !out.contains(v) { out.append(v) }
        }
        return out
    }
}

/// Лид в локальной базе: данные конвейера + то, что пользователь сделал в приложении.
public struct LeadItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var data: LeadData
    public var discoveredAt: Date
    public var favorite: Bool
    public var archived: Bool
    public var excluded: Bool
    public var seen: Bool
    public var note: String

    public init(id: String, data: LeadData, discoveredAt: Date, favorite: Bool = false, archived: Bool = false,
                excluded: Bool = false, seen: Bool = false, note: String = "") {
        self.id = id; self.data = data; self.discoveredAt = discoveredAt; self.favorite = favorite
        self.archived = archived; self.excluded = excluded; self.seen = seen; self.note = note
    }

    // Ключи для сортировки в таблице.
    public var title: String { data.title }
    public var score: Double { data.score }
    public var source: String { data.source }
    public var kindTitle: String { data.kind.title }
    public var relevanceRank: Int { data.relevance.rank }
    public var regionText: String { data.region ?? "" }
    public var categoryText: String { data.category ?? data.projectType ?? "" }
    public var isNew: Bool { !seen }
}

/// Состояние источника, как его ведёт конвейер.
public struct SourceState: Identifiable, Hashable, Sendable {
    public var id: String { source }
    public var source: String
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var consecutiveFailures: Int
    public var status: String
    public var lastError: String?

    public init(source: String, lastSuccessAt: Date?, lastAttemptAt: Date?, consecutiveFailures: Int,
                status: String, lastError: String?) {
        self.source = source; self.lastSuccessAt = lastSuccessAt; self.lastAttemptAt = lastAttemptAt
        self.consecutiveFailures = consecutiveFailures; self.status = status; self.lastError = lastError
    }
}

/// Ошибка из журнала конвейера.
public struct PipelineError: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var at: Date?
    public var module: String
    public var message: String
}

/// Правило исключения.
public enum ExclusionKind: String, CaseIterable, Codable, Sendable {
    case domain, phone, email, name

    public var title: String {
        switch self {
        case .domain: return "Домен"
        case .phone: return "Телефон"
        case .email: return "Email"
        case .name: return "Название"
        }
    }
}

public struct Exclusion: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: ExclusionKind
    public var value: String
    public var createdAt: Date?
}

/// Запись журнала синхронизации.
public struct SyncLogEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var at: Date?
    public var ok: Bool
    public var added: Int
    public var updated: Int
    public var message: String
}

/// Событие истории лида.
public struct LeadEvent: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var at: Date?
    public var action: String
}

/// Итог импорта состояния.
public struct ImportResult: Sendable, Equatable {
    public var added: Int
    public var updated: Int
    public var sources: Int
    public init(added: Int, updated: Int, sources: Int) {
        self.added = added; self.updated = updated; self.sources = sources
    }
}
