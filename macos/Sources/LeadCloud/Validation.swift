import Foundation

/// Проверки на клиенте — для быстрых подсказок. Те же правила проверяет сервер.
public enum Validation {
    public static let passwordRules = "Пароль: не короче 8 символов, строчные и заглавные буквы и цифры."

    private static let emailRx = try! NSRegularExpression(pattern: #"^[^@\s<>()",;:]+@[^@\s<>()",;:]+\.[^@\s<>()",;:.]{2,}$"#)

    public static func normalizedEmail(_ raw: String) -> String? {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.count <= 254, emailRx.firstMatch(in: e, range: NSRange(e.startIndex..., in: e)) != nil else { return nil }
        return e
    }

    /// nil — пароль подходит, иначе — что исправить.
    public static func passwordProblem(_ p: String) -> String? {
        var missing: [String] = []
        if p.count < 8 { missing.append("не короче 8 символов") }
        if !p.contains(where: { $0.isLowercase }) { missing.append("строчная буква") }
        if !p.contains(where: { $0.isUppercase }) { missing.append("заглавная буква") }
        if !p.contains(where: { $0.isNumber }) { missing.append("цифра") }
        if p.count > 72 { return "Пароль не длиннее 72 символов." }
        return missing.isEmpty ? nil : "В пароле нужно: " + missing.joined(separator: ", ") + "."
    }

    public static func code(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        return (6...10).contains(digits.count) ? digits : nil
    }
}
