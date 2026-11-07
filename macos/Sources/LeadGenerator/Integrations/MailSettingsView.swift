import AppKit
import LeadGenCore
import SwiftUI

/// «Настройки → Обращения → Почта»: как отправлять письма из окна «Написать».
struct MailSettingsSection: View {
    let mail: MailController
    @State private var address = ""
    @State private var name = ""
    @State private var host = ""
    @State private var port = 465
    @State private var security: MailSecurity = .tls
    @State private var login = ""
    @State private var password = ""
    @State private var copyToSelf = true
    @State private var provider: MailProvider = .custom
    @State private var saved = false

    var body: some View {
        Section("Почта") {
            Picker("Как отправлять письма", selection: Binding(get: { mail.delivery }, set: { mail.delivery = $0 })) {
                ForEach(MailDelivery.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if mail.delivery == .mailApp {
                HStack(spacing: 10) {
                    ServiceIcon(kind: .mailApp, size: 26)
                    Text("Кнопка «Открыть в Почте» создаёт готовое письмо в программе «Почта» (или в почтовой программе по умолчанию). Отправленные письма хранятся там и видны на всех ваших устройствах.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                smtpForm
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var smtpForm: some View {
        TextField("Ваш адрес", text: $address, prompt: Text("name@gmail.com"))
            .onChange(of: address) { _, new in applyPreset(new) }
        TextField("Имя отправителя", text: $name, prompt: Text("Максим"))
        HStack(spacing: 10) {
            ServiceIcon(kind: .mail(provider), size: 24)
            Text(provider.title)
            Spacer()
            if let page = provider.appPasswordPage { Link("Создать пароль приложения", destination: page).font(.callout) }
        }
        Text(provider.hint).font(.caption).foregroundStyle(.secondary)
        if provider == .custom {
            TextField("SMTP-сервер", text: $host, prompt: Text("smtp.example.ru"))
            Picker("Шифрование", selection: $security) { ForEach(MailSecurity.allCases) { Text($0.title).tag($0) } }
                .onChange(of: security) { _, s in port = s == .tls ? 465 : 587 }
            TextField("Порт", value: $port, format: .number.grouping(.never))
        }
        TextField("Логин", text: $login, prompt: Text("обычно весь адрес"))
        SecureField("Пароль приложения", text: $password, prompt: Text(mail.hasPassword ? "сохранён в Связке ключей" : ""))
        Toggle("Копия себе (письмо появится во «Входящих» на всех устройствах)", isOn: $copyToSelf)
        HStack {
            Button("Сохранить") { save() }.disabled(draft.problem != nil)
            Button("Отправить проверочное письмо") { save(); Task { await mail.sendTest() } }
                .disabled(draft.problem != nil || (!mail.hasPassword && password.isEmpty) || mail.sending)
            if mail.sending { ProgressView().controlSize(.small) }
            Spacer()
            if mail.account != nil { Button("Забыть почту", role: .destructive) { mail.forget(); load() } }
        }
        if let p = draft.problem, !address.isEmpty { Text(p).font(.caption).foregroundStyle(.orange) }
        if let e = mail.lastError { Text(e).font(.caption).foregroundStyle(.red) }
        else if let r = mail.lastResult { Label(r, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
        else if saved { Label("Сохранено", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
        Text("Пароль хранится только в Связке ключей. Письма уходят по одному, по вашей кнопке: массовой рассылки нет. Соединение всегда зашифровано (TLS или STARTTLS).")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var draft: MailAccount {
        MailAccount(provider: provider, host: host, port: port, security: security,
                    username: login.isEmpty ? address : login, fromAddress: address, fromName: name, copyToSelf: copyToSelf)
    }

    private func load() {
        let a = mail.account ?? MailAccount()
        address = a.fromAddress
        name = a.fromName
        host = a.host
        port = a.port
        security = a.security
        login = a.username
        copyToSelf = a.copyToSelf
        provider = a.provider
        password = ""
        saved = false
    }

    private func applyPreset(_ email: String) {
        let p = MailProvider.detect(email)
        provider = p
        if p != .custom {
            host = p.host
            port = p.port
            security = p.security
        }
        if login.isEmpty || login.contains("@") { login = email }
        saved = false
    }

    private func save() {
        mail.account = draft
        if !password.isEmpty { mail.setPassword(password); password = "" }
        mail.lastError = nil
        saved = true
    }
}
