import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Небольшая обёртка над NSRegularExpression.
struct Rx {
    let re: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // Шаблоны заданы в коде, поэтому ошибка компиляции — это ошибка программы.
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    private func ns(_ s: String) -> NSRange { NSRange(s.startIndex..<s.endIndex, in: s) }

    func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: ns(s)) != nil }

    /// Группы первого совпадения: [0] — всё совпадение.
    func first(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: ns(s)) else { return nil }
        return Self.groups(m, s)
    }

    func all(_ s: String) -> [[String?]] {
        re.matches(in: s, range: ns(s)).map { Self.groups($0, s) }
    }

    func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: ns(s), withTemplate: template)
    }

    func fullMatch(_ s: String) -> Bool {
        guard let m = re.firstMatch(in: s, options: [.anchored], range: ns(s)) else { return false }
        return m.range.length == (s as NSString).length
    }

    private static func groups(_ m: NSTextCheckingResult, _ s: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}

public enum SearchText {
    private static let urlRx = Rx(#"https?://\S+"#)
    private static let punctRx = Rx(#"[^\w\s]"#)
    private static let spaceRx = Rx(#"\s+"#)

    /// Как `normalize_text` в Python: регистр, «ё», без ссылок и пунктуации.
    public static func normalize(_ text: String) -> String {
        var t = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        t = urlRx.replace(t, with: " ")
        t = punctRx.replace(t, with: " ")
        t = spaceRx.replace(t, with: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Быстрый предфильтр по ключевым словам (подстрока). Пустой список пропускает всё.
    public static func prefilter(_ text: String, _ keywords: [String]) -> Bool {
        let words = keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        let low = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        return words.contains { low.contains($0.lowercased().replacingOccurrences(of: "ё", with: "е")) }
    }

    // MARK: HTML

    private static let scriptRx = Rx(#"<(script|style)\b[^>]*>.*?</\1\s*>"#, [.caseInsensitive, .dotMatchesLineSeparators])
    private static let brRx = Rx(#"<br\s*/?>|</p\s*>|</div\s*>|</li\s*>"#, [.caseInsensitive])
    private static let tagRx = Rx(#"<[^>]*>"#)
    private static let entityRx = Rx(#"&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)

    /// HTML в текст. `lines: true` — переносы строк сохраняются (посты Telegram),
    /// иначе всё в одну строку (RSS).
    public static func htmlToText(_ html: String, lines: Bool = false) -> String {
        var s = scriptRx.replace(html, with: " ")
        s = brRx.replace(s, with: lines ? "\n" : " ")
        s = tagRx.replace(s, with: lines ? "" : " ")
        s = decodeEntities(s)
        if lines {
            return s.components(separatedBy: "\n")
                .map { spaceRx.replace($0, with: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return spaceRx.replace(s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "laquo": "«", "raquo": "»",
        "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®", "trade": "™", "bull": "•",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "bdquo": "„", "times": "×", "deg": "°",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entityRx.re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            var rep: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                rep = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                rep = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                rep = named[body.lowercased()]
            }
            out += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Контакты

    private static let emailRx = Rx(#"[\w.+-]+@[\w-]+\.[\w.-]+"#)
    private static let phoneRx = Rx(#"(?:\+7|8)[\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2}"#)
    private static let tgRx = Rx(#"(?<![\w/])@([A-Za-z][A-Za-z0-9_]{4,31})\b|t\.me/([A-Za-z][A-Za-z0-9_]{4,31})"#)

    /// Только контакты, опубликованные в самом тексте. Ничего не додумываем.
    public static func contacts(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        if let m = emailRx.first(text), let e = m[0] {
            var v = e
            while v.hasSuffix(".") { v.removeLast() }
            out["email"] = v
        }
        if let m = phoneRx.first(text), let p = m[0] {
            out["phone"] = String(p.filter { $0.isNumber || $0 == "+" })
        }
        if let m = tgRx.first(text), let name = m[1] ?? m[2] {
            out["telegram"] = "@" + name
        }
        return out
    }

    // MARK: Идентификаторы

    /// Первые 24 символа SHA-256 в hex — так же, как в Python-версии.
    public static func shortHash(_ s: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(s.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
        #else
        #error("Для сборки без CryptoKit подключите swift-crypto")
        #endif
    }

    public static func leadId(source: String, externalId: String) -> String {
        shortHash("\(source)|\(externalId)")
    }

    private static let wwwRx = Rx(#"^(https?://)?(www\.)?"#)

    /// Отпечаток содержимого: одна и та же заявка или организация из разных мест.
    public static func fingerprint(_ d: LeadDataLike) -> String {
        if d.isOrganization {
            var domain = ""
            if let w = d.website, !w.isEmpty {
                domain = String(wwwRx.replace(w.lowercased(), with: "").split(separator: "/", omittingEmptySubsequences: false).first ?? "")
            }
            let phone = String((d.phone ?? "").filter(\.isNumber).suffix(10))
            let key = !domain.isEmpty ? domain : !phone.isEmpty ? phone
                : "\(normalize(d.title))|\(normalize(d.address ?? ""))"
            return shortHash("org|" + key)
        }
        let body = String(normalize("\(d.title) \(d.description)").prefix(400))
        return shortHash("order|" + body)
    }
}

/// Поля лида, нужные для отпечатка (чтобы не тянуть зависимость в утилиты).
public protocol LeadDataLike {
    var isOrganization: Bool { get }
    var title: String { get }
    var description: String { get }
    var website: String? { get }
    var phone: String? { get }
    var address: String? { get }
}
