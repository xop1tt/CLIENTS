import AppKit
import LeadGenCore
import SwiftUI

/// Список подключаемых сервисов с кнопкой «Подключиться». Показывается в окне «Интеграции»
/// (меню учётной записи) и в «Настройки → Данные».
///
/// Здесь не те диски, приложения которых уже установлены (они в «Облачное хранилище»), а те,
/// к которым приложение подключается само: вход через браузер или WebDAV.
struct DriveIntegrationsList: View {
    let controller: IntegrationsController
    let backupFile: () -> URL?
    @State private var webdavFor: DriveService?

    var body: some View {
        ForEach(DriveService.allCases) { s in
            DriveRow(service: s, controller: controller, onConnect: { connect(s) }, onUpload: { upload(s) })
        }
        if let e = controller.error {
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        } else if let m = controller.message {
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        }
        Text("Токены и пароли хранятся только в Связке ключей этого Mac. Приложение получает доступ лишь к своей папке «Customers» (у Google — только к своим файлам) и выгружает туда копии базы по кнопке. Копия базы зашифрована ключом из Связки ключей этого Mac, как и рабочая база.")
            .font(.caption).foregroundStyle(.secondary)
            .sheet(item: $webdavFor) { s in
                WebDAVConnectSheet(service: s, controller: controller).environment(\.look, AppearanceSettings.shared)
            }
    }

    private func connect(_ s: DriveService) {
        switch s.auth {
        case .oauth: controller.startOAuth(s)
        case .webdav: webdavFor = s
        }
    }

    private func upload(_ s: DriveService) {
        guard let file = backupFile() else { controller.error = "Не удалось создать копию базы"; return }
        Task { await controller.upload(file, to: s) }
    }
}

private struct DriveRow: View {
    let service: DriveService
    let controller: IntegrationsController
    let onConnect: () -> Void
    let onUpload: () -> Void

    var body: some View {
        let connected = controller.isConnected(service)
        let available = controller.isAvailable(service)
        HStack(spacing: 10) {
            ServiceIcon(kind: .drive(service), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(service.title)
                    if connected { Text("подключён").font(.caption).foregroundStyle(.green) }
                }
                Text(available ? service.subtitle : "Недоступно в этой сборке: не задан ключ приложения")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if controller.busy == service {
                ProgressView().controlSize(.small)
                if case .oauth = service.auth { Button("Отмена") { controller.cancel() } }
            } else if connected {
                Button("Выгрузить копию") { onUpload() }.disabled(controller.busy != nil)
                Menu {
                    Button("Переподключить") { onConnect() }
                    Button("Отключить", role: .destructive) { controller.disconnect(service) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            } else {
                Button("Подключиться") { onConnect() }.disabled(!available || controller.busy != nil)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Подключение по WebDAV: адрес, логин и пароль приложения.
struct WebDAVConnectSheet: View {
    let service: DriveService
    let controller: IntegrationsController
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var login = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ServiceIcon(kind: .drive(service), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подключить \(service.title)").font(.headline)
                    Text(service.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Адрес WebDAV", text: $url, prompt: Text("https://…"))
                TextField("Логин", text: $login, prompt: Text(service.passwordOptional ? "не нужен для MEGAcmd" : "логин или email"))
                SecureField("Пароль приложения", text: $password, prompt: Text(service.passwordOptional ? "не нужен для MEGAcmd" : ""))
            }
            .formStyle(.grouped)
            hint
            if let e = controller.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                if case .webdav(_, let page?) = service.auth {
                    Link(service == .mega ? "Скачать MEGAcmd" : "Создать пароль приложения", destination: page).font(.callout)
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Подключиться") {
                    Task { if await controller.connectWebDAV(service, url: url, login: login, password: password) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || (!service.passwordOptional && (login.isEmpty || password.isEmpty)) || controller.busy != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if case .webdav(let d, _) = service.auth { url = controller.connections[service]?.webdavURL ?? d }
            login = controller.connections[service]?.login ?? ""
        }
    }

    @ViewBuilder private var hint: some View {
        switch service {
        case .yandexDisk:
            Text("Логин — адрес Яндекса. Пароль — пароль приложения с доступом к «Файлам» (id.yandex.ru → Безопасность → Пароли приложений), не основной пароль.")
                .font(.caption).foregroundStyle(.secondary)
        case .mega:
            Text("MEGA не даёт входить сторонним приложениям. Установите бесплатный MEGAcmd, войдите в нём и выполните в Терминале «mega-webdav /Customers» — он покажет адрес вида http://127.0.0.1:4443/…/Customers/. Вставьте его сюда.")
                .font(.caption).foregroundStyle(.secondary)
        case .pCloud:
            Text("Европейские аккаунты: ewebdav.pcloud.com, американские: webdav.pcloud.com. Логин и пароль — от pCloud.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text("Адрес WebDAV даёт ваш сервер, например https://cloud.example.ru/remote.php/dav/files/имя/ для Nextcloud. Лучше создать отдельный пароль приложения.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Окно «Интеграции» из меню учётной записи: облачные диски и почта.
struct IntegrationsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var controller: IntegrationsController
    @State private var mail: MailController

    init(model: AppModel) {
        self.model = model
        _controller = State(initialValue: IntegrationsController(user: model.username, inert: model.isInert))
        _mail = State(initialValue: MailController(user: model.username, inert: model.isInert))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Интеграции").font(.title3.weight(.semibold))
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 18).padding(.bottom, 8)
            Form {
                Section("Облачные диски") {
                    DriveIntegrationsList(controller: controller, backupFile: { model.backupNow() })
                }
                Section("Почта") {
                    HStack(spacing: 10) {
                        if let a = mail.account, mail.delivery == .smtp {
                            ServiceIcon(kind: .mail(a.provider), size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.fromAddress)
                                Text(mail.smtpReady ? "Письма уходят прямо из приложения" : "Не хватает пароля приложения")
                                    .font(.caption).foregroundStyle(mail.smtpReady ? Color.secondary : Color.orange)
                            }
                        } else {
                            ServiceIcon(kind: .mailApp, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Программа «Почта»")
                                Text("Письма открываются в «Почте», отправленные хранятся там же").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(mail.smtpReady ? "Настроить" : "Подключить почту") {
                            UserDefaults.standard.set(SettingsSection.outreach.rawValue, forKey: "settings.section")
                            dismiss()
                            openSettings()
                        }
                    }
                }
                Section("Звонки") {
                    HStack(spacing: 10) {
                        Image(systemName: "phone.fill").font(.system(size: 15)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Color.green))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("FaceTime и iPhone")
                            Text("Кнопка звонка в карточке лида открывает FaceTime. Чтобы звонить по сотовой связи, включите на iPhone «Вызовы на других устройствах» и в FaceTime на Mac — «Вызовы с iPhone».")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: 640)
    }
}
