import Foundation
import XCTest
@testable import LeadGenCore

/// Шифрование локальной базы (SQLCipher) и перевод старых незашифрованных баз.
/// Идёт на macOS (`swift test`) и на Linux (scripts/linux-cloud-tests.sh, libsqlcipher-dev).
final class DatabaseEncryptionTests: XCTestCase {
    var dir: URL!
    let key = DatabaseKey.random()

    /// Строки, которых не должно быть в файлах зашифрованной базы открытым текстом.
    static let secretEmail = "director.secret@example-client.ru"
    static let secretNote = "перезвонить Ивановой после обеда"
    static let secretTitle = "Сайт для клиники Лаванда-Секрет"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func path(_ name: String = "leads.db") -> String { dir.appendingPathComponent(name).path }

    static func lead(_ title: String = secretTitle) -> LeadData {
        LeadData(kind: .organization, source: "osm", externalId: "1", title: title,
                 discoveredAt: Date(timeIntervalSince1970: 1_790_000_000),
                 contacts: ["email": secretEmail], phone: "+7 900 123-45-67", score: 80, relevance: .high)
    }

    /// Заполняет базу всем, что пользователь хранит: лид, избранное, заметка, исключение, настройка.
    func fill(_ store: LeadStore) throws {
        try store.save(Self.lead(), id: "L1", fingerprint: "fp1")
        try store.save(Self.lead("Второй лид"), id: "L2", fingerprint: "fp2")
        try store.setFavorite(["L1"], true)
        try store.setNote("L1", Self.secretNote)
        try store.addExclusion(.email, Self.secretEmail)
        try store.setValue("draft.signature", "Максим")
        try store.logEvent("L1", "opened")
    }

    func assertFilled(_ store: LeadStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let leads = try store.allLeads(includeDeleted: true).sorted { $0.id < $1.id }
        XCTAssertEqual(leads.map(\.id), ["L1", "L2"], file: file, line: line)
        XCTAssertEqual(leads[0].data.title, Self.secretTitle, file: file, line: line)
        XCTAssertEqual(leads[0].data.emails, [Self.secretEmail], file: file, line: line)
        XCTAssertTrue(leads[0].favorite, file: file, line: line)
        XCTAssertEqual(leads[0].note, Self.secretNote, file: file, line: line)
        XCTAssertEqual(try store.exclusions().map(\.value), [Normalize.email(Self.secretEmail)], file: file, line: line)
        XCTAssertEqual(store.value("draft.signature"), "Максим", file: file, line: line)
        XCTAssertEqual(try store.events(for: "L1").first?.action, "opened", file: file, line: line)
    }

    /// Все файлы базы (сама база, -wal, -shm) не содержат ни одной из секретных строк.
    func assertNoPlaintext(at path: String, file: StaticString = #filePath, line: UInt = #line) {
        for suffix in ["", "-wal", "-shm"] {
            guard let data = FileManager.default.contents(atPath: path + suffix) else { continue }
            for secret in [Self.secretEmail, Self.secretNote, Self.secretTitle, "Максим"] {
                XCTAssertNil(data.range(of: Data(secret.utf8)), "«\(secret)» открытым текстом в \(path + suffix)",
                             file: file, line: line)
            }
        }
    }

    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".encrypting") || $0.contains(".unencrypted") }
    }

    func makePlaintextStore(_ name: String = "leads.db") throws -> String {
        let p = path(name)
        let store = try LeadStore(path: p)
        try fill(store)
        store.db.close()
        XCTAssertEqual(EncryptedDatabase.state(of: p), .plaintext)
        return p
    }

    // MARK: - Библиотека

    func testLibraryIsSQLCipher() throws {
        let db = try SQLiteDB(path: path("probe.db"))
        XCTAssertNotNil(db.cipherVersion, "ядро собрано с SQLCipher, а не с обычным SQLite")
    }

    // MARK: - Ключ

    func testKeyValidation() {
        XCTAssertNotNil(DatabaseKey(hex: String(repeating: "ab", count: 32)))
        XCTAssertEqual(DatabaseKey(hex: String(repeating: "AB", count: 32))?.hex, String(repeating: "ab", count: 32))
        XCTAssertNil(DatabaseKey(hex: String(repeating: "ab", count: 31)), "короткий ключ")
        XCTAssertNil(DatabaseKey(hex: String(repeating: "ab", count: 33)), "длинный ключ")
        XCTAssertNil(DatabaseKey(hex: String(repeating: "zz", count: 32)), "не шестнадцатеричный")
        XCTAssertNil(DatabaseKey(hex: String(repeating: "a'", count: 32)), "кавычка не пролезает в SQL")
        XCTAssertNil(DatabaseKey(hex: String(repeating: "٣", count: 64)), "только ASCII-цифры")
        XCTAssertNil(DatabaseKey(bytes: [UInt8](repeating: 1, count: 16)))
        XCTAssertEqual(DatabaseKey(bytes: [UInt8](repeating: 0x0f, count: 32))?.hex, String(repeating: "0f", count: 32))
    }

    func testRandomKeysDifferAndAreNotPrinted() {
        let keys = Set((0..<50).map { _ in DatabaseKey.random().hex })
        XCTAssertEqual(keys.count, 50)
        XCTAssertTrue(keys.allSatisfy { $0.count == 64 })
        XCTAssertFalse("\(key)".contains(key.hex), "ключ не попадает в журналы")
        XCTAssertFalse(String(reflecting: key).contains(key.hex))
    }

    // MARK: - Новая база

    func testNewDatabaseIsEncrypted() throws {
        let p = path()
        let store = try LeadStore(path: p, key: key)
        XCTAssertTrue(store.isEncrypted)
        try fill(store)
        try store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertEqual(EncryptedDatabase.state(of: p), .encrypted)
        assertNoPlaintext(at: p)
        store.db.close()
        assertNoPlaintext(at: p)
        try assertFilled(try LeadStore(path: p, key: key))
    }

    func testWalOfOpenDatabaseIsEncrypted() throws {
        let p = path()
        let store = try LeadStore(path: p, key: key)
        try fill(store)
        // Соединение открыто: свежие записи лежат в -wal. Он тоже зашифрован.
        assertNoPlaintext(at: p)
        try assertFilled(store)
    }

    func testEncryptedDatabaseDoesNotOpenWithoutKeyOrWithWrongKey() throws {
        let p = path()
        do { let s = try LeadStore(path: p, key: key); try fill(s); s.db.close() }
        let before = try Data(contentsOf: URL(fileURLWithPath: p))

        XCTAssertThrowsError(try LeadStore(path: p), "без ключа база не читается")
        XCTAssertThrowsError(try LeadStore(path: p, key: DatabaseKey.random())) { error in
            XCTAssertTrue(error.localizedDescription.contains("ключ не подходит"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains(self.key.hex), "ключ не попадает в сообщение")
        }
        XCTAssertThrowsError(try SQLiteDB(path: p, readOnly: true, key: DatabaseKey.random()))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)), before, "неудачные попытки не меняют файл")
        try assertFilled(try LeadStore(path: p, key: key))
    }

    func testSecondConnectionWithSameKeySeesData() throws {
        let p = path()
        let ui = try LeadStore(path: p, key: key)
        try fill(ui)
        // Поиск и синхронизация работают через свои соединения.
        let search = try LeadStore(path: p, key: key)
        try assertFilled(search)
        try search.setNote("L2", "из второго соединения")
        XCTAssertEqual(try ui.allLeads().first { $0.id == "L2" }?.note, "из второго соединения")
    }

    func testEmptyFileBecomesEncryptedDatabase() throws {
        let p = path()
        FileManager.default.createFile(atPath: p, contents: Data())
        XCTAssertEqual(EncryptedDatabase.state(of: p), .empty)
        let store = try LeadStore(path: p, key: key)
        try fill(store)
        store.db.close()
        XCTAssertEqual(EncryptedDatabase.state(of: p), .encrypted)
        XCTAssertEqual(try leftovers(), [])
    }

    func testStoreWithoutKeyStaysPlaintext() throws {
        // Старое поведение без ключа не меняется (на нём построены прежние тесты).
        let p = try makePlaintextStore()
        let store = try LeadStore(path: p)
        XCTAssertFalse(store.isEncrypted)
        try assertFilled(store)
        XCTAssertEqual(EncryptedDatabase.state(of: p), .plaintext)
    }

    // MARK: - Перевод старых баз

    func testPlaintextDatabaseIsMigratedWithoutDataLoss() throws {
        let p = try makePlaintextStore()
        let store = try LeadStore(path: p, key: key)
        try assertFilled(store)
        XCTAssertEqual(EncryptedDatabase.state(of: p), .encrypted)
        XCTAssertEqual(try leftovers(), [], "временные и исходные файлы убраны")
        store.db.close()
        assertNoPlaintext(at: p)
        // Повторное открытие — уже без миграции.
        let again = try LeadStore(path: p, key: key)
        try assertFilled(again)
        XCTAssertEqual(again.value("schema_version"), "2")
    }

    func testMigrationKeepsSyncJournalAndFlags() throws {
        let p = path()
        do {
            let s = try LeadStore(path: p)
            try s.enableSyncTracking()
            try fill(s)
            s.db.close()
        }
        let plain = try LeadStore(path: p)
        let pendingBefore = try plain.pendingChanges(limit: 100)
        plain.db.close()
        let store = try LeadStore(path: p, key: key)
        XCTAssertTrue(store.syncTracking, "флаг облака переехал вместе с базой")
        let pending = try store.pendingChanges(limit: 100)
        XCTAssertEqual(pending.leads.map(\.lead_id).sorted(), pendingBefore.leads.map(\.lead_id).sorted())
        XCTAssertEqual(pending.leads.count, 2)
    }

    func testMigrationReadsUncheckpointedWal() throws {
        // Прошлый сеанс завершился аварийно: часть данных только в -wal.
        let src = path("live.db")
        let live = try LeadStore(path: src)
        try live.db.exec("PRAGMA wal_autocheckpoint=0")
        try fill(live)
        let p = path()
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(atPath: src + suffix, toPath: p + suffix)
        }
        live.db.close()
        let store = try LeadStore(path: p, key: key)
        try assertFilled(store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p + "-wal") &&
                       (FileManager.default.contents(atPath: p + "-wal")?.range(of: Data(Self.secretEmail.utf8)) != nil),
                       "старый незашифрованный -wal не остаётся рядом с новой базой")
        store.db.close()
        assertNoPlaintext(at: p)
        XCTAssertEqual(try leftovers(), [])
    }

    func testMigrationPreservesUserVersionAndCustomTables() throws {
        let p = path()
        do {
            let db = try SQLiteDB(path: p)
            try db.exec("PRAGMA user_version = 7; CREATE TABLE \"odd \"\"name\" (v TEXT); INSERT INTO \"odd \"\"name\" VALUES ('x'), ('y');")
            db.close()
        }
        let db = try EncryptedDatabase.open(path: p, key: key)
        XCTAssertEqual(try db.scalar("PRAGMA user_version").int, 7)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM \"odd \"\"name\"").int, 2)
    }

    func testFailedMigrationLeavesOriginalUntouched() throws {
        // Файл с заголовком SQLite, но испорченным содержимым: переписать его нельзя.
        let p = path()
        var junk = Data(EncryptedDatabase.plainHeader)
        junk.append(Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try junk.write(to: URL(fileURLWithPath: p))
        XCTAssertThrowsError(try LeadStore(path: p, key: key))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p)), junk, "исходный файл не изменён")
        XCTAssertEqual(try leftovers(), [], "недописанная копия убрана")
    }

    func testRecoveryWhenCrashedAfterOriginalWasMovedAside() throws {
        // Сбой между «исходник отодвинут» и «копия на месте»: базы по пути нет.
        let p = try makePlaintextStore()
        try FileManager.default.moveItem(atPath: p, toPath: EncryptedDatabase.plaintextPath(p))
        FileManager.default.createFile(atPath: EncryptedDatabase.stagingPath(p), contents: Data("half".utf8))
        let store = try LeadStore(path: p, key: key)
        try assertFilled(store)
        XCTAssertEqual(EncryptedDatabase.state(of: p), .encrypted)
        XCTAssertEqual(try leftovers(), [])
    }

    func testRecoveryWhenCrashedAfterSwapBeforeCleanup() throws {
        // Сбой после замены: зашифрованная база на месте, исходник ещё лежит рядом.
        let p = try makePlaintextStore()
        let plainCopy = path("copy.db")
        try FileManager.default.copyItem(atPath: p, toPath: plainCopy)
        do { let s = try LeadStore(path: p, key: key); s.db.close() }
        try FileManager.default.moveItem(atPath: plainCopy, toPath: EncryptedDatabase.plaintextPath(p))
        let store = try LeadStore(path: p, key: key)
        try assertFilled(store)
        XCTAssertEqual(try leftovers(), [], "незашифрованный исходник удалён после проверки")
    }

    func testRecoveryKeepsBothFilesIfEncryptedOneDoesNotOpen() throws {
        let p = try makePlaintextStore()
        let plainCopy = path("copy.db")
        try FileManager.default.copyItem(atPath: p, toPath: plainCopy)
        do { let s = try LeadStore(path: p, key: key); s.db.close() }
        try FileManager.default.moveItem(atPath: plainCopy, toPath: EncryptedDatabase.plaintextPath(p))
        XCTAssertThrowsError(try LeadStore(path: p, key: DatabaseKey.random()), "чужой ключ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: EncryptedDatabase.plaintextPath(p)),
                      "исходник не удаляется, пока новая база не открылась")
        try assertFilled(try LeadStore(path: p, key: key))
    }

    func testRecoveryWhenPlaintextWasPutBackKeepsBoth() throws {
        let p = try makePlaintextStore()
        try FileManager.default.copyItem(atPath: p, toPath: EncryptedDatabase.plaintextPath(p))
        let store = try LeadStore(path: p, key: key)
        try assertFilled(store)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("leads.db.unencrypted-") }
        XCTAssertEqual(kept.count, 1, "отложенный файл сохранён под другим именем, ничего не удалено")
    }

    // MARK: - Резервные копии и перенос

    func testBackupOfEncryptedStoreIsEncrypted() throws {
        let store = try LeadStore(path: path(), key: key)
        try fill(store)
        let backup = dir.appendingPathComponent("backup.db")
        try store.backup(to: backup)
        XCTAssertEqual(EncryptedDatabase.state(of: backup.path), .encrypted)
        assertNoPlaintext(at: backup.path)
        XCTAssertThrowsError(try SQLiteDB(path: backup.path, readOnly: true, key: DatabaseKey.random()))
        try assertFilled(try LeadStore(path: backup.path, key: key))
    }

    func testRestoreFromEncryptedBackup() throws {
        let store = try LeadStore(path: path(), key: key)
        try fill(store)
        let backup = dir.appendingPathComponent("backup.db")
        try store.backup(to: backup)
        try store.setNote("L1", "изменено после копии")
        try store.restore(from: backup)
        try assertFilled(store)
        XCTAssertEqual(EncryptedDatabase.state(of: store.path), .encrypted)
        let safety = dir.appendingPathComponent("before-restore.db").path
        XCTAssertEqual(EncryptedDatabase.state(of: safety), .encrypted, "страховочная копия тоже зашифрована")
    }

    func testRestoreFromLegacyPlaintextBackupEncryptsIt() throws {
        let legacyBackup = try makePlaintextStore("old-backup.db")
        let store = try LeadStore(path: path(), key: key)
        try store.restore(from: URL(fileURLWithPath: legacyBackup))
        try assertFilled(store)
        store.db.close()
        XCTAssertEqual(EncryptedDatabase.state(of: path()), .encrypted)
        assertNoPlaintext(at: path())
        XCTAssertEqual(EncryptedDatabase.state(of: legacyBackup), .plaintext, "выбранный файл копии не меняется")
    }

    func testRestoreRejectsBackupEncryptedWithAnotherKey() throws {
        let other = try LeadStore(path: path("other.db"), key: DatabaseKey.random())
        try fill(other)
        let foreign = dir.appendingPathComponent("foreign.db")
        try other.backup(to: foreign)
        let store = try LeadStore(path: path(), key: key)
        try store.save(Self.lead("Своё"), id: "mine", fingerprint: "m")
        XCTAssertThrowsError(try store.restore(from: foreign))
        XCTAssertEqual(try store.allLeads().map(\.id), ["mine"], "текущая база не тронута")
    }

    func testMoveKeepsEncryption() throws {
        let store = try LeadStore(path: path(), key: key)
        try fill(store)
        let target = dir.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let newPath = try store.move(toDirectory: target)
        try assertFilled(store)
        try store.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertEqual(EncryptedDatabase.state(of: newPath), .encrypted)
        assertNoPlaintext(at: newPath)
    }

    func testImportFromLegacyPlaintextStoreIntoEncrypted() throws {
        // Перенос из локальной учётной записи: исходная база старой версии открывается с ключом
        // (и при этом шифруется), данные переносятся в зашифрованную облачную базу.
        let srcPath = try makePlaintextStore("local.db")
        let src = try LeadStore(path: srcPath, key: key)
        let target = try LeadStore(path: path("cloud.db"), key: key)
        let count = try target.importFrom(src)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(EncryptedDatabase.state(of: srcPath), .encrypted)
    }
}

#if canImport(Security)
/// Ключ в Связке ключей macOS. Отдельная запись на каждый тест, после теста удаляется.
final class KeychainDatabaseKeyTests: XCTestCase {
    func testKeyIsCreatedOnceAndReadBack() throws {
        let service = "LeadGenerator.tests.\(UUID().uuidString)"
        let first = KeychainDatabaseKeyProvider(service: service)
        defer { first.deleteForTesting() }
        let k1 = try first.databaseKey()
        XCTAssertEqual(try first.databaseKey(), k1, "повторный вызов — тот же ключ")
        let fresh = KeychainDatabaseKeyProvider(service: service)
        XCTAssertEqual(try fresh.databaseKey(), k1, "после перезапуска ключ читается из Связки ключей")
        let other = KeychainDatabaseKeyProvider(service: service, account: "other")
        defer { other.deleteForTesting() }
        XCTAssertNotEqual(try other.databaseKey(), k1)
    }

    func testKeychainKeyOpensDatabaseAfterRestart() throws {
        let service = "LeadGenerator.tests.\(UUID().uuidString)"
        let provider = KeychainDatabaseKeyProvider(service: service)
        defer { provider.deleteForTesting() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-kc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = dir.appendingPathComponent("leads.db").path
        do {
            let s = try LeadStore(path: p, key: try provider.databaseKey())
            try s.setValue("k", "v")
            s.db.close()
        }
        let reopened = try LeadStore(path: p, key: try KeychainDatabaseKeyProvider(service: service).databaseKey())
        XCTAssertEqual(reopened.value("k"), "v")
    }
}
#endif
