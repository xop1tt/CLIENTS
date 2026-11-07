import AppKit
import Foundation
import LeadGenCore
import Observation

/// SMTP поверх URLSessionStreamTask: умеет и TLS с первого байта, и STARTTLS.
final class SMTPStreamTransport: SMTPTransport, @unchecked Sendable {
    private let task: URLSessionStreamTask
    private let timeout: TimeInterval

    init(host: String, port: Int, implicitTLS: Bool, timeout: TimeInterval = 30) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        task.resume()
        if implicitTLS { task.startSecureConnection() }
    }

    func receive() async throws -> Data {
        do {
            let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: timeout)
            if let data, !data.isEmpty { return data }
            if eof { return Data() }
            return Data()
        } catch {
            throw MailError.connection(error.localizedDescription)
        }
    }

    func send(_ data: Data) async throws {
        do { try await task.write(data, timeout: timeout) } catch { throw MailError.connection(error.localizedDescription) }
    }

    func startTLS() async throws { task.startSecureConnection() }

    func close() {
        task.closeWrite()
        task.cancel()
    }
}

/// Почта пользователя: настройки ящика (UserDefaults), пароль приложения (Связка ключей), отправка.
@MainActor @Observable
final class MailController {
    let user: String
    private let inert: Bool
    private let defaults = UserDefaults.standard

    var account: MailAccount? = nil { didSet { if !inert { defaults.set(account?.encoded(), forKey: "mail.account.\(user)") } } }
    var delivery: MailDelivery = .mailApp { didSet { if !inert { defaults.set(delivery.rawValue, forKey: "mail.delivery.\(user)") } } }
    /// Есть ли пароль в Связке ключей. Сам пароль в памяти не держим.
    private(set) var hasPassword = false
    private(set) var sending = false
    var lastResult: String? = nil
    var lastError: String? = nil

    private var passwordAccount: String { "mail.password.\(user)" }

    init(user: String, inert: Bool = false) {
        self.user = user.lowercased()
        self.inert = inert
        let d = UserDefaults.standard
        account = inert ? nil : MailAccount.decode(d.string(forKey: "mail.account.\(user.lowercased())"))
        delivery = MailDelivery(rawValue: d.string(forKey: "mail.delivery.\(user.lowercased())") ?? "") ?? .mailApp
        hasPassword = !inert && !(Keychain.get("mail.password.\(user.lowercased())") ?? "").isEmpty
    }

    /// Отправка из приложения настроена полностью.
    var smtpReady: Bool { delivery == .smtp && account?.problem == nil && hasPassword }

    func setPassword(_ value: String) {
        guard !inert else { return }
        Keychain.set(passwordAccount, value)
        hasPassword = !value.isEmpty
    }

    func forget() {
        setPassword("")
        account = nil
        delivery = .mailApp
    }

    /// Отправка по SMTP. Возвращает true, если сервер принял письмо.
    func send(_ mail: OutgoingMail) async -> Bool {
        guard let account else { lastError = "Почта не настроена: Настройки → Обращения"; return false }
        guard let password = Keychain.get(passwordAccount), !password.isEmpty else { lastError = MailError.noPassword.localizedDescription; return false }
        sending = true
        lastError = nil
        defer { sending = false }
        let transport = SMTPStreamTransport(host: account.host.trimmingCharacters(in: .whitespaces), port: account.port,
                                            implicitTLS: account.security == .tls)
        do {
            try await SMTPClient(transport: transport).send(mail, account: account, password: password)
            lastResult = "Письмо отправлено на \(mail.to)"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Открывает письмо в программе «Почта» (или в почтовой программе по умолчанию).
    /// «Почта» сама сохранит его в «Отправленных» и покажет на всех устройствах.
    @discardableResult
    static func openInMailApp(_ mail: OutgoingMail) -> Bool {
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [mail.to]
            service.subject = mail.subject
            if service.canPerform(withItems: [mail.body]) {
                service.perform(withItems: [mail.body])
                return true
            }
        }
        guard let url = ContactLinks.mailtoURL(to: mail.to, subject: mail.subject, body: mail.body) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Проверочное письмо самому себе.
    func sendTest() async {
        guard let account else { return }
        if await send(OutgoingMail(to: account.fromAddress, subject: "Проверка почты Customers",
                                   body: "Это проверочное письмо: отправка из Customers настроена.")) {
            lastResult = "Проверочное письмо отправлено на \(account.fromAddress)"
        }
    }
}
