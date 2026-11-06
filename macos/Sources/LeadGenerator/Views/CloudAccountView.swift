import LeadCloud
import LeadGenCore
import SwiftUI

/// Настройки облачной учётной записи: адрес, синхронизация, пароль, смена адреса,
/// перенос локальных данных, выход и удаление.
struct CloudAccountSettingsView: View {
    @Environment(\.appModel) private var model
    @Environment(\.session) private var session

    var body: some View {
        Form {
            AccountSection()
            SyncSection()
            CloudPasswordSection()
            EmailChangeSection()
            ImportLocalSection()
            DeleteAccountSection()
        }
        .formStyle(.grouped)
        .onAppear { session.reloadCloudUser() }
    }
}

private struct AccountSection: View {
    @Environment(\.session) private var session

    var body: some View {
        Section("Учётная запись") {
            LabeledContent("Электронная почта", value: session.cloudUser?.email ?? "—")
            LabeledContent("Адрес подтверждён") {
                if session.cloudUser?.isConfirmed == true {
                    Label("Да", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Text("Нет").foregroundStyle(.orange)
                }
            }
            if let created = ISODate.parse(session.cloudUser?.createdAt) {
                LabeledContent("Создана", value: created.formatted(date: .abbreviated, time: .omitted))
            }
            Button("Выйти из учётной записи") { session.logout() }
            Text("После выхода данные остаются на этом Mac; при следующем входе они синхронизируются.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SyncSection: View {
    @Environment(\.session) private var session
    @State private var stats: [String: Int]?
    @State private var loading = false

    var body: some View {
        Section("Синхронизация") {
            if let sync = session.sync {
                LabeledContent("Состояние") { Label(sync.summary, systemImage: sync.icon) }
                if case .failed(let message) = sync.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if let last = sync.lastSync {
                    LabeledContent("Последняя", value: last.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Ждут отправки", value: "\(sync.pending)")
                HStack {
                    Button("Синхронизировать сейчас") { sync.syncNow() }
                        .disabled(sync.state == .syncing)
                    Button("Что в облаке?") {
                        loading = true
                        Task { stats = await session.cloudStats(); loading = false }
                    }
                    .disabled(loading)
                    if loading { ProgressView().controlSize(.small) }
                }
                if let stats {
                    Text("В облаке: лидов \(stats["leads_active"] ?? 0) (с удалёнными \(stats["leads"] ?? 0)), исключений \(stats["exclusions"] ?? 0), настроек \(stats["settings"] ?? 0).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Синхронизируются лиды и отметки (избранное, архив, удаление, просмотр, заметки), исключения, настройки поиска, интервал автопоиска и подпись. Оформление, ключ VK, пути к файлам и журнал поиска остаются на этом Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CloudPasswordSection: View {
    @Environment(\.session) private var session
    @State private var old = ""
    @State private var new = ""
    @State private var again = ""
    @State private var result: String?
    @State private var ok = false
    @State private var busy = false

    var body: some View {
        Section("Сменить пароль") {
            SecureField("Текущий пароль", text: $old)
            SecureField("Новый пароль", text: $new)
            SecureField("Повторите новый пароль", text: $again)
            Text(Validation.passwordRules).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Сменить пароль") {
                    busy = true; ok = false
                    Task {
                        result = await session.changeCloudPassword(current: old, new: new, confirm: again)
                        ok = result == nil
                        if ok { old = ""; new = ""; again = "" }
                        busy = false
                    }
                }
                .disabled(busy || old.isEmpty || new.isEmpty)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if ok { Label("Пароль изменён, другие устройства отключены", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if let result { Text(result).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct EmailChangeSection: View {
    @Environment(\.session) private var session
    @State private var newEmail = ""
    @State private var password = ""
    @State private var codeCurrent = ""
    @State private var codeNew = ""
    @State private var result: String?
    @State private var info: String?
    @State private var busy = false

    var body: some View {
        Section("Сменить адрес почты") {
            if let pending = session.cloudUser?.newEmail, !pending.isEmpty, let current = session.cloudUser?.email {
                Text("Ожидает подтверждения: \(pending). Письма отправлены на оба адреса — введите оба кода (или откройте ссылки из писем).")
                    .font(.callout)
                TextField("Код из письма на \(current)", text: $codeCurrent)
                TextField("Код из письма на \(pending)", text: $codeNew)
                HStack {
                    Button("Подтвердить") { confirm(current: current, pending: pending) }
                        .disabled(busy || (Validation.code(codeCurrent) == nil && Validation.code(codeNew) == nil))
                    Button("Отправить письма ещё раз") {
                        perform { await session.resendCloudEmailChange() } done: { info = "Письма отправлены ещё раз." }
                    }
                    .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            } else {
                TextField("Новый адрес", text: $newEmail)
                SecureField("Текущий пароль", text: $password)
                HStack {
                    Button("Сменить адрес") {
                        perform { await session.changeCloudEmail(to: newEmail, password: password) } done: {
                            password = ""
                            info = "Письма с кодами отправлены на текущий и новый адрес. Адрес сменится после подтверждения обоих."
                        }
                    }
                    .disabled(busy || newEmail.isEmpty || password.isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if let info { Text(info).font(.caption).foregroundStyle(.secondary) }
            if let result { Text(result).font(.caption).foregroundStyle(.red) }
        }
    }

    private func confirm(current: String, pending: String) {
        let pairs = [(current, codeCurrent), (pending, codeNew)].filter { Validation.code($0.1) != nil }
        perform {
            for (email, code) in pairs {
                if let e = await session.confirmCloudEmail(email: email, code: code) { return e }
            }
            return nil
        } done: {
            codeCurrent = ""; codeNew = ""
            if session.cloudUser?.newEmail?.isEmpty == false {
                info = "Код принят. Введите код из второго письма."
            } else {
                info = "Адрес изменён: \(session.cloudUser?.email ?? pending)."
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () async -> String?, done: @escaping @MainActor () -> Void) {
        busy = true; result = nil; info = nil
        Task {
            result = await action()
            if result == nil { done() }
            busy = false
        }
    }
}

private struct ImportLocalSection: View {
    @Environment(\.session) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        let accounts = session.localAccounts
        if !accounts.isEmpty {
            Section("Перенести данные локальной учётной записи") {
                Picker("Учётная запись", selection: $username) {
                    Text("Выберите…").tag("")
                    ForEach(accounts) { Text($0.username).tag($0.username) }
                }
                SecureField("Пароль локальной учётной записи", text: $password)
                HStack {
                    Button("Перенести в облако") {
                        busy = true; result = nil
                        Task {
                            result = await session.importLocal(username: username, password: password)
                            if result == nil { password = "" }
                            busy = false
                        }
                    }
                    .disabled(busy || username.isEmpty || password.isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let result { Text(result).font(.caption).foregroundStyle(.red) }
                Text("Лиды, исключения и настройки копируются в эту учётную запись и уходят в облако. Локальная учётная запись и её база не меняются. Перед переносом сохраняется резервная копия.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeleteAccountSection: View {
    @Environment(\.session) private var session
    @State private var password = ""
    @State private var asking = false
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        Section("Удалить учётную запись") {
            Text("Учётная запись и все данные в облаке будут удалены без возможности восстановления. Перед удалением база с этого Mac сохраняется в папку резервных копий.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Пароль", text: $password)
            HStack {
                Button("Удалить учётную запись…", role: .destructive) { asking = true }
                    .disabled(busy || password.isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }
            if let result { Text(result).font(.caption).foregroundStyle(.red) }
        }
        .confirmationDialog("Удалить учётную запись и все данные в облаке?", isPresented: $asking) {
            Button("Удалить", role: .destructive) {
                busy = true; result = nil
                Task {
                    result = await session.deleteCloudAccount(password: password)
                    password = ""
                    busy = false
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить.")
        }
    }
}
