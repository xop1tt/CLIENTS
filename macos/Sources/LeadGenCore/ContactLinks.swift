import Foundation

/// Ссылки для звонка и письма из карточки лида: tel:, facetime-audio:, mailto:.
///
/// macOS сам решает, чем открыть ссылку: tel: открывает FaceTime (звонок с iPhone через
/// «Непрерывность» или по FaceTime Audio), mailto: — почтовую программу по умолчанию.
/// Только Foundation: собирается и на Linux.
public enum ContactLinks {
    /// Номер в виде, понятном системе: «+» и цифры. Добавочный номер отбрасывается.
    /// Российский номер «8 XXX…» (11 цифр) переводится в «+7 XXX…». Меньше 5 цифр — не номер.
    public static func normalizedPhone(_ raw: String) -> String? {
        var text = raw.lowercased()
        for marker in ["доб", "ext", "вн.", "#", ",", ";"] {
            if let r = text.range(of: marker) { text = String(text[..<r.lowerBound]) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plus = trimmed.hasPrefix("+")
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 5, digits.count <= 15 else { return nil }
        if !plus, digits.count == 11, digits.hasPrefix("8") { return "+7" + digits.dropFirst() }
        if !plus, digits.count == 11, digits.hasPrefix("7") { return "+" + digits }
        return (plus ? "+" : "") + digits
    }

    /// tel:+78430000000 — FaceTime на Mac предлагает позвонить через iPhone.
    public static func telURL(_ phone: String) -> URL? {
        normalizedPhone(phone).flatMap { URL(string: "tel:" + $0) }
    }

    /// facetime-audio:+78430000000 — аудиозвонок FaceTime сразу, без выбора.
    public static func faceTimeAudioURL(_ phone: String) -> URL? {
        normalizedPhone(phone).flatMap { URL(string: "facetime-audio:" + $0) }
    }

    /// Простая проверка адреса: одна «@», непустые части, точка в домене, без пробелов и
    /// управляющих символов (перевод строки в адресе открыл бы подстановку заголовков письма).
    public static func isEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count <= 254, !s.contains(where: { $0.isWhitespace || $0.isNewline || ("<>()[]\\,;:\"".contains($0)) }),
              !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
        return true
    }

    /// mailto:адрес?subject=…&body=… с кодированием по RFC 6068 (пробел — %20, перевод строки — %0D%0A).
    public static func mailtoURL(to address: String, subject: String = "", body: String = "") -> URL? {
        let to = address.trimmingCharacters(in: .whitespaces)
        guard isEmail(to) else { return nil }
        var query: [String] = []
        if !subject.isEmpty { query.append("subject=" + encode(subject)) }
        if !body.isEmpty { query.append("body=" + encode(normalizeNewlines(body))) }
        let addr = to.addingPercentEncoding(withAllowedCharacters: addressAllowed) ?? to
        return URL(string: "mailto:" + addr + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Только латиница, цифры и «-._~»: всё остальное, включая кириллицу и «&=+#», кодируется.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let addressAllowed = unreserved.union(CharacterSet(charactersIn: "@!$'*+"))

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
}

/// Письмо-черновик: тема отдельно от текста.
public struct EmailDraft: Equatable, Sendable {
    public var subject: String
    public var body: String
    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}

extension DraftWriter {
    /// Черновик письма: первая строка «Тема: …» шаблона становится темой.
    public static func email(for lead: LeadData, signature: String) -> EmailDraft {
        split(draft(for: lead, channel: .email, signature: signature))
    }

    /// Делит текст «Тема: …\n\nТекст» на тему и текст. Без строки темы тема пустая.
    public static func split(_ text: String) -> EmailDraft {
        let prefix = "Тема:"
        guard text.hasPrefix(prefix) else { return EmailDraft(subject: "", body: text) }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = lines[0].dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .newlines) : ""
        return EmailDraft(subject: subject, body: body)
    }
}
