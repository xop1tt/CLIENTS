import Foundation

extension KeyedDecodingContainer {
    /// Значение или значение по умолчанию: новые поля не сбрасывают сохранённые настройки.
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// Ключи источников. Совпадают с ключами Python-версии, чтобы старые лиды оставались привязаны к источникам.
public enum SourceKey {
    public static let rss = "fl_ru"
    public static let telegram = "telegram_channels"
    public static let vk = "vk_communities"
    public static let osm = "osm_organizations"
    public static let all = [rss, telegram, vk, osm]
}

/// RSS/Atom-ленты (FL.ru и любые другие публичные ленты заказов).
public struct FeedSourceSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var intervalHours: Double = 2
    public var feeds: [String] = ["https://www.fl.ru/rss/all.xml"]
    /// Пусто — в оценку идут все записи.
    public var keywords: [String] = []

    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, intervalHours, feeds, keywords }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.v(.enabled, d.enabled); intervalHours = c.v(.intervalHours, d.intervalHours)
        feeds = c.v(.feeds, d.feeds); keywords = c.v(.keywords, d.keywords)
    }
}

/// Публичные Telegram-каналы через веб-превью t.me/s/<канал>.
public struct TelegramSourceSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var intervalHours: Double = 3
    public var channels: [String] = ["teleworko", "vacanciesbest", "freetasks", "theyseeku"]
    public var maxPages = 3
    public var keywords: [String] = SearchDefaults.orderKeywords

    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, intervalHours, channels, maxPages, keywords }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.v(.enabled, d.enabled); intervalHours = c.v(.intervalHours, d.intervalHours)
        channels = c.v(.channels, d.channels); maxPages = c.v(.maxPages, d.maxPages); keywords = c.v(.keywords, d.keywords)
    }
}

/// Открытые сообщества ВКонтакте (wall.get с бесплатным сервисным ключом).
public struct VKSourceSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var intervalHours: Double = 3
    public var communities: [String] = []
    public var pageSize = 50
    public var maxPages = 2
    public var keywords: [String] = ["сайт", "бот", "приложени", "разработ", "программист", "автоматизац", "crm", "парсер", "интеграц"]

    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, intervalHours, communities, pageSize, maxPages, keywords }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.v(.enabled, d.enabled); intervalHours = c.v(.intervalHours, d.intervalHours)
        communities = c.v(.communities, d.communities); pageSize = c.v(.pageSize, d.pageSize)
        maxPages = c.v(.maxPages, d.maxPages); keywords = c.v(.keywords, d.keywords)
    }
}

/// Категория организаций OpenStreetMap.
public struct OSMCategory: Codable, Hashable, Identifiable, Sendable {
    public var key: String
    public var label: String
    public var group: String
    public var filters: [String]
    public var enabled: Bool
    public var weight: Double
    public var id: String { key }

    public init(key: String, label: String, group: String, filters: [String], enabled: Bool = true, weight: Double = 10) {
        self.key = key; self.label = label; self.group = group; self.filters = filters
        self.enabled = enabled; self.weight = weight
    }
}

/// Организации из OpenStreetMap через Overpass API.
public struct OSMSourceSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var intervalHours: Double = 120
    public var regions: [String] = ["Ереван"]
    public var categories: [OSMCategory] = SearchDefaults.osmCategories
    public var checkWebsites = true
    /// Одинаковый запрос регион × категория не чаще, чем раз в N дней.
    public var refreshDays: Double = 7
    /// Повторная проверка уже известной организации.
    public var recheckDays: Double = 60
    public var maxNewPerRun = 40
    public var endpoint = "https://overpass-api.de/api/interpreter"

    public init() {}
    enum CodingKeys: String, CodingKey {
        case enabled, intervalHours, regions, categories, checkWebsites, refreshDays, recheckDays, maxNewPerRun, endpoint
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.v(.enabled, d.enabled); intervalHours = c.v(.intervalHours, d.intervalHours)
        regions = c.v(.regions, d.regions); categories = c.v(.categories, d.categories)
        checkWebsites = c.v(.checkWebsites, d.checkWebsites); refreshDays = c.v(.refreshDays, d.refreshDays)
        recheckDays = c.v(.recheckDays, d.recheckDays); maxNewPerRun = c.v(.maxNewPerRun, d.maxNewPerRun)
        endpoint = c.v(.endpoint, d.endpoint)
    }
}

/// Все настройки поиска пользователя. Хранятся в его базе как JSON — тот же JSON сможет читать сервер.
public struct SearchSettings: Codable, Equatable, Sendable {
    public var rss = FeedSourceSettings()
    public var telegram = TelegramSourceSettings()
    public var vk = VKSourceSettings()
    public var osm = OSMSourceSettings()

    public init() {}
    enum CodingKeys: String, CodingKey { case rss, telegram, vk, osm }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rss = c.v(.rss, FeedSourceSettings()); telegram = c.v(.telegram, TelegramSourceSettings())
        vk = c.v(.vk, VKSourceSettings()); osm = c.v(.osm, OSMSourceSettings())
    }

    public func isEnabled(_ key: String) -> Bool {
        switch key {
        case SourceKey.rss: return rss.enabled
        case SourceKey.telegram: return telegram.enabled
        case SourceKey.vk: return vk.enabled
        case SourceKey.osm: return osm.enabled
        default: return false
        }
    }

    public func intervalHours(_ key: String) -> Double {
        switch key {
        case SourceKey.rss: return rss.intervalHours
        case SourceKey.telegram: return telegram.intervalHours
        case SourceKey.vk: return vk.intervalHours
        case SourceKey.osm: return osm.intervalHours
        default: return 24
        }
    }

    public static func decode(_ json: String?) -> SearchSettings {
        guard let json, let s = try? JSONDecoder().decode(SearchSettings.self, from: Data(json.utf8)) else { return SearchSettings() }
        return s
    }

    public func encoded() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Секреты, которые нужны источникам. Хранит их приложение (Связка ключей), а не настройки.
public struct SearchSecrets: Sendable {
    public var vkToken: String?
    public init(vkToken: String? = nil) { self.vkToken = vkToken }
}

public enum SearchDefaults {
    public static let orderKeywords = [
        "сайт", "бот", "приложени", "разработ", "программист", "автоматизац", "crm", "срм", "парсер", "интеграц",
        "лендинг", "верстк", "доработ", "интернет-магазин", "telegram", "телеграм", "python", "api",
    ]

    public static let osmCategories: [OSMCategory] = [
        OSMCategory(key: "beauty", label: "Салоны красоты", group: "beauty",
                    filters: [#"["shop"="beauty"]"#, #"["shop"="hairdresser"]"#], weight: 20),
        OSMCategory(key: "dance", label: "Танцевальные студии", group: "dance",
                    filters: [#"["leisure"="dance"]"#, #"["amenity"="dancing_school"]"#], weight: 20),
        OSMCategory(key: "restaurant", label: "Рестораны", group: "restaurant",
                    filters: [#"["amenity"="restaurant"]"#], weight: 12),
        OSMCategory(key: "cafe", label: "Кафе", group: "restaurant", filters: [#"["amenity"="cafe"]"#], weight: 10),
        OSMCategory(key: "education", label: "Образовательные центры", group: "education",
                    filters: [#"["amenity"="language_school"]"#, #"["amenity"="training"]"#, #"["amenity"="music_school"]"#], weight: 15),
        OSMCategory(key: "medical", label: "Медицина и косметология", group: "medical",
                    filters: [#"["amenity"="dentist"]"#, #"["healthcare"="clinic"]"#, #"["amenity"="clinic"]"#], weight: 15),
        OSMCategory(key: "fitness", label: "Спорт и фитнес", group: "fitness",
                    filters: [#"["leisure"="fitness_centre"]"#, #"["leisure"="sports_centre"]"#], weight: 15),
        OSMCategory(key: "shops", label: "Магазины", group: "shop",
                    filters: [#"["shop"="clothes"]"#, #"["shop"="gift"]"#, #"["shop"="florist"]"#], weight: 10),
    ]
}

/// Приведение того, что вводит пользователь, к виду, который понимает источник.
public enum SourceInput {
    private static let channelRx = Rx(#"^[A-Za-z][A-Za-z0-9_]{3,31}$"#)
    private static let vkRx = Rx(#"^[A-Za-z0-9_.]{2,64}$"#)

    /// «@name», «t.me/name», «https://t.me/s/name» → «name».
    public static func telegramChannel(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        for p in ["www.", "t.me/s/", "t.me/", "telegram.me/"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("@") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" }) { s = String(s[..<cut]) }
        return channelRx.matches(s) ? s : nil
    }

    /// «https://vk.com/name» → «name».
    public static func vkCommunity(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        for p in ["www.", "m.vk.com/", "vk.com/", "vk.ru/"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("@") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" }) { s = String(s[..<cut]) }
        return vkRx.matches(s) ? s : nil
    }

    /// Адрес ленты: только публичный http(s).
    public static func feedURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        return SiteChecker.isPublicHTTPURL(s) ? s : nil
    }

    public static func keyword(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.isEmpty ? nil : s
    }

    public static func region(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
        return s.isEmpty ? nil : s
    }

    /// Разбивает ввод на элементы: по запятым, точкам с запятой и строкам.
    public static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
