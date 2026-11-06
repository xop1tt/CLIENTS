import Foundation

/// Даты в формате Python `datetime.isoformat()`: «2026-11-05T09:42:00+00:00», иногда с микросекундами.
public enum ISODate {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func parse(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let d = plain.date(from: s) ?? fractional.date(from: s) { return d }
        // Python без часового пояса: считаем UTC.
        if !s.contains("+") && !s.hasSuffix("Z") && s.count >= 19 { s += "Z" }
        // Микросекунды (6 знаков) ISO8601DateFormatter не понимает — обрезаем до миллисекунд.
        if let dot = s.firstIndex(of: ".") {
            let tail = s[s.index(after: dot)...]
            let digits = tail.prefix { $0.isNumber }
            let rest = tail.dropFirst(digits.count)
            s = String(s[..<dot]) + "." + String(digits.prefix(3)) + rest
        }
        return plain.date(from: s) ?? fractional.date(from: s)
    }

    public static func format(_ d: Date?) -> String? {
        guard let d else { return nil }
        return plain.string(from: d)
    }

    public static func now() -> String { plain.string(from: Date()) }
}

/// Нормализация значений для исключений и сравнения.
public enum Normalize {
    public static func domain(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<slash]) }
        return s
    }

    /// Последние 10 цифр телефона: +7 (843) 212-48-90 и 8 843 2124890 совпадают.
    public static func phone(_ raw: String) -> String {
        String(raw.filter(\.isNumber).suffix(10))
    }

    public static func email(_ raw: String) -> String {
        raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Название без кавычек, регистра, «ё» и лишних пробелов.
    public static func name(_ raw: String) -> String {
        let lowered = raw.lowercased().replacingOccurrences(of: "ё", with: "е")
        let cleaned = lowered.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    public static func value(_ raw: String, kind: ExclusionKind) -> String {
        switch kind {
        case .domain: return domain(raw)
        case .phone: return phone(raw)
        case .email: return email(raw)
        case .name: return name(raw)
        }
    }
}

/// Человекочитаемые названия источников и честные условия доступа.
public enum SourceCatalog {
    public struct Info: Sendable {
        public let title: String
        public let access: String
        public let note: String
    }

    public static let known: [String: Info] = [
        "fl_ru": Info(title: "FL.ru и RSS", access: "Бесплатно",
                      note: "Публичные RSS-ленты заказов: FL.ru и любые другие. Ленты хранят только последние записи."),
        "telegram_channels": Info(title: "Telegram-каналы", access: "Бесплатно",
                                  note: "Только публичные каналы с веб-превью t.me/s. Bot API чужие каналы не читает."),
        "vk_communities": Info(title: "VK-сообщества", access: "Бесплатный ключ",
                               note: "Нужен бесплатный сервисный ключ VK (dev.vk.com). Читаются стены выбранных сообществ."),
        "osm_organizations": Info(title: "OpenStreetMap", access: "Бесплатно",
                                  note: "Overpass API, данные ODbL (© участники OpenStreetMap). Полнота в РФ ниже, чем у Яндекса и 2ГИС."),
        "site_checker": Info(title: "Проверка сайтов", access: "Бесплатно",
                             note: "Один запрос к главной странице: доступность, HTTPS, мобильная вёрстка, год, онлайн-запись."),
    ]

    /// Источники, которые сознательно не подключены, с причиной.
    public static let unavailable: [(String, String)] = [
        ("Яндекс Карты", "Бесплатные условия запрещают сохранять данные."),
        ("2ГИС", "Бесплатно только демо-ключ на 1 месяц."),
        ("Поисковые системы", "Официальные API платные или закрыты для новых клиентов."),
        ("Kwork, Habr Freelance", "Нет API и RSS, robots.txt запрещает автоматический сбор."),
    ]

    public static func title(_ key: String) -> String {
        if let info = known[key] { return info.title }
        if key == "import" { return "Импорт" }
        return key
    }
}
