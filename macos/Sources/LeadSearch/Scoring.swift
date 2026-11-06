import Foundation
import LeadGenCore

/// Правила оценки. Значения по умолчанию совпадают с config.yaml Python-версии.
public struct OrderScoring: Sendable {
    public var maxAgeDays: Double = 14
    public var minBudgetRub: Double = 3000
    public var high: Double = 65, medium: Double = 45, low: Double = 25
    public var wTopic: Double = 30, wIntent: Double = 20, wOfferPenalty: Double = 35, wBudget: Double = 15
    public var wLowBudgetPenalty: Double = 10, wUrgency: Double = 5, wCompleteness: Double = 10
    public var wTooShortPenalty: Double = 10, wCustomerType: Double = 5, wFeasibility: Double = 5
    public var wFeasibilityPenalty: Double = 15, wSpamPenalty: Double = 40, wFreshness: Double = 10

    public var projectTypes: [(String, [String])] = [
        ("site", ["сайт", "лендинг", "landing", "интернет-магазин", "wordpress", "tilda", "тильда", "битрикс", "верстк", "одностраничник"]),
        ("telegram_bot", ["телеграм бот", "telegram бот", "телеграм-бот", "telegram-бот", "бот для телеграм", "бот в телеграм",
                          "чат-бот", "чат бот", "tg бот", "aiogram", "бота"]),
        ("mobile_app", ["мобильное приложение", "мобильного приложения", "приложение для ios", "приложение для android",
                        "flutter", "react native", "android", "ios"]),
        ("web_app", ["веб-приложение", "веб приложение", "web-приложение", "веб-сервис", "личный кабинет", "react", "vue",
                     "django", "fastapi", "nextjs", "next js"]),
        ("automation", ["автоматизац", "парсер", "парсинг", "скрипт", "интеграц", "api", "google таблиц", "google sheets",
                        "webhook", "n8n", "zapier"]),
        ("crm", ["crm", "срм", "amocrm", "битрикс24", "учетн систем", "внутренн систем", "erp"]),
        ("support", ["доработ", "исправить", "баг", "модерниз", "редизайн", "поддержка сайта", "перенести сайт"]),
    ]
    public var intent = ["ищу", "ищем", "нужен", "нужна", "нужно", "требуется", "требуются", "кто может", "кто сделает",
                         "кто возьмется", "хочу заказать", "заказать", "техническое задание", "тз"]
    public var offers = ["сделаю", "разработаю", "создам", "предлагаю услуги", "мои услуги", "ищу заказы", "ищу заказчиков",
                         "беру заказы", "возьму заказ", "мое портфолио", "моё портфолио"]
    public var stopWords = ["в штат", "оклад", "полный рабочий день", "резюме", "стажировк", "казино", "ставки на спорт",
                            "букмекер", "закладк", "обнал", "накрутк", "без оплаты", "за отзыв", "даркнет", "взлом", "18+"]
    public var spam = ["заработок от", "доход от", "пассивный доход", "подписывайся", "розыгрыш", "промокод",
                       "арбитраж трафика", "реферал"]
    public var urgency = ["срочно", "сегодня", "до завтра", "в кратчайшие сроки", "asap", "горит"]
    public var business = ["компания", "компании", "ооо", "бизнес", "магазин", "студия", "салон", "клиника", "ресторан",
                           "школа", "агентство", "производство"]
    public var hard = ["1с", "1c", "unity", "unreal", "микроконтроллер", "arduino", "embedded", "fpga", "plc", "solidity",
                       "смарт-контракт", "в офис"]

    public init() {}
}

public struct OrganizationScoring: Sendable {
    public var high: Double = 60, medium: Double = 40, low: Double = 25
    public var base: Double = 10
    public var signals: [(String, String, Double)] = [
        ("no_website", "сайт не указан в источнике", 35),
        ("site_unreachable", "сайт недоступен", 30),
        ("no_https", "нет HTTPS", 10),
        ("no_viewport", "нет мобильной вёрстки (meta viewport)", 15),
        ("outdated", "сайт выглядит устаревшим", 15),
        ("no_booking", "нет онлайн-записи (предположение о потребности)", 10),
    ]
    public var hasContacts: Double = 10
    public var noContactsPenalty: Double = 20
    public init() {}
}

/// Собственная оценка без AI: ключевые слова и веса. Это оценка системы, а не факт.
public final class Scorer {
    public let orders: OrderScoring
    public let organizations: OrganizationScoring
    private var cache: [String: Rx] = [:]

    public init(orders: OrderScoring = OrderScoring(), organizations: OrganizationScoring = OrganizationScoring()) {
        self.orders = orders; self.organizations = organizations
    }

    static func classify(_ score: Double, high: Double, medium: Double, low: Double) -> Relevance {
        score >= high ? .high : score >= medium ? .medium : score >= low ? .low : .rejected
    }

    /// Слова, найденные в нормализованном тексте (по началу слова).
    func containsAny(_ text: String, _ words: [String]) -> [String] {
        words.filter { w in
            let wn = SearchText.normalize(w)
            guard !wn.isEmpty else { return false }
            let rx: Rx
            if let c = cache[wn] { rx = c } else {
                rx = Rx(#"(?<!\w)"# + NSRegularExpression.escapedPattern(for: wn))
                cache[wn] = rx
            }
            return rx.matches(text)
        }
    }

    private static func pts(_ v: Double) -> String { String(format: "%.0f", v) }

    public func scoreOrder(_ lead: inout LeadData, now: Date = Date()) {
        let o = orders
        let text = SearchText.normalize("\(lead.title) \(lead.description)")
        var reasons: [String] = []
        var total = 0.0

        let stop = containsAny(text, o.stopWords)
        if !stop.isEmpty {
            lead.score = 0; lead.relevance = .rejected
            lead.scoreReasons = ["стоп-слова: \(stop.prefix(3).joined(separator: ", "))"]
            return
        }

        // 1. Тематика разработки и тип проекта
        var bestType: String?
        var bestHits = 0
        for (type, words) in o.projectTypes {
            let hits = containsAny(text, words).count
            if hits > bestHits { bestType = type; bestHits = hits }
        }
        guard let bestType, bestHits > 0 else {
            lead.score = 0; lead.relevance = .rejected
            lead.scoreReasons = ["нет признаков разработки"]
            return
        }
        if lead.projectType == nil { lead.projectType = bestType }
        let topic = o.wTopic * min(1.0, 0.6 + 0.2 * Double(bestHits))
        total += topic
        reasons.append("тематика «\(bestType)» (+\(Self.pts(topic)))")

        // 2. Конкретный запрос
        if let first = containsAny(text, o.intent).first {
            total += o.wIntent
            reasons.append("явный запрос: «\(first)» (+\(Self.pts(o.wIntent)))")
        }
        if !containsAny(text, o.offers).isEmpty {
            total -= o.wOfferPenalty
            reasons.append("похоже на предложение услуг, а не заказ")
        }

        // 3. Бюджет
        if lead.budget == nil, let b = Budget.parse("\(lead.title) \(lead.description)") {
            lead.budget = b.value; lead.currency = b.currency
        }
        if let budget = lead.budget, budget > 0 {
            total += o.wBudget
            reasons.append("указан бюджет (+\(Self.pts(o.wBudget)))")
            if lead.currency == "RUB", o.minBudgetRub > 0, budget < o.minBudgetRub {
                total -= o.wLowBudgetPenalty
                reasons.append("бюджет ниже \(Self.pts(o.minBudgetRub)) ₽")
            }
        }

        // 4. Срочность
        if !containsAny(text, o.urgency).isEmpty { total += o.wUrgency; reasons.append("срочно") }

        // 5. Полнота описания
        let words = text.split(separator: " ").count
        if words >= 40 { total += o.wCompleteness; reasons.append("подробное описание") }
        else if words < 8 { total -= o.wTooShortPenalty; reasons.append("слишком короткое описание") }

        // 6. Тип заказчика
        if !containsAny(text, o.business).isEmpty { total += o.wCustomerType; reasons.append("заказчик — бизнес") }

        // 7. Выполнимость силами одного разработчика
        if let h = containsAny(text, o.hard).first {
            total -= o.wFeasibilityPenalty
            reasons.append("сложно выполнить удалённо/в одиночку: \(h)")
        } else {
            total += o.wFeasibility
        }

        // 8. Спам
        let links = lead.description.components(separatedBy: "http://").count + lead.description.components(separatedBy: "https://").count - 2
        if !containsAny(text, o.spam).isEmpty || links > 5 {
            total -= o.wSpamPenalty
            reasons.append("признаки спама")
        }

        // 9. Свежесть
        if let published = lead.publishedAt {
            let age = now.timeIntervalSince(published)
            if age > o.maxAgeDays * 86400 {
                lead.score = 0; lead.relevance = .rejected
                lead.scoreReasons = reasons + ["устарело"]
                return
            }
            if age <= 86400 { total += o.wFreshness; reasons.append("свежая публикация") }
        }

        lead.score = (max(0, min(100, total)) * 10).rounded() / 10
        lead.relevance = Self.classify(lead.score, high: o.high, medium: o.medium, low: o.low)
        lead.scoreReasons = reasons
    }

    /// Организация: опирается только на проверенные сигналы из проверки сайта.
    public func scoreOrganization(_ lead: inout LeadData, categoryWeight: Double?, signals: [String: Bool]) {
        let g = organizations
        var reasons: [String] = []
        var total = categoryWeight ?? g.base
        reasons.append("категория «\(lead.category ?? "—")» (+\(Self.pts(total)))")
        for (key, label, w) in g.signals where signals[key] == true {
            total += w
            reasons.append("\(label) (+\(Self.pts(w)))")
        }
        if !(lead.phone ?? "").isEmpty || !lead.contacts.isEmpty {
            total += g.hasContacts
            reasons.append("есть публичный контакт")
        } else {
            total -= g.noContactsPenalty
            reasons.append("нет контактов")
        }
        lead.score = (max(0, min(100, total)) * 10).rounded() / 10
        lead.relevance = Self.classify(lead.score, high: g.high, medium: g.medium, low: g.low)
        lead.scoreReasons = reasons
    }
}

/// Бюджет в тексте заказа.
public enum Budget {
    static let num = #"(\d[\d\s.,]*\d|\d)"#
    static let withCurrency = Rx(num + #"\s*(тыс\.?|тысяч|к|k|млн)?\s*(руб(?:лей|\.|ля)?|р\.|₽|rub|\$|usd|долл\w*|€|eur)"#, [.caseInsensitive])
    static let withPrefix = Rx(#"бюджет[:\s—-]*(?:до|от|около)?\s*"# + num + #"\s*(тыс\.?|тысяч|к|k|млн)?"#, [.caseInsensitive])
    static let thousands = Rx(#"\d{1,3}([.,]\d{3})+"#)

    static func number(_ raw: String, _ mult: String?) -> Double? {
        var s = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00a0}", with: "")
            .filter { !$0.isWhitespace }
        if thousands.fullMatch(s) {
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
        } else {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        guard var value = Double(s) else { return nil }
        var m = (mult ?? "").lowercased()
        while m.hasSuffix(".") { m.removeLast() }
        if ["тыс", "тысяч", "к", "k"].contains(m) { value *= 1000 } else if m == "млн" { value *= 1_000_000 }
        return value
    }

    public static func parse(_ text: String) -> (value: Double, currency: String)? {
        if let m = withCurrency.first(text), let raw = m[1], let cur = m[3]?.lowercased() {
            let currency: String
            switch cur {
            case "$", "usd": currency = "USD"
            case "€", "eur": currency = "EUR"
            default: currency = cur.hasPrefix("долл") ? "USD" : "RUB"
            }
            if let v = number(raw, m[2]), v > 0, v >= 100 || currency != "RUB" { return (v, currency) }
        }
        if let m = withPrefix.first(text), let raw = m[1], let v = number(raw, m[2]), v >= 100 {
            return (v, "RUB")
        }
        return nil
    }
}
