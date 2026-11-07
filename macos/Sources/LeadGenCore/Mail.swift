import Foundation

// Отправка писем прямо из приложения по SMTP. Протокол и сборка письма здесь, только на
// Foundation (собирается и на Linux, проверяется тестами с поддельным соединением); само
// TLS-соединение открывает приложение (URLSessionStreamTask, см. SMTPStreamTransport).

/// Почтовый сервис: готовые настройки SMTP и где взять пароль приложения.
public enum MailProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case gmail, yandex, mailru, icloud, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .yandex: return "Яндекс Почта"
        case .mailru: return "Почта Mail.ru"
        case .icloud: return "iCloud Почта"
        case .custom: return "Другой сервер (SMTP)"
        }
    }

    public var host: String {
        switch self {
        case .gmail: return "smtp.gmail.com"
        case .yandex: return "smtp.yandex.ru"
        case .mailru: return "smtp.mail.ru"
        case .icloud: return "smtp.mail.me.com"
        case .custom: return ""
        }
    }

    public var port: Int { self == .icloud ? 587 : 465 }
    public var security: MailSecurity { self == .icloud ? .startTLS : .tls }

    /// Страница, где создаётся пароль приложения (обычный пароль сервисы по SMTP не принимают).
    public var appPasswordPage: URL? {
        switch self {
        case .gmail: return URL(string: "https://myaccount.google.com/apppasswords")
        case .yandex: return URL(string: "https://id.yandex.ru/security/app-passwords")
        case .mailru: return URL(string: "https://account.mail.ru/user/2-step-auth/passwords/")
        case .icloud: return URL(string: "https://account.apple.com/account/manage")
        case .custom: return nil
        }
    }

    public var hint: String {
        switch self {
        case .gmail: return "Нужна двухэтапная аутентификация и пароль приложения из 16 букв."
        case .yandex: return "Создайте пароль приложения для «Почты» и включите доступ по протоколам в настройках Яндекс Почты."
        case .mailru: return "Создайте пароль для внешнего приложения в настройках безопасности Mail.ru."
        case .icloud: return "Создайте пароль приложения в настройках Apple ID. Логин — адрес @icloud.com."
        case .custom: return "Адрес SMTP-сервера и порт даёт ваш почтовый сервис. 465 — TLS, 587 — STARTTLS."
        }
    }

    /// Сервис по домену адреса, иначе «другой сервер».
    public static func detect(_ email: String) -> MailProvider {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return .gmail
        case "yandex.ru", "ya.ru", "yandex.com", "yandex.by", "yandex.kz", "narod.ru": return .yandex
        case "mail.ru", "inbox.ru", "list.ru", "bk.ru", "internet.ru": return .mailru
        case "icloud.com", "me.com", "mac.com": return .icloud
        default: return .custom
        }
    }
}

/// Шифрование соединения. Без шифрования приложение не отправляет: пароль ушёл бы открытым текстом.
public enum MailSecurity: String, CaseIterable, Identifiable, Codable, Sendable {
    /// TLS с первого байта (обычно порт 465).
    case tls
    /// Открытое соединение, затем обязательная команда STARTTLS (обычно порт 587).
    case startTLS
    public var id: String { rawValue }
    public var title: String { self == .tls ? "TLS (465)" : "STARTTLS (587)" }
}

/// Как отправлять письма из окна «Написать».
public enum MailDelivery: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Письмо открывается в программе «Почта» (или другой по умолчанию): она хранит отправленные.
    case mailApp
    /// Отправка прямо из приложения по SMTP.
    case smtp
    public var id: String { rawValue }
    public var title: String { self == .mailApp ? "Через программу «Почта»" : "Прямо из приложения (SMTP)" }
}

/// Настройки почтового ящика без пароля. Пароль приложения лежит в Связке ключей.
public struct MailAccount: Codable, Equatable, Sendable {
    public var provider: MailProvider
    public var host: String
    public var port: Int
    public var security: MailSecurity
    public var username: String
    public var fromAddress: String
    public var fromName: String
    /// Скрытая копия себе: письмо попадает и в свой ящик (так оно видно в «Почте» на всех устройствах).
    public var copyToSelf: Bool

    public init(provider: MailProvider = .custom, host: String = "", port: Int = 465, security: MailSecurity = .tls,
                username: String = "", fromAddress: String = "", fromName: String = "", copyToSelf: Bool = true) {
        self.provider = provider
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.copyToSelf = copyToSelf
    }

    /// Готовые настройки сервиса по адресу.
    public static func preset(for email: String, name: String = "") -> MailAccount {
        let p = MailProvider.detect(email)
        return MailAccount(provider: p, host: p.host, port: p == .custom ? 465 : p.port, security: p.security,
                           username: email, fromAddress: email, fromName: name)
    }

    /// Текст ошибки, если настройки неполные; nil — можно отправлять.
    public var problem: String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty || h.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) { return "Укажите адрес SMTP-сервера" }
        if !(1...65535).contains(port) { return "Неверный порт" }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "Укажите логин" }
        if !ContactLinks.isEmail(fromAddress) { return "Укажите адрес отправителя" }
        if fromName.contains(where: \.isNewline) { return "Имя отправителя не должно содержать переводов строки" }
        return nil
    }

    public func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func decode(_ text: String?) -> MailAccount? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MailAccount.self, from: data)
    }
}

/// Письмо: один получатель, простой текст в UTF-8.
public struct OutgoingMail: Equatable, Sendable {
    public var to: String
    public var subject: String
    public var body: String
    public init(to: String, subject: String, body: String) {
        self.to = to
        self.subject = subject
        self.body = body
    }
}

public enum MailError: Error, Equatable, LocalizedError, Sendable {
    case invalidRecipient
    case invalidAccount(String)
    case emptyMessage
    case noPassword
    /// Сервер не предложил STARTTLS: пароль открытым текстом не отправляем.
    case tlsUnavailable
    case authUnsupported
    /// Ответ сервера с кодом ошибки на шаге stage.
    case server(code: Int, message: String, stage: String)
    case badReply(String)
    case connection(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRecipient: return "Неверный адрес получателя"
        case .invalidAccount(let s): return s
        case .emptyMessage: return "Пустое письмо: добавьте тему или текст"
        case .noPassword: return "Не задан пароль приложения для почты (Настройки → Обращения)"
        case .tlsUnavailable: return "Сервер не поддерживает шифрование STARTTLS. Выберите TLS (порт 465)"
        case .authUnsupported: return "Сервер не поддерживает вход по логину и паролю (AUTH PLAIN / LOGIN)"
        case let .server(code, message, stage):
            if code == 535 || code == 534 || (stage == "AUTH" && code >= 500) {
                return "Почтовый сервер не принял логин или пароль. Нужен пароль приложения, а не обычный пароль. (\(code))"
            }
            if stage == "RCPT" { return "Сервер отклонил адрес получателя: \(message) (\(code))" }
            return "Почтовый сервер ответил ошибкой на шаге \(stage): \(message) (\(code))"
        case .badReply(let s): return "Непонятный ответ почтового сервера: \(s)"
        case .connection(let s): return "Не удалось связаться с почтовым сервером: \(s)"
        }
    }
}

// MARK: - Сборка письма (RFC 5322 + MIME)

public enum MIMEMessage {
    /// Письмо целиком, строки через CRLF, без завершающей точки DATA.
    public static func build(_ mail: OutgoingMail, from account: MailAccount, date: Date = Date(),
                             messageID: String = UUID().uuidString) throws -> String {
        let to = mail.to.trimmingCharacters(in: .whitespaces)
        guard ContactLinks.isEmail(to) else { throw MailError.invalidRecipient }
        if let p = account.problem { throw MailError.invalidAccount(p) }
        let subject = mail.subject.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard !subject.trimmingCharacters(in: .whitespaces).isEmpty || !mail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MailError.emptyMessage }

        let fromAddr = account.fromAddress.trimmingCharacters(in: .whitespaces)
        let name = account.fromName.trimmingCharacters(in: .whitespaces)
        let domain = fromAddr.split(separator: "@").last.map(String.init) ?? "localhost"
        var headers: [String] = []
        headers.append("From: " + (name.isEmpty ? "<\(fromAddr)>" : "\(encodedWord(name)) <\(fromAddr)>"))
        headers.append("To: <\(to)>")
        headers.append("Subject: " + encodedWord(subject))
        headers.append("Date: " + rfc5322Date(date))
        headers.append("Message-ID: <\(messageID)@\(domain)>")
        headers.append("MIME-Version: 1.0")
        headers.append("Content-Type: text/plain; charset=UTF-8")
        headers.append("Content-Transfer-Encoding: base64")
        headers.append("X-Mailer: Customers")
        let body = ContactLinks.normalizeNewlines(mail.body)
        let encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + encoded + "\r\n"
    }

    /// Заголовок в кодировке RFC 2047 (=?UTF-8?B?…?=). Только ASCII без спецсимволов — как есть.
    /// Длинный текст делится на несколько слов, каждое не длиннее 75 символов; символ не разрывается.
    public static func encodedWord(_ text: String) -> String {
        let plainOK = text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F } && !text.contains("=?")
            && !text.contains(where: { "\"<>()@,;:".contains($0) })
        if plainOK && text.count <= 70 { return text }
        var words: [String] = []
        var chunk = Data()
        for ch in text {
            let bytes = Data(String(ch).utf8)
            if chunk.count + bytes.count > 45 {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty || words.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    public static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    /// Точка в начале строки удваивается, чтобы сервер не принял её за конец письма.
    public static func dotStuffed(_ message: String) -> String {
        message.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
    }
}

// MARK: - SMTP

/// Соединение с почтовым сервером: байты туда и обратно и включение TLS по STARTTLS.
public protocol SMTPTransport: AnyObject {
    /// Следующая порция байтов от сервера. Пустой ответ — соединение закрыто.
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    /// Перевести открытое соединение в TLS (после ответа 220 на STARTTLS).
    func startTLS() async throws
    func close()
}

public struct SMTPReply: Equatable, Sendable {
    public let code: Int
    public let lines: [String]
    public var text: String { lines.joined(separator: " ") }
}

/// Диалог SMTP: EHLO, STARTTLS, AUTH PLAIN/LOGIN, MAIL FROM, RCPT TO, DATA, QUIT.
public final class SMTPClient {
    private let transport: SMTPTransport
    private var buffer = Data()
    public private(set) var log: [String] = []

    public init(transport: SMTPTransport) { self.transport = transport }

    /// Отправляет письмо. Транспорт для `.tls` должен быть уже зашифрован, для `.startTLS` — открыт.
    public func send(_ mail: OutgoingMail, account: MailAccount, password: String, hostname: String = "localhost") async throws {
        guard !password.isEmpty else { throw MailError.noPassword }
        let message = try MIMEMessage.build(mail, from: account)
        defer { transport.close() }

        try expect(await reply(), [220], "приветствие")
        var caps = try await ehlo(hostname)
        if account.security == .startTLS {
            guard caps.contains(where: { $0.uppercased() == "STARTTLS" }) else { throw MailError.tlsUnavailable }
            try await command("STARTTLS", [220], "STARTTLS")
            try await transport.startTLS()
            buffer = Data()
            caps = try await ehlo(hostname)
        }
        try await authenticate(caps, user: account.username.trimmingCharacters(in: .whitespaces), password: password)

        let from = account.fromAddress.trimmingCharacters(in: .whitespaces)
        try await command("MAIL FROM:<\(from)>", [250], "MAIL")
        try await command("RCPT TO:<\(mail.to.trimmingCharacters(in: .whitespaces))>", [250, 251], "RCPT")
        if account.copyToSelf, from.lowercased() != mail.to.trimmingCharacters(in: .whitespaces).lowercased() {
            try await command("RCPT TO:<\(from)>", [250, 251], "RCPT")
        }
        try await command("DATA", [354], "DATA")
        try await transport.send(Data((MIMEMessage.dotStuffed(message) + ".\r\n").utf8))
        log.append("C: <письмо>")
        try expect(await reply(), [250], "DATA")
        // Письмо уже принято: ошибка на QUIT не считается неудачей.
        try? await command("QUIT", [221], "QUIT")
    }

    private func ehlo(_ hostname: String) async throws -> [String] {
        let r = try await command("EHLO \(hostname)", [250], "EHLO")
        return r.lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func authenticate(_ caps: [String], user: String, password: String) async throws {
        let auth = caps.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased()
            .replacingOccurrences(of: "AUTH=", with: "AUTH ")
            .split(separator: " ").dropFirst().map(String.init) ?? []
        if auth.contains("PLAIN") {
            let token = Data("\0\(user)\0\(password)".utf8).base64EncodedString()
            try await command("AUTH PLAIN \(token)", [235], "AUTH", secret: true)
        } else if auth.contains("LOGIN") {
            try await command("AUTH LOGIN", [334], "AUTH")
            try await command(Data(user.utf8).base64EncodedString(), [334], "AUTH", secret: true)
            try await command(Data(password.utf8).base64EncodedString(), [235], "AUTH", secret: true)
        } else {
            throw MailError.authUnsupported
        }
    }

    @discardableResult
    private func command(_ line: String, _ ok: [Int], _ stage: String, secret: Bool = false) async throws -> SMTPReply {
        log.append("C: " + (secret ? "<скрыто>" : line))
        try await transport.send(Data((line + "\r\n").utf8))
        let r = try await reply()
        try expect(r, ok, stage)
        return r
    }

    private func expect(_ r: SMTPReply, _ ok: [Int], _ stage: String) throws {
        guard ok.contains(r.code) else { throw MailError.server(code: r.code, message: r.text, stage: stage) }
    }

    /// Ответ сервера, возможно многострочный («250-…» … «250 …»).
    func reply() async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            log.append("S: " + line)
            guard line.count >= 3, let code = Int(line.prefix(3)) else { throw MailError.badReply(line) }
            let sep = line.count > 3 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
            lines.append(line.count > 4 ? String(line.dropFirst(4)) : "")
            if sep != "-" { return SMTPReply(code: code, lines: lines) }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.range(of: Data("\n".utf8)) {
                var lineData = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                if lineData.last == 13 { lineData.removeLast() }
                return String(decoding: lineData, as: UTF8.self)
            }
            if buffer.count > 64 * 1024 { throw MailError.badReply("слишком длинная строка") }
            let chunk = try await transport.receive()
            if chunk.isEmpty { throw MailError.connection("сервер закрыл соединение") }
            buffer.append(chunk)
        }
    }
}
