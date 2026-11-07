import Foundation

/// Ключ шифрования локальной базы (SQLCipher, AES-256): 32 случайных байта.
/// Передаётся в SQLCipher как «сырой» ключ (`x'…'`), без медленного вывода ключа из пароля.
public struct DatabaseKey: Equatable, Sendable, CustomStringConvertible {
    /// 64 шестнадцатеричных символа в нижнем регистре.
    public let hex: String

    public init?(hex raw: String) {
        let h = raw.lowercased()
        guard h.count == 64, h.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        hex = h
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        hex = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Новый случайный ключ. `SystemRandomNumberGenerator` криптографически стойкий
    /// на всех платформах (arc4random_buf на macOS, getrandom на Linux).
    public static func random() -> DatabaseKey {
        var rng = SystemRandomNumberGenerator()
        return DatabaseKey(bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) })!
    }

    /// Значение для `PRAGMA key` и `ATTACH … KEY`. В нём только [0-9a-f], экранировать нечего.
    var sqlLiteral: String { "x'\(hex)'" }

    /// Ключ не попадает в журналы и сообщения об ошибках.
    public var description: String { "DatabaseKey(…)" }
}

/// Источник ключа базы. В приложении — Связка ключей macOS, в тестах — ключ в памяти.
public protocol DatabaseKeyProvider: Sendable {
    func databaseKey() throws -> DatabaseKey
}

public struct DatabaseEncryptionError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Открытие зашифрованной базы и перевод старых (незашифрованных) баз в зашифрованные.
public enum EncryptedDatabase {
    /// Первые 16 байт любого незашифрованного файла SQLite. У файла SQLCipher заголовок случайный.
    static let plainHeader = Array("SQLite format 3\u{0}".utf8)

    public enum FileState: Equatable { case missing, empty, plaintext, encrypted }

    public static func state(of path: String) -> FileState {
        guard let h = FileHandle(forReadingAtPath: path) else { return .missing }
        defer { try? h.close() }
        let head = [UInt8]((try? h.read(upToCount: 16)) ?? Data())
        if head.isEmpty { return .empty }
        return head == plainHeader ? .plaintext : .encrypted
    }

    /// Временный файл миграции (зашифрованная копия, которая ещё не заняла место базы).
    static func stagingPath(_ path: String) -> String { path + ".encrypting" }
    /// Исходный незашифрованный файл на время замены. Удаляется только после проверки новой базы.
    static func plaintextPath(_ path: String) -> String { path + ".unencrypted" }

    /// Открывает базу по `path` с ключом `key`. Незашифрованная база (версии до шифрования)
    /// сначала переписывается в зашифрованную; данные проверяются до удаления исходного файла.
    /// Если программа прервалась посреди замены, при следующем запуске замена доводится до конца
    /// или откатывается к исходному файлу — данные не теряются ни в одной точке.
    public static func open(path: String, key: DatabaseKey) throws -> SQLiteDB {
        try recoverInterruptedMigration(path: path, key: key)
        switch state(of: path) {
        case .missing, .empty, .encrypted:
            return try SQLiteDB(path: path, key: key)
        case .plaintext:
            try migrate(path: path, key: key)
            return try SQLiteDB(path: path, key: key)
        }
    }

    /// Переписывает незашифрованную базу `path` в зашифрованную на том же месте.
    static func migrate(path: String, key: DatabaseKey) throws {
        let fm = FileManager.default
        let staging = stagingPath(path), plain = plaintextPath(path)
        removeDatabaseFiles(staging)

        // 1. Зашифрованная копия рядом. Источник открыт обычным соединением: оно видит и
        //    данные из журнала WAL, если прошлый сеанс не успел их перенести в основной файл.
        let source = try SQLiteDB(path: path)
        let counts: [String: Int64]
        do {
            counts = try rowCounts(source)
            let userVersion = try source.scalar("PRAGMA user_version").int ?? 0
            try source.run("ATTACH DATABASE ? AS encrypted KEY ?", [.text(staging), .text(key.sqlLiteral)])
            _ = try source.query("SELECT sqlcipher_export('encrypted')")
            // sqlcipher_export не переносит user_version.
            try source.exec("PRAGMA encrypted.user_version = \(userVersion)")
            try source.exec("DETACH DATABASE encrypted")
        } catch {
            source.close()
            removeDatabaseFiles(staging)
            throw DatabaseEncryptionError(message: "Не удалось зашифровать базу \(path): \(error.localizedDescription). Исходный файл не изменён.")
        }
        source.close()

        // 2. Копия открывается ключом и совпадает с исходной по числу строк в каждой таблице.
        do {
            try verify(staging, key: key, expected: counts)
        } catch {
            removeDatabaseFiles(staging)
            throw DatabaseEncryptionError(message: "Зашифрованная копия базы не прошла проверку: \(error.localizedDescription). Исходный файл не изменён.")
        }

        // 3. Замена: исходный файл (вместе с -wal/-shm) отходит в сторону, копия встаёт на его место.
        //    Старый -wal нельзя оставлять рядом с новой базой: SQLite попытался бы применить его к ней.
        removeDatabaseFiles(plain)
        try fm.moveItem(atPath: path, toPath: plain)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try fm.moveItem(atPath: path + suffix, toPath: plain + suffix)
        }
        do {
            try fm.moveItem(atPath: staging, toPath: path)
        } catch {
            try? fm.moveItem(atPath: plain, toPath: path)
            for suffix in ["-wal", "-shm"] { try? fm.moveItem(atPath: plain + suffix, toPath: path + suffix) }
            throw error
        }

        // 4. Исходный файл удаляется только после того, как база на месте открылась ключом.
        try verify(path, key: key, expected: counts)
        removeDatabaseFiles(plain)
    }

    /// Доводит до конца или откатывает замену, прерванную на шаге 3–4.
    static func recoverInterruptedMigration(path: String, key: DatabaseKey) throws {
        let fm = FileManager.default
        let staging = stagingPath(path), plain = plaintextPath(path)
        guard fm.fileExists(atPath: plain) else {
            removeDatabaseFiles(staging)  // недописанная копия с шагов 1–2: исходник не тронут
            return
        }
        switch state(of: path) {
        case .missing, .empty:
            // Исходник уже отодвинут, а копия не встала на место: возвращаем исходник,
            // миграция начнётся заново.
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
            try fm.moveItem(atPath: plain, toPath: path)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: plain + suffix) {
                try? fm.removeItem(atPath: path + suffix)
                try fm.moveItem(atPath: plain + suffix, toPath: path + suffix)
            }
            removeDatabaseFiles(staging)
        case .encrypted:
            // Копия уже на месте. Исходник удаляем, только если база открывается ключом.
            let db = try SQLiteDB(path: path, key: key)
            db.close()
            removeDatabaseFiles(plain)
            removeDatabaseFiles(staging)
        case .plaintext:
            // На месте снова незашифрованная база (например, её вернули вручную): её данные новее,
            // отложенный файл оставляем как есть под другим именем, чтобы ничего не потерять.
            let keep = path + ".unencrypted-\(Int(Date().timeIntervalSince1970))"
            try fm.moveItem(atPath: plain, toPath: keep)
            removeDatabaseFiles(staging)
        }
    }

    /// Число строк в каждой пользовательской таблице.
    static func rowCounts(_ db: SQLiteDB) throws -> [String: Int64] {
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            .compactMap { $0["name"]?.string }
        var out: [String: Int64] = [:]
        for t in tables {
            let quoted = "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            out[t] = try db.scalar("SELECT count(*) FROM \(quoted)").int ?? 0
        }
        return out
    }

    static func verify(_ path: String, key: DatabaseKey, expected: [String: Int64]) throws {
        let db = try SQLiteDB(path: path, readOnly: true, key: key)
        defer { db.close() }
        guard try db.scalar("PRAGMA quick_check").string == "ok" else {
            throw DatabaseEncryptionError(message: "проверка целостности не пройдена")
        }
        let actual = try rowCounts(db)
        guard actual == expected else {
            throw DatabaseEncryptionError(message: "число записей не совпадает с исходной базой")
        }
    }

    static func removeDatabaseFiles(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
}
