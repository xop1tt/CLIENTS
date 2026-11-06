import Foundation
import LeadCloud
import LeadGenCore
import Observation

/// Этап экрана входа для облачной учётной записи.
enum AuthStage: Equatable {
    case signIn
    case signUp
    case confirm(email: String)          // ввод кода из письма регистрации
    case forgot                          // ввод адреса для восстановления
    case reset(email: String)            // код восстановления + новый пароль
    case newPassword                     // вход по ссылке восстановления: задать новый пароль
    case local                           // локальная учётная запись (без облака)
}

/// Кто вошёл в приложение: облачная учётная запись (Supabase) или локальная (только этот Mac).
@MainActor
@Observable
final class SessionModel {
    private(set) var auth: AuthService?
    let cloudConfig: CloudConfig?
    private(set) var cloud: CloudAuth?
    private(set) var cloudUser: CloudUser?
    private(set) var sync: CloudSyncController?
    private(set) var current: AppModel?
    var stage: AuthStage = .signIn
    var error: String?
    var info: String?
    private(set) var busy = false

    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lead Generator", isDirectory: true)
    }

    private static let rememberKey = "session.user"

    init() {
        do {
            auth = try LocalAuthService(root: Self.rootDirectory)
        } catch {
            self.error = "Не удалось открыть учётные записи: \(error.localizedDescription)"
        }
        // Адрес сервера и публичный ключ встраиваются при сборке; для разработки их можно
        // задать в UserDefaults (defaults write local.leadgenerator.app LGSupabaseURL …).
        let d = UserDefaults.standard
        cloudConfig = CloudConfig.fromBundle()
            ?? CloudConfig(url: d.string(forKey: "LGSupabaseURL") ?? "", anonKey: d.string(forKey: "LGSupabaseAnonKey") ?? "")
        if let cloudConfig {
            let c = CloudAuth(config: cloudConfig, store: KeychainSessionStore(), deviceID: DeviceIdentity.id)
            cloud = c
            // Сессия из Связки ключей: данные открываются сразу, даже без сети; токен обновится в фоне.
            if let saved = KeychainSessionStore().load() {
                openCloud(saved.user)
                Task { await self.revalidate() }
            }
        } else {
            stage = .local
        }
        cleanupGitHubSecrets()
        if current == nil, let auth, let name = Keychain.get(Self.rememberKey), !name.isEmpty, let account = auth.account(name) {
            open(account)
        }
    }

    var cloudAvailable: Bool { cloud != nil }
    var hasUsers: Bool { auth?.hasUsers ?? false }
    var isCloudSession: Bool { current?.isCloud == true }

    /// Есть база версии 1.0, созданная до появления учётных записей.
    var legacyDatabase: URL? {
        let custom = UserDefaults.standard.string(forKey: "data.path").map { URL(fileURLWithPath: $0) }
        let url = custom ?? Self.rootDirectory.appendingPathComponent("leads.db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Облако — вход и регистрация

    /// Выполнить облачную операцию с индикатором и понятной ошибкой.
    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do { try await body() } catch { self.error = error.localizedDescription }
            self.busy = false
        }
    }

    func cloudSignIn(email: String, password: String) {
        guard let cloud else { return }
        run {
            do {
                let s = try await cloud.signIn(email: email, password: password)
                self.openCloud(s.user)
            } catch CloudError.emailNotConfirmed {
                self.stage = .confirm(email: email.trimmingCharacters(in: .whitespaces).lowercased())
                self.info = "Адрес ещё не подтверждён. Введите код из письма или запросите новое письмо."
            }
        }
    }

    func cloudSignUp(email: String, password: String, confirm: String) {
        guard let cloud else { return }
        guard password == confirm else { error = CloudError.passwordsDiffer.localizedDescription; return }
        run {
            try await cloud.signUp(email: email, password: password)
            if let user = await cloud.user {
                self.openCloud(user)  // на сервере выключено подтверждение почты
                return
            }
            let e = Validation.normalizedEmail(email) ?? email
            self.stage = .confirm(email: e)
            self.info = "Мы отправили письмо с кодом на \(e). Если аккаунт с этим адресом уже есть, просто войдите."
        }
    }

    func confirmSignUp(email: String, code: String) {
        guard let cloud else { return }
        run {
            guard let s = try await cloud.verify(email: email, code: code, type: "signup") else { throw CloudError.invalidCode }
            self.info = nil
            self.openCloud(s.user)
        }
    }

    func resendConfirmation(email: String) {
        guard let cloud else { return }
        run {
            try await cloud.resendConfirmation(email: email)
            self.info = "Письмо отправлено ещё раз. Проверьте и папку «Спам»."
        }
    }

    func requestReset(email: String) {
        guard let cloud else { return }
        run {
            try await cloud.requestPasswordReset(email: email)
            let e = Validation.normalizedEmail(email) ?? email
            self.stage = .reset(email: e)
            self.info = "Если аккаунт с адресом \(e) существует, на него придёт письмо с кодом."
        }
    }

    func finishReset(email: String, code: String, password: String, confirm: String) {
        guard let cloud else { return }
        guard password == confirm else { error = CloudError.passwordsDiffer.localizedDescription; return }
        if let p = Validation.passwordProblem(password) { error = p; return }
        run {
            guard try await cloud.verify(email: email, code: code, type: "recovery") != nil else { throw CloudError.invalidCode }
            try await cloud.setNewPassword(password)
            self.info = nil
            if let u = await cloud.user { self.openCloud(u) }
        }
    }

    /// Новый пароль после входа по ссылке восстановления.
    func setPasswordAfterRecovery(_ password: String, confirm: String) {
        guard let cloud else { return }
        guard password == confirm else { error = CloudError.passwordsDiffer.localizedDescription; return }
        run {
            try await cloud.setNewPassword(password)
            self.info = nil
            if let u = await cloud.user { self.openCloud(u) }
        }
    }

    /// Ссылка из письма: leadgenerator://auth/callback#…
    func handle(url: URL) {
        guard let cloud, url.scheme == "leadgenerator" else { return }
        run {
            switch try await cloud.handleCallback(url) {
            case .signedIn(let type):
                if type == "recovery" {
                    self.closeCurrent()
                    self.stage = .newPassword
                    self.info = "Задайте новый пароль."
                } else if let u = await cloud.user {
                    if self.isCloudSession, self.cloudUser?.id == u.id {
                        self.cloudUser = u
                        self.current?.lastMessage = type == "email_change" ? "Адрес почты изменён" : "Адрес подтверждён"
                    } else {
                        self.openCloud(u)
                    }
                }
            case .message:
                self.info = "Первая ссылка принята. Подтвердите смену адреса и по ссылке из второго письма."
                self.current?.lastMessage = self.info
            }
        }
    }

    /// Проверить сохранённую сессию на сервере. Отозванная — выход с понятным сообщением.
    private func revalidate() async {
        guard let cloud else { return }
        do {
            let u = try await cloud.reloadUser()
            cloudUser = u
        } catch CloudError.sessionExpired {
            sessionExpired()
        } catch {
            // Нет сети — продолжаем работать с локальными данными.
        }
    }

    private func sessionExpired() {
        guard isCloudSession else { return }
        closeCurrent()
        stage = .signIn
        error = CloudError.sessionExpired.localizedDescription
    }

    private func openCloud(_ user: CloudUser) {
        closeCurrent()
        cloudUser = user
        error = nil
        let id = "cloud-\(user.id.lowercased())"
        let dir = Self.rootDirectory.appendingPathComponent("users", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        let model = AppModel(username: id, displayName: user.email, isCloud: true, dataDirectory: dir)
        current = model
        if let cloud {
            let controller = CloudSyncController(auth: cloud, model: model)
            controller.onSessionExpired = { [weak self] in self?.sessionExpired() }
            sync = controller
            controller.start()
        }
        stage = .signIn
    }

    // MARK: Облако — управление учётной записью

    func reloadCloudUser() {
        guard let cloud else { return }
        Task { if let u = try? await cloud.reloadUser() { self.cloudUser = u } }
    }

    func changeCloudPassword(current old: String, new: String, confirm: String) async -> String? {
        guard let cloud else { return CloudError.notConfigured.localizedDescription }
        guard new == confirm else { return CloudError.passwordsDiffer.localizedDescription }
        do { try await cloud.changePassword(current: old, new: new); return nil } catch { return error.localizedDescription }
    }

    func changeCloudEmail(to email: String, password: String) async -> String? {
        guard let cloud else { return CloudError.notConfigured.localizedDescription }
        do {
            try await cloud.changeEmail(to: email, password: password)
            cloudUser = await cloud.user
            return nil
        } catch { return error.localizedDescription }
    }

    func confirmCloudEmail(email: String, code: String) async -> String? {
        guard let cloud else { return CloudError.notConfigured.localizedDescription }
        do {
            try await cloud.confirmEmailChange(email: email, code: code)
            cloudUser = await cloud.user
            return nil
        } catch { return error.localizedDescription }
    }

    func resendCloudEmailChange() async -> String? {
        guard let cloud else { return CloudError.notConfigured.localizedDescription }
        do { try await cloud.resendEmailChange(); return nil } catch { return error.localizedDescription }
    }

    /// Удаление облачной учётной записи. Локальная копия базы остаётся в папке резервных копий.
    func deleteCloudAccount(password: String) async -> String? {
        guard let cloud, let model = current, model.isCloud else { return nil }
        // Сначала локальная копия: без неё удалять нельзя.
        guard let backup = model.backupNow() else {
            return "Не удалось сохранить резервную копию базы, учётная запись не удалена. \(model.lastError ?? "")"
        }
        do {
            try await cloud.deleteAccount(password: password)
        } catch { return error.localizedDescription }
        closeCurrent()
        // Локальные данные удалённой учётной записи убираются с этого Mac; копия — в резервных копиях.
        let dir = URL(fileURLWithPath: model.defaultDatabasePath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
        stage = .signIn
        info = "Учётная запись удалена вместе с данными в облаке."
            + " Копия базы сохранена: \(backup.path)"
        return nil
    }

    /// Сколько данных лежит в облаке (для сверки после переноса).
    func cloudStats() async -> [String: Int]? {
        guard let cloud, let store = current?.store, current?.isCloud == true else { return nil }
        return try? await SyncEngine(auth: cloud, store: store, deviceID: DeviceIdentity.id).remoteStats()
    }

    // MARK: Перенос локальной учётной записи в облако

    /// Локальные учётные записи на этом Mac (для переноса их лидов в облако).
    var localAccounts: [UserAccount] { (auth as? LocalAuthService)?.allAccounts() ?? [] }

    /// Копирует лиды, исключения и настройки локальной учётной записи в открытую облачную.
    /// Исходная база не меняется (она и есть резервная копия). Записи, которые уже есть в
    /// облаке и менялись там, не затираются: перенесённым данным даётся раннее время изменения.
    func importLocal(username: String, password: String) async -> String? {
        guard let auth, let model = current, model.isCloud, let target = model.store else { return nil }
        do { _ = try auth.login(username: username, password: password) } catch { return error.localizedDescription }
        let source = auth.dataDirectory(for: username).appendingPathComponent("leads.db")
        let customPath = UserDefaults.standard.string(forKey: "data.path.\(username.lowercased())")
        let path = customPath ?? source.path
        guard FileManager.default.fileExists(atPath: path) else { return "У этой учётной записи нет базы лидов." }
        do {
            model.backupNow()
            let src = try LeadStore(path: path)
            defer { src.db.close() }
            let total = try src.allLeads(includeDeleted: true).count
            let count = try target.importFrom(src)
            model.reload()
            model.reloadSyncedSettings()
            sync?.syncNow()
            model.lastMessage = "Перенесено лидов: \(count) из \(total) (остальные уже были). Исходная база не изменена."
            return nil
        } catch { return "Перенос не удался: \(error.localizedDescription)" }
    }

    // MARK: Локальные учётные записи

    func register(username: String, password: String, confirm again: String, remember: Bool) {
        guard let auth else { return }
        guard password == again else { error = AuthError.passwordsDiffer.localizedDescription; return }
        do {
            let first = !auth.hasUsers
            let account = try auth.register(username: username, password: password)
            let migrationError = first ? adoptLegacyDatabase(for: account.username) : nil
            finish(account, remember: remember)
            // Ошибку переноса старой базы показываем после входа: повторно перенос не запускается.
            if let migrationError { current?.lastError = migrationError }
        } catch { self.error = error.localizedDescription }
    }

    func login(username: String, password: String, remember: Bool) {
        guard let auth else { return }
        do { finish(try auth.login(username: username, password: password), remember: remember) }
        catch { self.error = error.localizedDescription }
    }

    func logout() {
        if current?.isCloud == false {
            Keychain.set(Self.rememberKey, "")
        } else if let cloud {
            // Облачная сессия (в том числе после входа по ссылке восстановления) отзывается.
            Task { await cloud.signOut() }
        }
        closeCurrent()
        stage = cloudAvailable ? .signIn : .local
    }

    private func closeCurrent() {
        sync?.stop()
        sync = nil
        current?.shutdown()
        current = nil
        cloudUser = nil
    }

    func changePassword(old: String, new: String, confirm again: String) -> String? {
        guard let auth, let user = current?.username else { return nil }
        guard new == again else { return AuthError.passwordsDiffer.localizedDescription }
        do { try auth.changePassword(username: user, old: old, new: new); return nil }
        catch { return error.localizedDescription }
    }

    var remembered: Bool { Keychain.get(Self.rememberKey)?.isEmpty == false }

    func setRemembered(_ on: Bool) {
        Keychain.set(Self.rememberKey, on ? (current?.username ?? "") : "")
    }

    private func finish(_ account: UserAccount, remember: Bool) {
        error = nil
        Keychain.set(Self.rememberKey, remember ? account.username : "")
        open(account)
    }

    private func open(_ account: UserAccount) {
        guard let auth else { return }
        closeCurrent()
        current = AppModel(username: account.username, dataDirectory: auth.dataDirectory(for: account.username))
    }

    /// Первая учётная запись получает лиды из базы версии 1.0. Исходный файл остаётся рядом под другим именем.
    private func adoptLegacyDatabase(for username: String) -> String? {
        guard let auth, let legacy = legacyDatabase else { return nil }
        let target = auth.dataDirectory(for: username).appendingPathComponent("leads.db")
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            let old = try LeadStore(path: legacy.path)
            try old.backup(to: target)
            old.db.close()
            let renamed = legacy.deletingLastPathComponent().appendingPathComponent("leads-1.0-backup.db")
            try? FileManager.default.removeItem(at: renamed)
            try FileManager.default.moveItem(at: legacy, to: renamed)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: legacy.path + suffix) }
            UserDefaults.standard.removeObject(forKey: "data.path")
            return nil
        } catch {
            return "Лиды из прежней версии не перенесены: \(error.localizedDescription). Файл остался на месте: \(legacy.path). Его можно открыть через «Настройки → Данные → Восстановить из файла…»."
        }
    }

    /// Токен GitHub и ключ шифрования из версии 1.0 больше не нужны — убираем их из Связки ключей.
    private func cleanupGitHubSecrets() {
        let flag = "cleanup.github.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        Keychain.set("github.token", "")
        Keychain.set("state.secret", "")
        for k in ["sync.owner", "sync.repo", "sync.branch", "sync.interval"] { UserDefaults.standard.removeObject(forKey: k) }
        UserDefaults.standard.set(true, forKey: flag)
    }
}
