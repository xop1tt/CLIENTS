// Ключ локальной базы в Связке ключей macOS. На Linux (тестовый стенд) ключ передают явно.
#if canImport(Security)
import Foundation
import Security

/// Один ключ на все локальные базы этого пользователя macOS: базы учётных записей, резервные
/// копии и перенос данных между учётными записями открываются одним и тем же ключом.
/// Ключ создаётся при первом запуске и больше не меняется.
public final class KeychainDatabaseKeyProvider: DatabaseKeyProvider, @unchecked Sendable {
    public static let shared = KeychainDatabaseKeyProvider()

    let service: String
    let account: String
    private let lock = NSLock()
    private var cached: DatabaseKey?

    public init(service: String = "LeadGenerator", account: String = "database.key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func databaseKey() throws -> DatabaseKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let existing = try read() {
            cached = existing
            return existing
        }
        // Ключа нет (именно «не найден», а не «доступ запрещён»): создаём новый.
        let key = DatabaseKey.random()
        var add = query
        add[kSecValueData as String] = Data(key.hex.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Customers: ключ шифрования базы лидов"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Self.error("Не удалось сохранить ключ базы в Связку ключей", status)
        }
        // Базу шифруем только ключом, который действительно читается из Связки ключей:
        // иначе после перезапуска её нечем было бы открыть.
        guard let stored = try read() else {
            throw DatabaseEncryptionError(message: "Ключ базы не читается из Связки ключей после сохранения")
        }
        cached = stored
        return stored
    }

    /// nil — ключа нет. Любая другая ошибка (Связка заблокирована, доступ отклонён) — исключение:
    /// в этом случае новый ключ создавать нельзя, иначе существующую базу нечем будет открыть.
    private func read() throws -> DatabaseKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.error("Нет доступа к ключу базы в Связке ключей", status) }
        guard let data = out as? Data, let text = String(data: data, encoding: .utf8), let key = DatabaseKey(hex: text) else {
            throw DatabaseEncryptionError(message: "Ключ базы в Связке ключей повреждён. Новый ключ не создан, чтобы не потерять доступ к базе.")
        }
        return key
    }

    static func error(_ text: String, _ status: OSStatus) -> DatabaseEncryptionError {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "код \(status)"
        return DatabaseEncryptionError(message: "\(text): \(detail)")
    }

    /// Только для тестов: удалить ключ из Связки ключей.
    func deleteForTesting() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        SecItemDelete(query as CFDictionary)
    }
}
#endif
