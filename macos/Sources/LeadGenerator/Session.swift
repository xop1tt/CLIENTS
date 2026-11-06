import Foundation
import LeadGenCore
import Observation

/// Кто вошёл в приложение. Учётные записи сейчас локальные; позже сюда встанет вход на сервер.
@MainActor
@Observable
final class SessionModel {
    private(set) var auth: AuthService?
    private(set) var current: AppModel?
    var error: String?

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
        cleanupGitHubSecrets()
        if let auth, let name = Keychain.get(Self.rememberKey), let account = auth.account(name) {
            open(account)
        }
    }

    var hasUsers: Bool { auth?.hasUsers ?? false }

    /// Есть база версии 1.0, созданная до появления учётных записей.
    var legacyDatabase: URL? {
        let custom = UserDefaults.standard.string(forKey: "data.path").map { URL(fileURLWithPath: $0) }
        let url = custom ?? Self.rootDirectory.appendingPathComponent("leads.db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

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
        current?.shutdown()
        current = nil
        Keychain.set(Self.rememberKey, "")
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
        current?.shutdown()
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
