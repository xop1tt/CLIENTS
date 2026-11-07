import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LeadGenCore

/// Звонки и письма из карточки лида: ссылки tel:/mailto:, черновик письма.
final class ContactLinksTests: XCTestCase {
    func testRussianPhonesAreNormalized() {
        XCTAssertEqual(ContactLinks.normalizedPhone("8 (843) 000-00-00"), "+78430000000")
        XCTAssertEqual(ContactLinks.normalizedPhone("+7 843 000-00-00"), "+78430000000")
        XCTAssertEqual(ContactLinks.normalizedPhone("7 843 000 00 00"), "+78430000000")
        XCTAssertEqual(ContactLinks.normalizedPhone("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(ContactLinks.normalizedPhone("8 800 555-35-35 доб. 123"), "+78005553535", "добавочный отбрасывается")
        XCTAssertEqual(ContactLinks.normalizedPhone("+7 843 000-00-00, +7 900 000-00-00"), "+78430000000", "только первый номер")
        XCTAssertEqual(ContactLinks.normalizedPhone("12-34"), nil, "меньше 5 цифр — не номер")
        XCTAssertEqual(ContactLinks.normalizedPhone("нет телефона"), nil)
        XCTAssertEqual(ContactLinks.normalizedPhone("1234567890123456"), nil, "больше 15 цифр (E.164) — не номер")
        XCTAssertEqual(ContactLinks.normalizedPhone("٨٠٠١٢٣٤٥"), nil, "не-ASCII цифры не принимаются")
    }

    func testTelAndFaceTimeURLs() {
        XCTAssertEqual(ContactLinks.telURL("8 (843) 000-00-00")?.absoluteString, "tel:+78430000000")
        XCTAssertEqual(ContactLinks.faceTimeAudioURL("+7 843 000-00-00")?.absoluteString, "facetime-audio:+78430000000")
        XCTAssertNil(ContactLinks.telURL("abc"))
    }

    func testEmailValidation() {
        for ok in ["a@b.ru", "first.last+tag@sub.example.com", "Иван@почта.рф"] { XCTAssertTrue(ContactLinks.isEmail(ok), ok) }
        for bad in ["", "a", "a@b", "@b.ru", "a@.ru", "a@b.", "a@@b.ru", "a b@c.ru", "a@b..ru", "a@b.ru\r\nBcc: x@y.ru",
                    "<a@b.ru>", "a@b.ru,c@d.ru", String(repeating: "a", count: 65) + "@b.ru"] {
            XCTAssertFalse(ContactLinks.isEmail(bad), bad)
        }
    }

    func testMailtoEncodesEverythingOutsideUnreserved() throws {
        let url = try XCTUnwrap(ContactLinks.mailtoURL(to: "info@example.ru", subject: "Привет & пока", body: "Строка 1\nСтрока 2 + 3=4#"))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("mailto:info@example.ru?subject="))
        XCTAssertTrue(s.contains("%20%26%20"), "пробел и & закодированы")
        XCTAssertTrue(s.contains("%0D%0A"), "перевод строки — CRLF")
        XCTAssertTrue(s.contains("%2B") && s.contains("%3D") && s.contains("%23"))
        XCTAssertFalse(s.contains(" "))
        let parsed = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parsed.queryItems?.first { $0.name == "subject" }?.value, "Привет & пока")
        XCTAssertEqual(parsed.queryItems?.first { $0.name == "body" }?.value, "Строка 1\r\nСтрока 2 + 3=4#")
    }

    func testMailtoWithoutSubjectAndInvalidAddress() {
        XCTAssertEqual(ContactLinks.mailtoURL(to: " a@b.ru ")?.absoluteString, "mailto:a@b.ru")
        XCTAssertNil(ContactLinks.mailtoURL(to: "a@b.ru?cc=x@y.ru"))
        XCTAssertNil(ContactLinks.mailtoURL(to: "не адрес"))
    }

    func testEmailDraftSplitsSubject() {
        let org = LeadData(kind: .organization, source: "osm", externalId: "1", title: "Студия «Лаванда»", phone: "+7 843 000-00-00")
        let d = DraftWriter.email(for: org, signature: "Максим")
        XCTAssertEqual(d.subject, "Предложение для Студия «Лаванда»")
        XCTAssertTrue(d.body.hasPrefix("Здравствуйте!"))
        XCTAssertTrue(d.body.hasSuffix("Максим"))
        XCTAssertFalse(d.body.contains("Тема:"))
        // Совпадает с прежним черновиком канала «Email».
        XCTAssertEqual("Тема: \(d.subject)\n\n\(d.body)", DraftWriter.draft(for: org, channel: .email, signature: "Максим"))
    }

    func testSplitWithoutSubject() {
        XCTAssertEqual(DraftWriter.split("Просто текст"), EmailDraft(subject: "", body: "Просто текст"))
        XCTAssertEqual(DraftWriter.split("Тема: Только тема"), EmailDraft(subject: "Только тема", body: ""))
    }
}

// MARK: - Почта

final class MailSettingsTests: XCTestCase {
    func testProviderDetection() {
        XCTAssertEqual(MailProvider.detect("me@gmail.com"), .gmail)
        XCTAssertEqual(MailProvider.detect("me@GoogleMail.com"), .gmail)
        XCTAssertEqual(MailProvider.detect("me@ya.ru"), .yandex)
        XCTAssertEqual(MailProvider.detect("me@yandex.ru"), .yandex)
        XCTAssertEqual(MailProvider.detect("me@inbox.ru"), .mailru)
        XCTAssertEqual(MailProvider.detect("me@icloud.com"), .icloud)
        XCTAssertEqual(MailProvider.detect("me@company.ru"), .custom)
        XCTAssertEqual(MailProvider.detect(""), .custom)
    }

    func testPresetsUseEncryptedPorts() {
        for p in MailProvider.allCases where p != .custom {
            XCTAssertFalse(p.host.isEmpty, p.title)
            XCTAssertEqual(p.port == 465, p.security == .tls, "465 — TLS, 587 — STARTTLS: \(p)")
            XCTAssertNotNil(p.appPasswordPage, p.title)
            XCTAssertEqual(p.appPasswordPage?.scheme, "https")
            XCTAssertFalse(p.hint.isEmpty)
        }
        let a = MailAccount.preset(for: "me@gmail.com", name: "Максим")
        XCTAssertEqual(a.host, "smtp.gmail.com")
        XCTAssertEqual(a.port, 465)
        XCTAssertEqual(a.security, .tls)
        XCTAssertEqual(a.username, "me@gmail.com")
        XCTAssertNil(a.problem)
        XCTAssertEqual(MailAccount.preset(for: "me@icloud.com").security, .startTLS)
        XCTAssertEqual(MailAccount.preset(for: "me@icloud.com").port, 587)
    }

    func testAccountProblems() {
        var a = MailAccount.preset(for: "me@yandex.ru")
        XCTAssertNil(a.problem)
        a.host = "smtp.example.ru/evil"; XCTAssertNotNil(a.problem)
        a.host = ""; XCTAssertNotNil(a.problem)
        a = MailAccount.preset(for: "me@yandex.ru"); a.port = 0; XCTAssertNotNil(a.problem)
        a = MailAccount.preset(for: "me@yandex.ru"); a.username = " "; XCTAssertNotNil(a.problem)
        a = MailAccount.preset(for: "me@yandex.ru"); a.fromAddress = "не адрес"; XCTAssertNotNil(a.problem)
        a = MailAccount.preset(for: "me@yandex.ru"); a.fromName = "Имя\r\nBcc: x@y.ru"; XCTAssertNotNil(a.problem)
    }

    func testAccountRoundTripHasNoPassword() throws {
        let a = MailAccount.preset(for: "me@mail.ru", name: "Максим")
        let text = a.encoded()
        XCTAssertEqual(MailAccount.decode(text), a)
        XCTAssertFalse(text.lowercased().contains("password"), "пароль в настройках не хранится")
        XCTAssertNil(MailAccount.decode("не json"))
        XCTAssertNil(MailAccount.decode(nil))
    }

    func testDeliveryTitles() {
        XCTAssertEqual(Set(MailDelivery.allCases.map(\.title)).count, MailDelivery.allCases.count)
        XCTAssertEqual(Set(MailSecurity.allCases.map(\.title)).count, 2)
    }

    func testErrorsAreReadable() {
        let auth = MailError.server(code: 535, message: "5.7.8 Username and Password not accepted", stage: "AUTH")
        XCTAssertTrue(auth.localizedDescription.contains("пароль приложения"))
        XCTAssertTrue(MailError.server(code: 550, message: "no such user", stage: "RCPT").localizedDescription.contains("получателя"))
        for e: MailError in [.invalidRecipient, .invalidAccount("x"), .emptyMessage, .noPassword, .tlsUnavailable, .authUnsupported,
                             .badReply("x"), .connection("x"), .server(code: 451, message: "x", stage: "DATA")] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
    }
}

final class MIMEMessageTests: XCTestCase {
    private let account = MailAccount.preset(for: "me@gmail.com", name: "Максим Г.")

    private func headers(_ message: String) -> [String: String] {
        let head = message.components(separatedBy: "\r\n\r\n")[0].replacingOccurrences(of: "\r\n ", with: " ")
        var out: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            out[String(parts[0])] = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return out
    }

    func testMessageStructure() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let msg = try MIMEMessage.build(OutgoingMail(to: "client@example.ru", subject: "Предложение", body: "Здравствуйте!\nСтрока"),
                                        from: account, date: date, messageID: "abc")
        let h = headers(msg)
        XCTAssertEqual(h["To"], "<client@example.ru>")
        XCTAssertTrue(h["From"]!.hasSuffix("<me@gmail.com>"))
        XCTAssertTrue(h["From"]!.hasPrefix("=?UTF-8?B?"))
        XCTAssertEqual(h["Message-ID"], "<abc@gmail.com>")
        XCTAssertEqual(h["MIME-Version"], "1.0")
        XCTAssertEqual(h["Content-Type"], "text/plain; charset=UTF-8")
        XCTAssertEqual(h["Content-Transfer-Encoding"], "base64")
        XCTAssertTrue(h["Date"]!.contains("2023"))
        XCTAssertTrue(msg.hasSuffix("\r\n"))
        XCTAssertFalse(msg.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "только CRLF")
        let body = msg.components(separatedBy: "\r\n\r\n")[1].replacingOccurrences(of: "\r\n", with: "")
        XCTAssertEqual(String(data: try XCTUnwrap(Data(base64Encoded: body)), encoding: .utf8), "Здравствуйте!\r\nСтрока")
    }

    func testBodyLinesAreShort() throws {
        let msg = try MIMEMessage.build(OutgoingMail(to: "a@b.ru", subject: "s", body: String(repeating: "Длинный текст ", count: 200)), from: account)
        for line in msg.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.count, 998, "RFC 5322: строка не длиннее 998") }
        let body = msg.components(separatedBy: "\r\n\r\n")[1]
        for line in body.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.count, 76) }
    }

    func testHeaderInjectionIsImpossible() throws {
        let msg = try MIMEMessage.build(OutgoingMail(to: "a@b.ru", subject: "Тема\r\nBcc: victim@x.ru", body: "x"), from: account)
        XCTAssertFalse(msg.contains("\r\nBcc:"))
        XCTAssertThrowsError(try MIMEMessage.build(OutgoingMail(to: "a@b.ru\r\nBcc: v@x.ru", subject: "s", body: "x"), from: account)) {
            XCTAssertEqual($0 as? MailError, .invalidRecipient)
        }
        var bad = account
        bad.fromName = "x\nBcc: v@x.ru"
        XCTAssertThrowsError(try MIMEMessage.build(OutgoingMail(to: "a@b.ru", subject: "s", body: "x"), from: bad))
    }

    func testEmptyMessageIsRejected() {
        XCTAssertThrowsError(try MIMEMessage.build(OutgoingMail(to: "a@b.ru", subject: " ", body: "\n"), from: account)) {
            XCTAssertEqual($0 as? MailError, .emptyMessage)
        }
    }

    func testEncodedWords() {
        XCTAssertEqual(MIMEMessage.encodedWord("Hello world"), "Hello world")
        XCTAssertTrue(MIMEMessage.encodedWord("Привет").hasPrefix("=?UTF-8?B?"))
        XCTAssertTrue(MIMEMessage.encodedWord("a=?b").hasPrefix("=?UTF-8?B?"), "похожее на закодированное слово кодируется")
        XCTAssertTrue(MIMEMessage.encodedWord("Ivan <x@y.ru>").hasPrefix("=?UTF-8?B?"), "спецсимволы адреса кодируются")
        let long = String(repeating: "Очень длинная тема письма ", count: 6)
        let encoded = MIMEMessage.encodedWord(long)
        var decoded = ""
        for word in encoded.components(separatedBy: "\r\n ") {
            XCTAssertLessThanOrEqual(word.count, 75, "RFC 2047: слово не длиннее 75")
            let b64 = word.dropFirst("=?UTF-8?B?".count).dropLast(2)
            decoded += String(data: Data(base64Encoded: String(b64))!, encoding: .utf8)!
        }
        XCTAssertEqual(decoded, long, "символы не разорваны между словами")
        XCTAssertEqual(MIMEMessage.encodedWord(""), "")
    }

    func testDotStuffing() {
        XCTAssertEqual(MIMEMessage.dotStuffed(".\r\n..x\r\nok"), "..\r\n...x\r\nok")
    }
}

/// Поддельный почтовый сервер: отдаёт заранее заданные ответы, записывает команды клиента.
final class ScriptedSMTP: SMTPTransport {
    var replies: [String]
    var sent: [String] = []
    var tlsStarted = false
    var closed = false
    /// Отдавать ответы мелкими кусками, чтобы проверить сборку строк из частей.
    var chunked = false

    init(_ replies: [String]) { self.replies = replies }

    func receive() async throws -> Data {
        guard !replies.isEmpty else { return Data() }
        if chunked, replies[0].count > 3 {
            let head = String(replies[0].prefix(3))
            replies[0] = String(replies[0].dropFirst(3))
            return Data(head.utf8)
        }
        return Data(replies.removeFirst().utf8)
    }

    func send(_ data: Data) async throws { sent.append(String(decoding: data, as: UTF8.self)) }
    func startTLS() async throws { tlsStarted = true }
    func close() { closed = true }
}

final class SMTPClientTests: XCTestCase {
    private let mail = OutgoingMail(to: "client@example.ru", subject: "Тема", body: "Текст\n.точка в начале")

    private func account(_ security: MailSecurity = .tls, copy: Bool = false) -> MailAccount {
        var a = MailAccount.preset(for: "me@gmail.com")
        a.security = security
        a.copyToSelf = copy
        return a
    }

    private let okTail = ["250 2.1.0 OK\r\n", "250 2.1.5 OK\r\n", "354 Go ahead\r\n", "250 2.0.0 OK queued\r\n", "221 Bye\r\n"]

    func testPlainAuthOverTLS() async throws {
        let t = ScriptedSMTP(["220 smtp.gmail.com ESMTP\r\n", "250-smtp.gmail.com\r\n250-SIZE 35882577\r\n250-AUTH LOGIN PLAIN XOAUTH2\r\n250 SMTPUTF8\r\n",
                              "235 2.7.0 Accepted\r\n"] + okTail)
        let client = SMTPClient(transport: t)
        try await client.send(mail, account: account(), password: "app-pass")
        XCTAssertEqual(t.sent[0], "EHLO localhost\r\n")
        XCTAssertEqual(t.sent[1], "AUTH PLAIN " + Data("\0me@gmail.com\0app-pass".utf8).base64EncodedString() + "\r\n")
        XCTAssertEqual(t.sent[2], "MAIL FROM:<me@gmail.com>\r\n")
        XCTAssertEqual(t.sent[3], "RCPT TO:<client@example.ru>\r\n")
        XCTAssertEqual(t.sent[4], "DATA\r\n")
        XCTAssertTrue(t.sent[5].hasSuffix("\r\n.\r\n"))
        XCTAssertTrue(t.sent[5].contains("Subject: =?UTF-8?B?"))
        XCTAssertEqual(t.sent[6], "QUIT\r\n")
        XCTAssertFalse(t.tlsStarted, "при TLS с первого байта STARTTLS не нужен")
        XCTAssertTrue(t.closed)
        XCTAssertFalse(client.log.joined().contains("app-pass"), "пароль не попадает в журнал")
        XCTAssertFalse(client.log.joined().contains(Data("\0me@gmail.com\0app-pass".utf8).base64EncodedString()))
    }

    func testStartTLSAndLoginAuth() async throws {
        let t = ScriptedSMTP(["220 mail ESMTP\r\n", "250-mail\r\n250-STARTTLS\r\n250 AUTH=LOGIN\r\n", "220 Ready to start TLS\r\n",
                              "250-mail\r\n250 AUTH LOGIN\r\n", "334 VXNlcm5hbWU6\r\n", "334 UGFzc3dvcmQ6\r\n", "235 OK\r\n"] + okTail)
        t.chunked = true
        try await SMTPClient(transport: t).send(mail, account: account(.startTLS), password: "pw")
        XCTAssertTrue(t.tlsStarted)
        XCTAssertEqual(Array(t.sent.prefix(6)), ["EHLO localhost\r\n", "STARTTLS\r\n", "EHLO localhost\r\n", "AUTH LOGIN\r\n",
                                                 Data("me@gmail.com".utf8).base64EncodedString() + "\r\n",
                                                 Data("pw".utf8).base64EncodedString() + "\r\n"])
    }

    func testRefusesPlaintextWhenStartTLSMissing() async {
        let t = ScriptedSMTP(["220 mail\r\n", "250-mail\r\n250 AUTH PLAIN\r\n"])
        do {
            try await SMTPClient(transport: t).send(mail, account: account(.startTLS), password: "pw")
            XCTFail("пароль нельзя отправлять без шифрования")
        } catch {
            XCTAssertEqual(error as? MailError, .tlsUnavailable)
        }
        XCTAssertFalse(t.sent.contains { $0.hasPrefix("AUTH") })
        XCTAssertTrue(t.closed)
    }

    func testWrongPassword() async {
        let t = ScriptedSMTP(["220 x\r\n", "250-x\r\n250 AUTH PLAIN\r\n", "535 5.7.8 Username and Password not accepted\r\n"])
        do {
            try await SMTPClient(transport: t).send(mail, account: account(), password: "bad")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? MailError, .server(code: 535, message: "5.7.8 Username and Password not accepted", stage: "AUTH"))
        }
        XCTAssertFalse(t.sent.contains { $0.hasPrefix("MAIL FROM") })
    }

    func testNoAuthMechanism() async {
        let t = ScriptedSMTP(["220 x\r\n", "250 x\r\n"])
        do { try await SMTPClient(transport: t).send(mail, account: account(), password: "pw"); XCTFail() } catch {
            XCTAssertEqual(error as? MailError, .authUnsupported)
        }
    }

    func testCopyToSelfAddsSecondRecipientWithoutHeader() async throws {
        let t = ScriptedSMTP(["220 x\r\n", "250-x\r\n250 AUTH PLAIN\r\n", "235 OK\r\n", "250 OK\r\n", "250 OK\r\n", "250 OK\r\n",
                              "354 Go\r\n", "250 OK\r\n", "221 Bye\r\n"])
        try await SMTPClient(transport: t).send(mail, account: account(copy: true), password: "pw")
        XCTAssertEqual(t.sent.filter { $0.hasPrefix("RCPT TO:") }, ["RCPT TO:<client@example.ru>\r\n", "RCPT TO:<me@gmail.com>\r\n"])
        let data = try XCTUnwrap(t.sent.first { $0.contains("MIME-Version") })
        XCTAssertFalse(data.contains("me@gmail.com>\r\nBcc"), "скрытая копия не видна получателю")
        XCTAssertFalse(data.contains("Bcc:"))
    }

    func testRejectedRecipient() async {
        let t = ScriptedSMTP(["220 x\r\n", "250-x\r\n250 AUTH PLAIN\r\n", "235 OK\r\n", "250 OK\r\n", "550 5.1.1 No such user\r\n"])
        do { try await SMTPClient(transport: t).send(mail, account: account(), password: "pw"); XCTFail() } catch {
            XCTAssertEqual((error as? MailError).map { if case .server(550, _, "RCPT") = $0 { return true } else { return false } }, true)
        }
        XCTAssertFalse(t.sent.contains("DATA\r\n"))
    }

    func testQuitFailureAfterAcceptanceIsSuccess() async throws {
        let t = ScriptedSMTP(["220 x\r\n", "250-x\r\n250 AUTH PLAIN\r\n", "235 OK\r\n", "250 OK\r\n", "250 OK\r\n", "354 Go\r\n", "250 OK\r\n"])
        try await SMTPClient(transport: t).send(mail, account: account(), password: "pw")
    }

    func testBadGreetingAndClosedConnection() async {
        do { try await SMTPClient(transport: ScriptedSMTP(["554 No service\r\n"])).send(mail, account: account(), password: "pw"); XCTFail() } catch {
            XCTAssertEqual((error as? MailError).map { if case .server(554, _, _) = $0 { return true } else { return false } }, true)
        }
        do { try await SMTPClient(transport: ScriptedSMTP([])).send(mail, account: account(), password: "pw"); XCTFail() } catch {
            XCTAssertEqual((error as? MailError).map { if case .connection = $0 { return true } else { return false } }, true)
        }
        do { try await SMTPClient(transport: ScriptedSMTP(["hello\r\n"])).send(mail, account: account(), password: "pw"); XCTFail() } catch {
            XCTAssertEqual((error as? MailError).map { if case .badReply = $0 { return true } else { return false } }, true)
        }
    }

    func testEmptyPasswordAndBadRecipientDoNotConnect() async {
        let t = ScriptedSMTP(["220 x\r\n"])
        do { try await SMTPClient(transport: t).send(mail, account: account(), password: ""); XCTFail() } catch {
            XCTAssertEqual(error as? MailError, .noPassword)
        }
        do {
            try await SMTPClient(transport: t).send(OutgoingMail(to: "bad", subject: "s", body: "b"), account: account(), password: "pw")
            XCTFail()
        } catch { XCTAssertEqual(error as? MailError, .invalidRecipient) }
        XCTAssertTrue(t.sent.isEmpty, "ничего не отправлено на сервер")
    }

    func testBodyDotIsStuffed() async throws {
        let t = ScriptedSMTP(["220 x\r\n", "250-x\r\n250 AUTH PLAIN\r\n", "235 OK\r\n"] + okTail)
        let m = OutgoingMail(to: "a@b.ru", subject: "s", body: "x")
        try await SMTPClient(transport: t).send(m, account: account(), password: "pw")
        let data = try XCTUnwrap(t.sent.first { $0.contains("MIME-Version") })
        XCTAssertEqual(data.components(separatedBy: "\r\n").filter { $0 == "." }.count, 1, "одна завершающая точка")
    }
}

// MARK: - Облачные диски

final class IntegrationsTests: XCTestCase {
    private let google = OAuthClient(provider: .google, clientID: "123.apps.googleusercontent.com", clientSecret: "GOCSPX-test")!
    private let dropbox = OAuthClient(provider: .dropbox, clientID: "abc123")!

    func testCatalogIsComplete() {
        XCTAssertEqual(Set(DriveService.allCases.map(\.title)).count, DriveService.allCases.count)
        for s in DriveService.allCases {
            XCTAssertFalse(s.subtitle.isEmpty)
            XCTAssertEqual(DriveService(rawValue: s.rawValue), s)
        }
        XCTAssertTrue(DriveService.allCases.contains(.googleDrive))
        XCTAssertTrue(DriveService.allCases.contains(.dropbox))
        XCTAssertTrue(DriveService.allCases.contains(.mega))
        XCTAssertEqual(DriveService.googleDrive.auth, .oauth(.google))
        if case .webdav(let url, _) = DriveService.yandexDisk.auth { XCTAssertEqual(url, "https://webdav.yandex.ru") } else { XCTFail() }
        XCTAssertTrue(DriveService.mega.passwordOptional)
        XCTAssertFalse(DriveService.yandexDisk.passwordOptional)
    }

    func testProvidersUseHTTPS() {
        for p in OAuthProvider.allCases {
            XCTAssertEqual(p.authorizeURL.scheme, "https")
            XCTAssertEqual(p.tokenURL.scheme, "https")
            XCTAssertTrue(p.clientIDKey.hasPrefix("LG"))
            XCTAssertFalse(p.buildVariable.isEmpty)
        }
    }

    func testClientRequiresConfiguredValues() {
        XCTAssertNil(OAuthClient(provider: .dropbox, clientID: nil))
        XCTAssertNil(OAuthClient(provider: .dropbox, clientID: "  "))
        XCTAssertNil(OAuthClient(provider: .dropbox, clientID: "$(DROPBOX_APP_KEY)"), "не подставленная переменная")
        XCTAssertNil(OAuthClient(provider: .google, clientID: "id"), "Google без client_secret не работает")
        XCTAssertNotNil(OAuthClient(provider: .microsoft, clientID: "00000000-0000-0000-0000-000000000000"))
        XCTAssertNil(OAuthClient(provider: .microsoft, clientID: "a b"))
        XCTAssertNil(OAuthClient.fromBundle(.dropbox, bundle: Bundle(for: Self.self)), "в тестовом пакете ключей нет")
    }

    func testAuthorizeURLHasPKCEAndState() throws {
        let url = OAuthFlow.authorizeURL(google, state: "st", codeChallenge: "ch")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        func q(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value }
        XCTAssertEqual(c.host, "accounts.google.com")
        XCTAssertEqual(q("client_id"), "123.apps.googleusercontent.com")
        XCTAssertEqual(q("redirect_uri"), "http://localhost:47811/oauth/callback")
        XCTAssertEqual(q("response_type"), "code")
        XCTAssertEqual(q("state"), "st")
        XCTAssertEqual(q("code_challenge"), "ch")
        XCTAssertEqual(q("code_challenge_method"), "S256")
        XCTAssertEqual(q("scope"), "https://www.googleapis.com/auth/drive.file", "только файлы приложения")
        XCTAssertEqual(q("access_type"), "offline")
        XCTAssertNil(q("client_secret"), "секрет не уходит в браузер")
        let d = try XCTUnwrap(URLComponents(url: OAuthFlow.authorizeURL(dropbox, state: "s", codeChallenge: "c"), resolvingAgainstBaseURL: false))
        XCTAssertEqual(d.queryItems?.first { $0.name == "token_access_type" }?.value, "offline")
        XCTAssertNil(d.queryItems?.first { $0.name == "scope" })
    }

    func testVerifierAlphabetAndLength() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for len in [1, 43, 64, 128, 500] {
            let v = OAuthFlow.randomVerifier(length: len)
            XCTAssertEqual(v.count, max(43, min(len, 128)))
            XCTAssertTrue(v.allSatisfy(allowed.contains))
        }
        XCTAssertNotEqual(OAuthFlow.randomVerifier(), OAuthFlow.randomVerifier())
        XCTAssertEqual(OAuthFlow.base64URL(Data([0xfb, 0xff, 0xfe])), "-__-")
    }

    private func form(_ r: URLRequest) -> [String: String] {
        let text = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    func testTokenAndRefreshRequests() {
        let t = OAuthFlow.tokenRequest(google, code: "c/1+2", verifier: "v")
        XCTAssertEqual(t.httpMethod, "POST")
        XCTAssertEqual(t.url, OAuthProvider.google.tokenURL)
        XCTAssertEqual(t.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(form(t), ["grant_type": "authorization_code", "code": "c/1+2", "redirect_uri": OAuthRedirect.uri,
                                 "client_id": "123.apps.googleusercontent.com", "code_verifier": "v", "client_secret": "GOCSPX-test"])
        XCTAssertTrue(String(decoding: t.httpBody!, as: UTF8.self).contains("c%2F1%2B2"), "+ и / закодированы")
        let r = OAuthFlow.refreshRequest(dropbox, refreshToken: "rt")
        XCTAssertEqual(form(r), ["grant_type": "refresh_token", "refresh_token": "rt", "client_id": "abc123"])
        let ms = OAuthFlow.refreshRequest(OAuthClient(provider: .microsoft, clientID: "id")!, refreshToken: "rt")
        XCTAssertEqual(form(ms)["scope"], "Files.ReadWrite.AppFolder offline_access")
    }

    func testParseToken() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let t = try OAuthFlow.parseToken(Data(#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#.utf8), now: now)
        XCTAssertEqual(t, OAuthToken(accessToken: "at", refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 4600)))
        let refreshed = try OAuthFlow.parseToken(Data(#"{"access_token":"at2","expires_in":"60"}"#.utf8), previousRefresh: "rt", now: now)
        XCTAssertEqual(refreshed.refreshToken, "rt", "без нового refresh_token остаётся прежний")
        XCTAssertEqual(refreshed.expiresAt, Date(timeIntervalSince1970: 1060))
        XCTAssertNil(try OAuthFlow.parseToken(Data(#"{"access_token":"x"}"#.utf8)).expiresAt)
        XCTAssertThrowsError(try OAuthFlow.parseToken(Data(#"{"error":"invalid_grant"}"#.utf8))) { XCTAssertEqual($0 as? IntegrationError, .reauthorize) }
        XCTAssertThrowsError(try OAuthFlow.parseToken(Data(#"{"error":"access_denied","error_description":"нет"}"#.utf8))) {
            XCTAssertEqual($0 as? IntegrationError, .denied("нет"))
        }
        XCTAssertThrowsError(try OAuthFlow.parseToken(Data("<html>".utf8)))
        XCTAssertThrowsError(try OAuthFlow.parseToken(Data(#"{"access_token":""}"#.utf8)))
    }

    func testTokenExpiry() {
        let now = Date()
        XCTAssertFalse(OAuthToken(accessToken: "a", refreshToken: nil, expiresAt: nil).isExpired(now: now))
        XCTAssertTrue(OAuthToken(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(30)).isExpired(now: now))
        XCTAssertFalse(OAuthToken(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(600)).isExpired(now: now))
    }

    func testCallbackParsing() throws {
        let cb = try XCTUnwrap(OAuthCallback.parse(requestLine: "GET /oauth/callback?code=abc%2F1&state=xyz HTTP/1.1"))
        XCTAssertEqual(cb.code, "abc/1")
        XCTAssertEqual(try cb.validated(state: "xyz"), "abc/1")
        XCTAssertThrowsError(try cb.validated(state: "other")) { XCTAssertEqual($0 as? IntegrationError, .stateMismatch) }
        let denied = try XCTUnwrap(OAuthCallback.parse(requestLine: "GET /oauth/callback?error=access_denied&state=xyz HTTP/1.1"))
        XCTAssertThrowsError(try denied.validated(state: "xyz")) { XCTAssertEqual($0 as? IntegrationError, .denied("access_denied")) }
        let noCode = try XCTUnwrap(OAuthCallback.parse(requestLine: "GET /oauth/callback?state=xyz HTTP/1.1"))
        XCTAssertThrowsError(try noCode.validated(state: "xyz"))
        XCTAssertNil(OAuthCallback.parse(requestLine: "GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(OAuthCallback.parse(requestLine: "POST /oauth/callback?code=a HTTP/1.1"))
        XCTAssertNil(OAuthCallback.parse(requestLine: ""))
    }

    func testConnectionRoundTripAndKeychainNames() {
        let c = DriveConnection(service: .dropbox, token: OAuthToken(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 0)),
                                connectedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(DriveConnection.decode(c.encoded()), c)
        XCTAssertNil(DriveConnection.decode("{"))
        XCTAssertEqual(DriveConnection.keychainAccount(.dropbox, user: "Максим"), "integration.dropbox.максим")
        XCTAssertNotEqual(DriveConnection.keychainAccount(.dropbox, user: "a"), DriveConnection.keychainAccount(.dropbox, user: "b"))
        XCTAssertNotEqual(DriveConnection.keychainAccount(.dropbox, user: "a"), DriveConnection.keychainAccount(.oneDrive, user: "a"))
    }

    func testWebDAVAddressRules() throws {
        XCTAssertEqual(try DriveUpload.webdavBase("https://webdav.yandex.ru").absoluteString, "https://webdav.yandex.ru/")
        XCTAssertEqual(try DriveUpload.webdavBase(" http://127.0.0.1:4443/abc/Customers ").absoluteString, "http://127.0.0.1:4443/abc/Customers/")
        XCTAssertNoThrow(try DriveUpload.webdavBase("http://localhost:4443/x/"))
        for bad in ["", "webdav.yandex.ru", "http://webdav.yandex.ru", "ftp://x.ru", "https://user:pw@x.ru/", "http://192.168.1.5/"] {
            XCTAssertThrowsError(try DriveUpload.webdavBase(bad), bad) { XCTAssertEqual($0 as? IntegrationError, .invalidURL) }
        }
    }

    func testWebDAVUploadRequests() throws {
        let c = DriveConnection(service: .yandexDisk, webdavURL: "https://webdav.yandex.ru", login: "me", password: "pw")
        let rs = try DriveUpload.requests(for: c, fileName: "leadgen-1.db", data: Data([1, 2]))
        XCTAssertEqual(rs.map(\.httpMethod), ["MKCOL", "PUT"])
        XCTAssertEqual(rs[0].url?.absoluteString, "https://webdav.yandex.ru/Customers/")
        XCTAssertEqual(rs[1].url?.absoluteString, "https://webdav.yandex.ru/Customers/leadgen-1.db")
        XCTAssertEqual(rs[1].httpBody, Data([1, 2]))
        XCTAssertEqual(rs[1].value(forHTTPHeaderField: "Authorization"), "Basic " + Data("me:pw".utf8).base64EncodedString())
        let mega = DriveConnection(service: .mega, webdavURL: "http://127.0.0.1:4443/x/")
        XCTAssertNil(try DriveUpload.requests(for: mega, fileName: "f.db", data: Data())[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(DriveUpload.isSuccess(rs[0], status: 405), "папка уже есть")
        XCTAssertTrue(DriveUpload.isSuccess(rs[0], status: 201))
        XCTAssertFalse(DriveUpload.isSuccess(rs[1], status: 405))
        XCTAssertTrue(DriveUpload.isSuccess(rs[1], status: 204))
        XCTAssertFalse(DriveUpload.isSuccess(rs[1], status: 401))
    }

    func testOAuthUploadRequests() throws {
        let token = OAuthToken(accessToken: "AT", refreshToken: nil, expiresAt: nil)
        let g = try DriveUpload.requests(for: DriveConnection(service: .googleDrive, token: token), fileName: "a.db", data: Data("DB".utf8))
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].url?.host, "www.googleapis.com")
        XCTAssertEqual(g[0].value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertTrue(g[0].value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/related; boundary="))
        XCTAssertTrue(String(decoding: g[0].httpBody!, as: UTF8.self).contains("Customers a.db"))

        let d = try DriveUpload.requests(for: DriveConnection(service: .dropbox, token: token), fileName: "лиды.db", data: Data())
        let arg = try XCTUnwrap(d[0].value(forHTTPHeaderField: "Dropbox-API-Arg"))
        XCTAssertTrue(arg.allSatisfy(\.isASCII), "заголовок только ASCII")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: Any])
        XCTAssertEqual(obj["path"] as? String, "/Customers/лиды.db")
        XCTAssertEqual(obj["mode"] as? String, "add")
        XCTAssertEqual(d[0].url?.host, "content.dropboxapi.com")

        let o = try DriveUpload.requests(for: DriveConnection(service: .oneDrive, token: token), fileName: "a b.db", data: Data())
        XCTAssertEqual(o[0].httpMethod, "PUT")
        XCTAssertEqual(o[0].url?.absoluteString, "https://graph.microsoft.com/v1.0/me/drive/special/approot:/Customers/a%20b.db:/content")

        XCTAssertThrowsError(try DriveUpload.requests(for: DriveConnection(service: .dropbox), fileName: "a", data: Data())) {
            XCTAssertEqual($0 as? IntegrationError, .reauthorize)
        }
        let slash = try DriveUpload.requests(for: DriveConnection(service: .yandexDisk, webdavURL: "https://webdav.yandex.ru"), fileName: "../x/y.db", data: Data())
        XCTAssertEqual(slash[1].url?.lastPathComponent, ".._x_y.db", "имя файла не выходит из папки")
    }

    func testErrorDescriptions() {
        for e: IntegrationError in [.notConfigured(.google), .denied("x"), .stateMismatch, .badResponse("x"), .http(500, ""), .invalidURL, .reauthorize] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
        XCTAssertTrue(IntegrationError.notConfigured(.dropbox).localizedDescription.contains("DROPBOX_APP_KEY"))
    }
}
