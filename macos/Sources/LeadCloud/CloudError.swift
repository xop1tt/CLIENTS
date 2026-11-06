import Foundation

/// Ошибки облака с понятными сообщениями. Текст не раскрывает, существует ли аккаунт.
public enum CloudError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case network(String)
    case invalidEmail
    case weakPassword(String?)
    case passwordsDiffer
    case invalidCredentials
    case emailNotConfirmed
    case emailExists
    case invalidCode
    case samePassword
    case rateLimited(String)
    case mailUnavailable
    case sessionExpired
    case reauthRequired
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Облако не настроено: в этой сборке нет адреса сервера."
        case .network: return "Нет соединения с сервером. Проверьте интернет — данные на этом Mac доступны и без сети."
        case .invalidEmail: return "Проверьте адрес электронной почты."
        case .weakPassword(let m): return m ?? Validation.passwordRules
        case .passwordsDiffer: return "Пароли не совпадают."
        case .invalidCredentials: return "Неверный адрес почты или пароль."
        case .emailNotConfirmed: return "Адрес почты ещё не подтверждён. Введите код из письма."
        case .emailExists: return "Этот адрес уже используется другой учётной записью."
        case .invalidCode: return "Код неверный или устарел. Запросите новое письмо."
        case .samePassword: return "Новый пароль совпадает с текущим."
        case .rateLimited(let m): return m
        case .mailUnavailable: return "Не удалось отправить письмо: почтовый сервис недоступен или исчерпан лимит. Попробуйте позже."
        case .sessionExpired: return "Сессия завершена. Войдите снова."
        case .reauthRequired: return "Введите пароль ещё раз."
        case .server(let m): return "Ошибка сервера: \(m)"
        }
    }

    /// Разбор ответа Supabase Auth: {"code":400,"error_code":"…","msg":"…"} или {"error":"…","error_description":"…"}.
    static func fromAuth(status: Int, data: Data) -> CloudError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (obj["error_code"] as? String) ?? (obj["error"] as? String) ?? ""
        let msg = (obj["msg"] as? String) ?? (obj["error_description"] as? String) ?? (obj["message"] as? String) ?? ""
        switch code {
        case "invalid_credentials": return .invalidCredentials
        case "invalid_grant" where msg.lowercased().contains("credentials"): return .invalidCredentials
        case "email_not_confirmed": return .emailNotConfirmed
        case "weak_password": return .weakPassword(nil)
        case "email_exists", "user_already_exists", "conflict": return .emailExists
        case "email_address_invalid", "validation_failed": return .invalidEmail
        case "otp_expired", "otp_disabled", "bad_code_verifier": return .invalidCode
        case "same_password": return .samePassword
        case "over_email_send_rate_limit", "over_request_rate_limit":
            return .rateLimited("Слишком много попыток. Подождите немного и повторите.")
        case "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired",
             "user_not_found", "bad_jwt", "no_authorization":
            return .sessionExpired
        case "reauthentication_needed", "reauthentication_not_valid": return .reauthRequired
        default: break
        }
        if status == 429 { return .rateLimited("Слишком много попыток. Подождите немного и повторите.") }
        if msg.contains("hook") { return .mailUnavailable }
        if status == 401 || status == 403 { return .sessionExpired }
        return .server(msg.isEmpty ? "HTTP \(status)" : String(msg.prefix(200)))
    }
}
