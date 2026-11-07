import Foundation
import XCTest
@testable import LeadGenCore

// Эталонные проверки ядра: каждая функция и граничные случаи. Файл дополняет CoreTests и не меняет
// ни одной прежней проверки. См. Wiki → «Разработка и сборка → Тесты и проверки как эталон».

// MARK: - Нормализация и даты

final class NormalizeReferenceTests: XCTestCase {
    func testDomain() {
        XCTAssertEqual(Normalize.domain("example.ru/a#b"), "example.ru")
        XCTAssertEqual(Normalize.domain("example.ru?x=1"), "example.ru")
        XCTAssertEqual(Normalize.domain("  HTTPS://Shop.Example.RU  "), "shop.example.ru")
        XCTAssertEqual(Normalize.domain("http://www.example.ru"), "example.ru")
        XCTAssertEqual(Normalize.domain(""), "")
    }

    func testPhone() {
        XCTAssertEqual(Normalize.phone("+7 (843) 212-48-90"), "8432124890")
        XCTAssertEqual(Normalize.phone("8-843-212-48-90"), "8432124890")
        XCTAssertEqual(Normalize.phone("123"), "123", "короткие номера не обрезаются")
        XCTAssertEqual(Normalize.phone(""), "")
        XCTAssertEqual(Normalize.phone("тел. не указан"), "")
    }

    func testEmail() {
        XCTAssertEqual(Normalize.email("  Info@Lavanda.RU "), "info@lavanda.ru")
    }

    func testName() {
        XCTAssertEqual(Normalize.name("Ёлка"), Normalize.name("елка"))
        XCTAssertEqual(Normalize.name("ООО «Ромашка», г. Казань"), "ооо ромашка г казань")
        XCTAssertEqual(Normalize.name("   "), "")
    }

    func testValueDispatchesByKind() {
        XCTAssertEqual(Normalize.value("https://www.a.ru/x", kind: .domain), "a.ru")
        XCTAssertEqual(Normalize.value("+7 900 111-22-33", kind: .phone), "9001112233")
        XCTAssertEqual(Normalize.value(" A@B.RU ", kind: .email), "a@b.ru")
        XCTAssertEqual(Normalize.value("«Лавр»", kind: .name), "лавр")
    }

    func testISODate() throws {
        let base = try XCTUnwrap(ISODate.parse("2026-11-05T09:42:00+00:00"))
        XCTAssertEqual(ISODate.format(base), "2026-11-05T09:42:00Z")
        XCTAssertEqual(ISODate.parse("2026-11-05T09:42:00Z"), base)
        XCTAssertEqual(ISODate.parse("2026-11-05T09:42:00"), base, "без часового пояса считается UTC")
        XCTAssertEqual(ISODate.parse("2026-11-05T12:42:00+03:00"), base, "смещение учитывается")
        let micro = try XCTUnwrap(ISODate.parse("2026-11-05T09:42:00.123456+00:00"))
        XCTAssertEqual(micro.timeIntervalSince(base), 0.123, accuracy: 0.001)
        XCTAssertNil(ISODate.parse(nil))
        XCTAssertNil(ISODate.parse("не дата"))
        XCTAssertNil(ISODate.format(nil))
        XCTAssertTrue(ISODate.formatPrecise(base).contains("."))
        XCTAssertNotNil(ISODate.parse(ISODate.now()))
    }

    func testSourceCatalog() {
        XCTAssertEqual(SourceCatalog.title("osm_organizations"), "OpenStreetMap")
        XCTAssertEqual(SourceCatalog.title("import"), "Импорт")
        XCTAssertEqual(SourceCatalog.title("неизвестный"), "неизвестный", "неизвестный ключ показывается как есть")
        for (key, info) in SourceCatalog.known {
            XCTAssertFalse(info.title.isEmpty, key)
            XCTAssertFalse(info.access.isEmpty, key)
        }
        XCTAssertFalse(SourceCatalog.unavailable.isEmpty)
    }

    func testSQLValueConversions() {
        XCTAssertEqual(SQLValue.int(5).int, 5)
        XCTAssertEqual(SQLValue.text("7").int, 7)
        XCTAssertEqual(SQLValue.double(2.9).int, 2)
        XCTAssertNil(SQLValue.null.int)
        XCTAssertNil(SQLValue.text("x").int)
        XCTAssertEqual(SQLValue.int(3).double, 3.0)
        XCTAssertTrue(SQLValue.int(1).bool)
        XCTAssertFalse(SQLValue.int(0).bool)
        XCTAssertFalse(SQLValue.null.bool)
        XCTAssertEqual(SQLValue.of("a"), .text("a"))
        XCTAssertEqual(SQLValue.of(nil as String?), .null)
        XCTAssertEqual(SQLValue.of(true), .int(1))
        XCTAssertEqual(SQLValue.of(false), .int(0))
        XCTAssertEqual(SQLValue.of(1.5), .double(1.5))
    }
}

// MARK: - SQLite

final class SQLiteReferenceTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: dir.appendingPathComponent("t.db").path)
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, note TEXT)")
        return db
    }

    func testTypesRoundTrip() throws {
        let db = try makeDB()
        try db.run("INSERT INTO t(name, score, note) VALUES(?,?,?)", [.text("Лаванда «1»"), .double(84.5), .null])
        let row = try XCTUnwrap(try db.query("SELECT * FROM t").first)
        XCTAssertEqual(row["name"]?.string, "Лаванда «1»")
        XCTAssertEqual(row["score"]?.double, 84.5)
        XCTAssertEqual(row["note"], .null)
        XCTAssertEqual(db.lastInsertId, 1)
    }

    func testRunReturnsChangedRows() throws {
        let db = try makeDB()
        try db.run("INSERT INTO t(name) VALUES('a'), ('b'), ('c')")
        XCTAssertEqual(try db.run("UPDATE t SET note='x' WHERE name<>'a'"), 2)
        XCTAssertEqual(try db.run("DELETE FROM t WHERE name='zzz'"), 0)
    }

    func testQuotesAreBoundNotInterpolated() throws {
        let db = try makeDB()
        let evil = "x'); DROP TABLE t; --"
        try db.run("INSERT INTO t(name) VALUES(?)", [.text(evil)])
        XCTAssertTrue(try db.tableExists("t"))
        XCTAssertEqual(try db.scalar("SELECT name FROM t").string, evil)
    }

    func testScalarAndTableExists() throws {
        let db = try makeDB()
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM t").int, 0)
        XCTAssertEqual(try db.scalar("SELECT name FROM t"), .null, "пустой результат — null")
        XCTAssertTrue(try db.tableExists("t"))
        XCTAssertFalse(try db.tableExists("нет такой"))
    }

    func testTransactionCommitsAndRollsBack() throws {
        let db = try makeDB()
        try db.transaction { try db.run("INSERT INTO t(name) VALUES('ok')") }
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM t").int, 1)
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction { () throws -> Void in
            try db.run("INSERT INTO t(name) VALUES('lost')")
            throw Boom()
        })
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM t").int, 1, "откат отменил вставку")
        XCTAssertNoThrow(try db.transaction { try db.run("INSERT INTO t(name) VALUES('again')") }, "после отката база не заблокирована")
    }

    func testErrorsAreReported() throws {
        let db = try makeDB()
        XCTAssertThrowsError(try db.exec("SELEKT 1"))
        XCTAssertThrowsError(try db.query("SELECT * FROM нет_такой_таблицы"))
        XCTAssertNoThrow(try db.run("INSERT INTO t(id) VALUES(1)"), "первая вставка допустима")
        XCTAssertThrowsError(try db.run("INSERT INTO t(id) VALUES(1)"), "дубликат первичного ключа")
    }

    func testReadOnlyCannotWrite() throws {
        let path = dir.appendingPathComponent("t.db").path
        _ = try makeDB()
        let ro = try SQLiteDB(path: path, readOnly: true)
        XCTAssertEqual(try ro.scalar("SELECT COUNT(*) FROM t").int, 0)
        XCTAssertThrowsError(try ro.run("INSERT INTO t(name) VALUES('x')"))
    }

    func testClosedDatabaseThrows() throws {
        let db = try makeDB()
        db.close()
        XCTAssertThrowsError(try db.query("SELECT 1"))
    }
}

// MARK: - Модели

final class ModelReferenceTests: XCTestCase {
    func testEnumTitlesAndRanks() {
        XCTAssertEqual(LeadKind.order.title, "Заказ")
        XCTAssertEqual(LeadKind.organization.title, "Организация")
        XCTAssertEqual(Relevance.allCases.map(\.rank), [3, 2, 1, 0])
        XCTAssertEqual(Set(Relevance.allCases.map(\.title)).count, 4)
        XCTAssertEqual(Set(ExclusionKind.allCases.map(\.title)).count, 4)
    }

    func testRoundTripPreservesEverything() throws {
        var lead = StoreTests.order()
        lead.externalResults = [ExternalResult(service: "hunter", processedAt: ISODate.parse("2026-11-05T10:00:00Z"),
                                               ok: true, score: 0.9, label: "valid", error: nil)]
        let data = try JSONEncoder().encode(lead)
        let back = try JSONDecoder().decode(LeadData.self, from: data)
        XCTAssertEqual(back, lead)
    }

    func testEncodingUsesPythonKeys() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StoreTests.order())) as? [String: Any]
        for key in ["external_id", "published_at", "discovered_at", "project_type", "score_reasons", "external_results"] {
            XCTAssertNotNil(json?[key], key)
        }
        XCTAssertNil(json?["externalId"])
    }

    func testDecodingToleratesMissingAndBrokenFields() throws {
        let minimal = try JSONDecoder().decode(LeadData.self, from: Data(#"{"title": "Только название"}"#.utf8))
        XCTAssertEqual(minimal.title, "Только название")
        XCTAssertEqual(minimal.kind, .order)
        XCTAssertEqual(minimal.relevance, .rejected)
        XCTAssertEqual(minimal.status, "new")
        XCTAssertTrue(minimal.facts.isEmpty)
        XCTAssertTrue(minimal.contacts.isEmpty)
        let broken = try JSONDecoder().decode(LeadData.self,
            from: Data(#"{"title": "x", "score": "много", "relevance": "огонь", "budget": "?", "facts": 5}"#.utf8))
        XCTAssertEqual(broken.score, 0)
        XCTAssertEqual(broken.relevance, .rejected)
        XCTAssertNil(broken.budget)
        XCTAssertTrue(broken.facts.isEmpty)
    }

    func testEmailsAndPhones() {
        var d = StoreTests.order()
        XCTAssertEqual(d.emails, ["client@example.ru"])
        d.contacts = ["email": "a@b.ru", "vk": "@name", "telegram": "@a@b", "site": "example.ru", "phone2": "+7 900 000-00-02"]
        XCTAssertEqual(d.emails.sorted(), ["a@b.ru"], "@name и значения без точки после @ не считаются email")
        d.phone = "+7 900 000-00-01"
        XCTAssertEqual(d.phones, ["+7 900 000-00-01", "+7 900 000-00-02"])
        d.contacts = ["телефон": "+7 900 000-00-01"]
        XCTAssertEqual(d.phones, ["+7 900 000-00-01"], "один номер не дублируется")
        d.phone = nil
        d.contacts = [:]
        XCTAssertTrue(d.phones.isEmpty)
    }

    func testDomain() {
        var d = StoreTests.order()
        XCTAssertEqual(d.domain, "shop.example.ru")
        d.website = ""
        XCTAssertNil(d.domain)
        d.website = nil
        XCTAssertNil(d.domain)
    }

    func testLeadItemSortKeys() {
        let item = LeadItem(id: "1", data: StoreTests.order(), discoveredAt: Date())
        XCTAssertEqual(item.title, "Нужен Telegram-бот")
        XCTAssertEqual(item.score, 88)
        XCTAssertEqual(item.kindTitle, "Заказ")
        XCTAssertEqual(item.relevanceRank, 3)
        XCTAssertEqual(item.categoryText, "telegram_bot")
        XCTAssertEqual(item.regionText, "")
        XCTAssertTrue(item.isNew)
        XCTAssertFalse(LeadItem(id: "2", data: StoreTests.org, discoveredAt: Date(), seen: true).isNew)
        XCTAssertEqual(LeadItem(id: "3", data: StoreTests.org, discoveredAt: Date()).categoryText, "Салоны красоты")
    }
}

// MARK: - Хранилище лидов: действия пользователя и служебные таблицы

final class StoreReferenceTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makeStore(_ name: String = "ref.db") throws -> LeadStore {
        let store = try LeadStore(path: dir.appendingPathComponent(name).path)
        try store.save(StoreTests.org, id: "org1", fingerprint: "fp1")
        try store.save(StoreTests.order(), id: "ord1", fingerprint: "fp2")
        return store
    }

    func lead(_ store: LeadStore, _ id: String) throws -> LeadItem {
        try XCTUnwrap(try store.allLeads(includeDeleted: true).first { $0.id == id })
    }

    func testFavoriteArchiveAndEvents() throws {
        let store = try makeStore()
        try store.setFavorite(["org1"], true)
        XCTAssertTrue(try lead(store, "org1").favorite)
        XCTAssertFalse(try lead(store, "ord1").favorite, "другие лиды не затронуты")
        try store.setFavorite(["org1"], false)
        XCTAssertFalse(try lead(store, "org1").favorite)

        try store.setArchived(["org1", "ord1"], true)
        XCTAssertTrue(try store.allLeads().allSatisfy(\.archived))
        try store.setArchived(["ord1"], false)
        XCTAssertFalse(try lead(store, "ord1").archived)

        let actions = try store.events(for: "org1").map(\.action)
        XCTAssertTrue(actions.contains("Добавлен в избранное"))
        XCTAssertTrue(actions.contains("Убран из избранного"))
        XCTAssertTrue(actions.contains("Перенесён в архив"))
        XCTAssertTrue(actions.contains { $0.hasPrefix("Найден поиском") })
    }

    func testEmptyAndUnknownIdsAreHarmless() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.setFavorite([], true))
        XCTAssertNoThrow(try store.delete([]))
        XCTAssertNoThrow(try store.setFavorite(["нет-такого"], true))
        XCTAssertEqual(try store.allLeads().count, 2)
    }

    func testSeenAndMarkAllSeen() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.allLeads().allSatisfy { !$0.seen })
        try store.markSeen(["org1"])
        XCTAssertTrue(try lead(store, "org1").seen)
        XCTAssertFalse(try lead(store, "ord1").seen)
        let before = try store.events(for: "org1").count
        try store.markSeen(["org1"])
        XCTAssertEqual(try store.events(for: "org1").count, before, "просмотр не пишет событий")
        try store.markAllSeen()
        XCTAssertTrue(try store.allLeads().allSatisfy(\.seen))
    }

    func testNoteIsStoredAndCanBeCleared() throws {
        let store = try makeStore()
        try store.setNote("org1", "позвонить во вторник")
        XCTAssertEqual(try lead(store, "org1").note, "позвонить во вторник")
        try store.setNote("org1", "позвонить во вторник")
        try store.setNote("org1", "")
        XCTAssertEqual(try lead(store, "org1").note, "")
    }

    func testDeletedLeadIsHiddenButKeptAndNotResurrected() throws {
        let store = try makeStore()
        try store.delete(["ord1"])
        XCTAssertEqual(try store.allLeads().map(\.id), ["org1"])
        XCTAssertEqual(try store.allLeads(includeDeleted: true).count, 2)
        XCTAssertEqual(try store.save(StoreTests.order(), id: "ord1", fingerprint: "fp2"), .unchanged)
        XCTAssertEqual(try store.allLeads().map(\.id), ["org1"])
    }

    func testSaveOutcomes() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.save(StoreTests.org, id: "org1", fingerprint: "fp1"), .unchanged)
        var changed = StoreTests.org
        changed.score = 10
        XCTAssertEqual(try store.save(changed, id: "org1", fingerprint: "fp1"), .updated)
        XCTAssertEqual(try lead(store, "org1").data.score, 10)
        XCTAssertEqual(try store.save(StoreTests.org, id: "dup", fingerprint: "fp1"), .duplicate)
        XCTAssertEqual(try store.save(StoreTests.order("Другой"), id: "a", fingerprint: ""), .added, "пустой отпечаток дублем не считается")
        XCTAssertEqual(try store.save(StoreTests.order("Ещё другой"), id: "b", fingerprint: ""), .added)
        XCTAssertEqual(try store.allLeads().count, 4)
    }

    func testDiscoveryDateIsTheFirstOne() throws {
        let store = try makeStore()
        let first = try lead(store, "org1").discoveredAt
        var later = StoreTests.org
        later.discoveredAt = ISODate.parse("2030-01-01T00:00:00Z")
        later.score = 1
        XCTAssertEqual(try store.save(later, id: "org1", fingerprint: "fp1"), .updated)
        XCTAssertEqual(try lead(store, "org1").discoveredAt, first)
    }

    func testKeyValue() throws {
        let store = try makeStore()
        XCTAssertNil(store.value("нет"))
        try store.setValue("k", "1")
        try store.setValue("k", "2")
        XCTAssertEqual(store.value("k"), "2")
        XCTAssertNotNil(store.value("schema_version"))
        try store.searchFinished()
        XCTAssertNotNil(ISODate.parse(store.value("last_search_at")))
    }

    func testRunAndSyncLogs() throws {
        let store = try makeStore()
        store.logRun(ok: true, added: 3, updated: 1, message: "готово")
        store.logRun(ok: false, added: 0, updated: 0, message: "сбой")
        let log = try store.syncLog()
        XCTAssertEqual(log.first?.message, "сбой", "новые записи сверху")
        XCTAssertEqual(log.first?.ok, false)
        XCTAssertEqual(log.last?.added, 3)
        XCTAssertEqual(try store.syncLog(limit: 1).count, 1)
        try store.addSyncLog(ok: true, added: 2, updated: 5, message: "облако")
        XCTAssertEqual(try store.syncLog().first?.updated, 5)
    }

    func testPipelineErrorsLimitAndOrder() throws {
        let store = try makeStore()
        for i in 1...5 { store.logError(module: "m", message: "ошибка \(i)") }
        let errors = try store.pipelineErrors(limit: 3)
        XCTAssertEqual(errors.map(\.message), ["ошибка 5", "ошибка 4", "ошибка 3"])
    }

    func testSourceFailuresCountAndRecover() throws {
        let store = try makeStore()
        store.markAttempt("rss")
        store.finishSource("rss", ok: false, partial: false, error: "e1", cursor: nil)
        store.finishSource("rss", ok: false, partial: false, error: "e2", cursor: nil)
        XCTAssertEqual(try store.sourceStates().first?.consecutiveFailures, 2)
        XCTAssertEqual(try store.sourceStates().first?.lastError, "e2")
        store.finishSource("rss", ok: true, partial: false, error: nil, cursor: "c")
        XCTAssertEqual(try store.sourceStates().first?.consecutiveFailures, 0, "успех сбрасывает счётчик")
        XCTAssertNil(try store.sourceStates().first?.lastError)
    }

    func testQueryMemoryForgetAndReset() throws {
        let store = try makeStore()
        store.recordQuery("h1", source: "osm", label: "Казань", results: 2)
        XCTAssertNotNil(store.queryLastRun("h1"))
        store.forgetQuery("h1")
        XCTAssertNil(store.queryLastRun("h1"))
        XCTAssertNil(store.queryLastRun("не было"))
    }

    func testExclusionRules() throws {
        let store = try makeStore()
        try store.addExclusion(.email, "CLIENT@example.ru")
        XCTAssertTrue(try lead(store, "ord1").excluded)
        XCTAssertFalse(try lead(store, "org1").excluded)
        try store.addExclusion(.name, "студия красоты лаванда")
        XCTAssertTrue(try lead(store, "org1").excluded, "название сравнивается без кавычек и регистра")
        let before = try store.exclusions().count
        try store.addExclusion(.name, "Студия красоты «Лаванда»")
        XCTAssertEqual(try store.exclusions().count, before, "то же правило не дублируется")
        try store.addExclusion(.domain, "   ")
        XCTAssertEqual(try store.exclusions().count, before, "пустое значение не добавляется")
    }

    func testDomainExclusionDoesNotMatchSimilarNames() throws {
        let store = try makeStore()
        try store.addExclusion(.domain, "ample.ru")
        XCTAssertFalse(try lead(store, "ord1").excluded, "shop.example.ru не заканчивается на «.ample.ru»")
        try store.addExclusion(.domain, "example.ru")
        XCTAssertTrue(try lead(store, "ord1").excluded)
    }

    func testImportExclusionsClassifiesCells() throws {
        let store = try makeStore()
        let csv = "Компания;Сайт;Почта;Телефон\nЛавр;https://www.lavr.ru/;a@lavr.ru;+7 900 111-22-33\n;;;\nпросто текст;;;12\n"
        XCTAssertEqual(try store.importExclusions(csv: csv), 3)
        XCTAssertEqual(Set(try store.exclusions().map(\.kind)), [.domain, .email, .phone])
        XCTAssertEqual(try store.importExclusions(csv: csv), 0, "повторный импорт ничего не добавляет")
    }

    func testMoveDatabase() throws {
        let store = try makeStore("move.db")
        let target = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let newPath = try store.move(toDirectory: target)
        XCTAssertEqual(newPath, target.appendingPathComponent("leads.db").path)
        XCTAssertEqual(store.path, newPath)
        XCTAssertEqual(try store.allLeads().count, 2, "данные на новом месте")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("move.db").path))
        XCTAssertEqual(try store.move(toDirectory: target), newPath, "перенос на то же место ничего не делает")
        XCTAssertGreaterThan(store.fileSize, 0)
    }

    func testReopenKeepsData() throws {
        let path = dir.appendingPathComponent("reopen.db").path
        do {
            let store = try LeadStore(path: path)
            try store.save(StoreTests.org, id: "org1", fingerprint: "fp1")
            try store.setFavorite(["org1"], true)
        }
        let again = try LeadStore(path: path)
        XCTAssertEqual(try again.allLeads().map(\.id), ["org1"])
        XCTAssertTrue(try again.allLeads()[0].favorite)
    }

    func testRestoreRejectsFileThatIsNotADatabase() throws {
        let store = try makeStore()
        let junk = dir.appendingPathComponent("junk.db")
        try Data("это не база".utf8).write(to: junk)
        XCTAssertThrowsError(try store.restore(from: junk))
        XCTAssertEqual(try store.allLeads().count, 2, "текущая база не пострадала")
    }
}

// MARK: - Экспорт

final class ExportReferenceTests: XCTestCase {
    let items = [LeadItem(id: "o1", data: StoreTests.order(), discoveredAt: ISODate.parse("2026-11-05T09:15:00Z")!, favorite: true, note: "важно"),
                 LeadItem(id: "g1", data: StoreTests.org, discoveredAt: ISODate.parse("2026-11-05T09:42:00Z")!)]

    func testEveryFieldHasTitleAndValue() {
        XCTAssertEqual(Set(ExportField.allCases.map(\.title)).count, ExportField.allCases.count, "названия полей уникальны")
        for f in ExportField.allCases { XCTAssertFalse(f.title.isEmpty, f.rawValue) }
        XCTAssertTrue(ExportField.defaults.allSatisfy { ExportField.allCases.contains($0) })
        XCTAssertEqual(Set(ExportField.defaults).count, ExportField.defaults.count)
    }

    func testFieldValues() {
        let o = items[0], g = items[1]
        XCTAssertEqual(ExportField.id.value(o), "o1")
        XCTAssertEqual(ExportField.kind.value(o), "Заказ")
        XCTAssertEqual(ExportField.score.value(o), "88")
        XCTAssertEqual(ExportField.relevance.value(o), "Высокая")
        XCTAssertEqual(ExportField.budget.value(o), "40000 RUB")
        XCTAssertEqual(ExportField.budget.value(g), "")
        XCTAssertEqual(ExportField.emails.value(o), "client@example.ru")
        XCTAssertEqual(ExportField.phone.value(g), "+7 (843) 212-48-90")
        XCTAssertEqual(ExportField.favorite.value(o), "да")
        XCTAssertEqual(ExportField.favorite.value(g), "")
        XCTAssertEqual(ExportField.note.value(o), "важно")
        XCTAssertEqual(ExportField.region.value(g), "Казань")
        XCTAssertEqual(ExportField.category.value(o), "telegram_bot", "у заказа вместо категории тип проекта")
        XCTAssertEqual(ExportField.category.value(g), "Салоны красоты")
        XCTAssertEqual(ExportField.reasons.value(g), "нет сайта (+35)")
        XCTAssertEqual(ExportField.facts.value(g), "В OpenStreetMap не указан сайт")
        XCTAssertEqual(ExportField.discoveredAt.value(o), "2026-11-05T09:15:00Z")
        XCTAssertEqual(ExportField.source.value(g), "OpenStreetMap")
    }

    func testCSVStructure() throws {
        let data = Exporter.csv(items, fields: [.title, .score])
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "BOM для Excel")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lines = text.dropFirst().components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 4, "заголовок, две строки и пустой хвост")
        XCTAssertEqual(lines[0], "Название,Оценка")
        XCTAssertEqual(lines[1], "Нужен Telegram-бот,88")
        XCTAssertEqual(lines[3], "")
    }

    func testCSVEscapesSpecialCharactersInCells() throws {
        var d = StoreTests.order("Бот, с \"кавычками\"\nи переносом")
        d.score = 1
        let text = try XCTUnwrap(String(data: Exporter.csv([LeadItem(id: "x", data: d, discoveredAt: Date())], fields: [.title]), encoding: .utf8))
        XCTAssertTrue(text.contains("\"Бот, с \"\"кавычками\"\"\nи переносом\""))
    }

    func testCSVOfNoLeadsHasOnlyHeader() throws {
        let text = try XCTUnwrap(String(data: Exporter.csv([], fields: [.title, .phone]), encoding: .utf8))
        XCTAssertEqual(text, "\u{FEFF}Название,Телефон\r\n")
    }

    func testJSONContainsRequestedFieldsOnly() throws {
        let data = try Exporter.json(items, fields: [.id, .title])
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows[0].keys), ["id", "title"])
        XCTAssertEqual(rows[0]["id"], "o1")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("\\/"), "слэши не экранируются")
    }

    func testExportDispatchByFormat() throws {
        XCTAssertEqual(ExportFormat.csv.fileExtension, "csv")
        XCTAssertEqual(ExportFormat.json.fileExtension, "json")
        XCTAssertEqual(try Exporter.export(items, format: .csv, fields: [.title]), Exporter.csv(items, fields: [.title]))
        XCTAssertEqual(try Exporter.export(items, format: .json, fields: [.title]), try Exporter.json(items, fields: [.title]))
    }

    func testCSVParseLineEdgeCases() {
        XCTAssertEqual(CSV.parseLine(""), [""])
        XCTAssertEqual(CSV.parseLine("a,,c"), ["a", "", "c"])
        XCTAssertEqual(CSV.parseLine("a\tb\tc"), ["a", "b", "c"])
        XCTAssertEqual(CSV.separator(for: "a;b;c"), ";")
        XCTAssertEqual(CSV.separator(for: "a,b,c"), ",")
        XCTAssertEqual(CSV.separator(for: "одно значение"), ",")
    }
}

// MARK: - Черновики обращений

final class DraftReferenceTests: XCTestCase {
    func testOrderDraftMentionsTitleAndBudget() {
        let text = DraftWriter.draft(for: StoreTests.order(), channel: .message, signature: "Максим")
        XCTAssertTrue(text.hasPrefix("Здравствуйте!"))
        XCTAssertTrue(text.contains("«Нужен Telegram-бот»"))
        XCTAssertTrue(text.contains("Делаю Telegram-бот под ключ"))
        XCTAssertTrue(text.contains("Бюджет вижу"))
        XCTAssertTrue(text.hasSuffix("Максим"))
    }

    func testOrderWithoutBudgetDoesNotMentionIt() {
        var d = StoreTests.order()
        d.budget = nil
        XCTAssertFalse(DraftWriter.draft(for: d, channel: .message, signature: "").contains("Бюджет вижу"))
    }

    func testEmptySignatureAddsNothing() {
        let text = DraftWriter.draft(for: StoreTests.order(), channel: .message, signature: "  ")
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.hasSuffix(" "))
    }

    func testCallHasNoSubjectAndIntroducesTheCaller() {
        let text = DraftWriter.draft(for: StoreTests.org, channel: .call, signature: "Максим")
        XCTAssertTrue(text.hasPrefix("Добрый день! Меня зовут Максим"))
        XCTAssertFalse(text.hasPrefix("Тема:"))
        XCTAssertFalse(text.hasSuffix("Максим"), "в звонке подпись не дописывается")
    }

    func testEmailHasSubjectLine() {
        let order = DraftWriter.draft(for: StoreTests.order(), channel: .email, signature: "М")
        XCTAssertTrue(order.hasPrefix("Тема: Ваша заявка: Нужен Telegram-бот"))
        let org = DraftWriter.draft(for: StoreTests.org, channel: .email, signature: "М")
        XCTAssertTrue(org.hasPrefix("Тема: Предложение для"))
    }

    func testOrganizationProblemFollowsFacts() {
        var d = StoreTests.org
        d.website = "https://lavanda.ru"
        d.facts = ["Сайт не открылся"]
        XCTAssertTrue(DraftWriter.draft(for: d, channel: .message, signature: "").contains("не открывается"))
        d.facts = ["Нет viewport: сайт неудобен с телефона"]
        XCTAssertTrue(DraftWriter.draft(for: d, channel: .message, signature: "").contains("с телефона"))
        d.facts = ["Нет онлайн-записи (запись только по звонку)"]
        XCTAssertTrue(DraftWriter.draft(for: d, channel: .message, signature: "").contains("онлайн-записи"))
        d.facts = []
        XCTAssertTrue(DraftWriter.draft(for: d, channel: .message, signature: "").contains("упростить работу с клиентами"))
        d.website = nil
        XCTAssertTrue(DraftWriter.draft(for: d, channel: .message, signature: "").contains("сайта"))
    }

    func testChannelTitlesAreDistinct() {
        XCTAssertEqual(Set(DraftWriter.Channel.allCases.map(\.title)).count, 3)
    }
}

// MARK: - Учётные записи

final class AccountReferenceTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-auth-ref-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testUsernameRules() {
        XCTAssertEqual(LocalAuthService.normalized("  maksim  "), "maksim")
        XCTAssertEqual(LocalAuthService.normalized("Анна.Иванова-1"), "Анна.Иванова-1")
        XCTAssertNil(LocalAuthService.normalized("ab"), "короче 3")
        XCTAssertNil(LocalAuthService.normalized(String(repeating: "a", count: 33)), "длиннее 32")
        XCTAssertNotNil(LocalAuthService.normalized(String(repeating: "a", count: 32)))
        XCTAssertNil(LocalAuthService.normalized("-abc"), "начинается с буквы или цифры")
        XCTAssertNil(LocalAuthService.normalized("a b c"))
        XCTAssertNil(LocalAuthService.normalized("../etc"))
        XCTAssertNil(LocalAuthService.normalized(""))
    }

    func testUsernameIsCaseInsensitiveButKeepsDisplayName() throws {
        let auth = try LocalAuthService(root: dir)
        XCTAssertEqual(try auth.register(username: "Maksim", password: "correct horse").username, "Maksim")
        XCTAssertEqual(auth.account("MAKSIM")?.username, "Maksim")
        XCTAssertEqual(auth.allAccounts().map(\.username), ["Maksim"])
        XCTAssertEqual(auth.dataDirectory(for: "Maksim"), auth.dataDirectory(for: "maksim"))
    }

    func testPasswordRules() throws {
        let auth = try LocalAuthService(root: dir)
        XCTAssertThrowsError(try auth.register(username: "maksim", password: "1234567")) { XCTAssertEqual($0 as? AuthError, .weakPassword) }
        XCTAssertNoThrow(try auth.register(username: "maksim", password: "12345678"))
        XCTAssertThrowsError(try auth.changePassword(username: "maksim", old: "12345678", new: "short")) {
            XCTAssertEqual($0 as? AuthError, .weakPassword)
        }
        XCTAssertThrowsError(try auth.changePassword(username: "maksim", old: "не тот пароль", new: "new password")) {
            XCTAssertEqual($0 as? AuthError, .wrongCredentials)
        }
        XCTAssertNoThrow(try auth.login(username: "maksim", password: "12345678"), "неудачная смена пароля ничего не меняет")
        try auth.changePassword(username: "maksim", old: "12345678", new: "new password")
        XCTAssertThrowsError(try auth.login(username: "maksim", password: "12345678"))
        XCTAssertNoThrow(try auth.login(username: "maksim", password: "new password"))
    }

    func testPasswordsAreNotStoredInPlainText() throws {
        let auth = try LocalAuthService(root: dir)
        _ = try auth.register(username: "maksim", password: "very secret phrase")
        let bytes = try Data(contentsOf: dir.appendingPathComponent("accounts.db"))
        XCTAssertNil(bytes.range(of: Data("very secret phrase".utf8)))
    }

    func testAccountsSurviveReopen() throws {
        _ = try LocalAuthService(root: dir).register(username: "maksim", password: "correct horse")
        let again = try LocalAuthService(root: dir)
        XCTAssertTrue(again.hasUsers)
        XCTAssertNoThrow(try again.login(username: "maksim", password: "correct horse"))
        XCTAssertNotNil(again.account("maksim")?.lastLoginAt)
    }

    func testUnknownUserLooksLikeWrongPassword() throws {
        let auth = try LocalAuthService(root: dir)
        _ = try auth.register(username: "maksim", password: "correct horse")
        for name in ["maksim", "nobody"] {
            XCTAssertThrowsError(try auth.login(username: name, password: "wrong wrong")) {
                XCTAssertEqual($0 as? AuthError, .wrongCredentials, "ошибка одинакова для известного и неизвестного имени")
            }
        }
    }

    func testLockoutAfterFiveFailuresAndRecoveryForOthers() throws {
        let auth = try LocalAuthService(root: dir)
        _ = try auth.register(username: "maksim", password: "correct horse")
        _ = try auth.register(username: "anna", password: "correct horse")
        for _ in 0..<5 {
            XCTAssertThrowsError(try auth.login(username: "maksim", password: "wrong wrong")) { XCTAssertEqual($0 as? AuthError, .wrongCredentials) }
        }
        XCTAssertThrowsError(try auth.login(username: "maksim", password: "correct horse")) {
            guard case .tooManyAttempts(let seconds)? = $0 as? AuthError else { return XCTFail("ожидалась пауза") }
            XCTAssertGreaterThan(seconds, 0)
            XCTAssertLessThanOrEqual(seconds, 300)
        }
        XCTAssertNoThrow(try auth.login(username: "anna", password: "correct horse"), "пауза касается только одного имени")
    }

    func testSuccessfulLoginResetsFailureCounter() throws {
        let auth = try LocalAuthService(root: dir)
        _ = try auth.register(username: "maksim", password: "correct horse")
        for _ in 0..<4 { XCTAssertThrowsError(try auth.login(username: "maksim", password: "wrong wrong")) }
        XCTAssertNoThrow(try auth.login(username: "maksim", password: "correct horse"))
        for _ in 0..<4 { XCTAssertThrowsError(try auth.login(username: "maksim", password: "wrong wrong")) { XCTAssertEqual($0 as? AuthError, .wrongCredentials) } }
        XCTAssertNoThrow(try auth.login(username: "maksim", password: "correct horse"), "счётчик начался заново")
    }

    func testErrorsHaveReadableText() {
        for e in [AuthError.invalidUsername, .weakPassword, .passwordsDiffer, .exists, .wrongCredentials, .tooManyAttempts(7)] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
        XCTAssertTrue(AuthError.tooManyAttempts(7).errorDescription!.contains("7"))
    }
}
