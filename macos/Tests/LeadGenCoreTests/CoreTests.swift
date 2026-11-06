import Foundation
import XCTest
@testable import LeadGenCore

final class FernetTests: XCTestCase {
    // Токен получен из Python: Fernet(urlsafe_b64encode(sha256(b"test-secret")))._encrypt_from_parts(...)
    let token = "gAAAAABpDBcAAAECAwQFBgcICQoLDA0ODxTXPL3GSB3sXCGq6EPDTJ3WK8e4EciANfm1dl3uBcxjW94YYkFgUpM9GuoxZsGg6EZSAOll2OBupikKWxA5amU="

    func testDecryptsPythonToken() throws {
        let plain = try Fernet.decrypt(token: Data(token.utf8), secret: "test-secret")
        XCTAssertEqual(String(data: plain, encoding: .utf8), "Lead Generator лиды 123")
    }

    func testWrongSecretRejected() {
        XCTAssertThrowsError(try Fernet.decrypt(token: Data(token.utf8), secret: "wrong")) { err in
            XCTAssertEqual(err as? Fernet.Failure, .badSignature)
        }
    }

    func testGarbageRejected() {
        XCTAssertThrowsError(try Fernet.decrypt(token: Data("not a token".utf8), secret: "x"))
    }
}

final class ISODateTests: XCTestCase {
    func testPythonFormats() {
        XCTAssertNotNil(ISODate.parse("2026-11-05T09:42:00+00:00"))
        XCTAssertNotNil(ISODate.parse("2026-11-05T09:42:00.123456+00:00"))
        XCTAssertNotNil(ISODate.parse("2026-11-05T09:42:00"))
        XCTAssertNil(ISODate.parse(""))
    }
}

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Создаёт базу в формате конвейера (sqlite_store.py) с двумя лидами.
    func makePipelineDB(extraTitle: String? = nil) throws -> String {
        let path = dir.appendingPathComponent("pipeline-\(UUID().uuidString).db").path
        let db = try SQLiteDB(path: path)
        try db.exec("""
        CREATE TABLE leads (lead_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL,
            external_id TEXT NOT NULL, data_json TEXT NOT NULL, score REAL NOT NULL DEFAULT 0, relevance TEXT NOT NULL,
            discovered_at TEXT NOT NULL, updated_at TEXT NOT NULL, notion_page_id TEXT, notion_status TEXT NOT NULL DEFAULT 'pending',
            notified_at TEXT, enrich_due_at TEXT);
        CREATE TABLE external_results (id INTEGER PRIMARY KEY AUTOINCREMENT, lead_id TEXT NOT NULL, service TEXT NOT NULL,
            processed_at TEXT NOT NULL, ok INTEGER NOT NULL, score REAL, label TEXT, details_json TEXT, error TEXT);
        CREATE TABLE source_state (source TEXT PRIMARY KEY, last_success_at TEXT, last_attempt_at TEXT, cursor_json TEXT,
            consecutive_failures INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'ok', last_error TEXT);
        CREATE TABLE errors (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, module TEXT NOT NULL, signature TEXT NOT NULL, message TEXT NOT NULL);
        """)
        let org = """
        {"kind":"organization","source":"osm_organizations","external_id":"node/1","title":"Студия красоты «Лаванда»","url":"https://www.openstreetmap.org/node/1","description":"","published_at":null,"discovered_at":"2026-11-05T09:42:00+00:00","budget":null,"currency":null,"region":"Казань","contacts":{"vk":"vk.com/lavanda"},"category":"beauty","project_type":null,"customer_name":null,"address":"ул. Баумана, 44","phone":"+7 (843) 212-48-90","website":null,"facts":["В OpenStreetMap не указан сайт"],"assumptions":["Возможно, нужна онлайн-запись"],"score":84.0,"relevance":"high","score_reasons":["нет сайта (+35)"],"status":"new","external_results":[],"raw":{"tags":{"shop":"beauty"}}}
        """
        let order = """
        {"kind":"order","source":"fl_ru","external_id":"55","title":"\(extraTitle ?? "Нужен Telegram-бот")","url":"https://www.fl.ru/projects/55","description":"Ищу разработчика бота. Пишите: client@example.ru","published_at":"2026-11-05T08:00:00.123456+00:00","discovered_at":"2026-11-05T09:15:00+00:00","budget":40000.0,"currency":"RUB","region":null,"contacts":{"email":"client@example.ru"},"category":null,"project_type":"telegram_bot","customer_name":null,"address":null,"phone":null,"website":"https://shop.example.ru/about","facts":[],"assumptions":[],"score":88.0,"relevance":"high","score_reasons":["явный запрос: «ищу» (+20)"],"status":"new","external_results":[],"raw":{}}
        """
        try db.run("INSERT INTO leads(lead_id,fingerprint,kind,source,external_id,data_json,score,relevance,discovered_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                   ["org1", "fp1", "organization", "osm_organizations", "node/1", .text(org), 84.0, "high", "2026-11-05T09:42:00+00:00", "2026-11-05T09:42:00+00:00"])
        try db.run("INSERT INTO leads(lead_id,fingerprint,kind,source,external_id,data_json,score,relevance,discovered_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                   ["ord1", "fp2", "order", "fl_ru", "55", .text(order), 88.0, "high", "2026-11-05T09:15:00+00:00", .text(extraTitle == nil ? "2026-11-05T09:15:00+00:00" : "2026-11-06T10:00:00+00:00")])
        try db.run("INSERT INTO external_results(lead_id,service,processed_at,ok,score,label) VALUES('org1','ollama','2026-11-05T09:44:00+00:00',1,79,'нужна запись')")
        try db.run("INSERT INTO source_state(source,last_success_at,consecutive_failures,status,last_error) VALUES('fl_ru','2026-11-05T09:15:00+00:00',0,'ok',NULL)")
        try db.run("INSERT INTO errors(at,module,signature,message) VALUES('2026-11-05T05:00:00+00:00','osm_organizations','x','timeout')")
        db.close()
        return path
    }

    func testImportKeepsUserStateOnResync() throws {
        let store = try LeadStore(path: dir.appendingPathComponent("local.db").path)
        let first = try store.importPipelineDatabase(at: try makePipelineDB())
        XCTAssertEqual(first.added, 2)

        var leads = try store.allLeads()
        XCTAssertEqual(leads.count, 2)
        let org = try XCTUnwrap(leads.first { $0.id == "org1" })
        XCTAssertEqual(org.data.externalResults.first?.score, 79)
        XCTAssertEqual(org.data.facts, ["В OpenStreetMap не указан сайт"])
        XCTAssertFalse(org.seen)

        try store.setFavorite(["org1"], true)
        try store.setNote("org1", "позвонить")
        try store.delete(["ord1"])

        let second = try store.importPipelineDatabase(at: try makePipelineDB(extraTitle: "Нужен Telegram-бот (обновлено)"))
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, 1)

        leads = try store.allLeads()
        XCTAssertEqual(leads.map(\.id), ["org1"], "удалённый лид не должен вернуться")
        XCTAssertTrue(leads[0].favorite)
        XCTAssertEqual(leads[0].note, "позвонить")
        XCTAssertEqual(try store.sourceStates().first?.source, "fl_ru")
        XCTAssertEqual(try store.pipelineErrors().first?.message, "timeout")
        XCTAssertFalse(try store.events(for: "org1").isEmpty)
    }

    func testExclusions() throws {
        let store = try LeadStore(path: dir.appendingPathComponent("local.db").path)
        try store.importPipelineDatabase(at: try makePipelineDB())
        try store.addExclusion(.phone, "8 843 212 48 90")
        XCTAssertTrue(try store.allLeads().first { $0.id == "org1" }!.excluded)
        try store.addExclusion(.domain, "example.ru")
        XCTAssertTrue(try store.allLeads().first { $0.id == "ord1" }!.excluded, "поддомен shop.example.ru исключён")
        for e in try store.exclusions() { try store.removeExclusion(e.id) }
        XCTAssertTrue(try store.allLeads().allSatisfy { !$0.excluded })

        let n = try store.importExclusions(csv: "Компания;Email;Телефон\nЛаванда;info@lavanda.ru;+7 (843) 212-48-90\n")
        XCTAssertEqual(n, 2)
        XCTAssertTrue(try store.allLeads().first { $0.id == "org1" }!.excluded)
    }

    func testBackupAndRestore() throws {
        let store = try LeadStore(path: dir.appendingPathComponent("local.db").path)
        try store.importPipelineDatabase(at: try makePipelineDB())
        let backup = dir.appendingPathComponent("b.db")
        try store.backup(to: backup)
        try store.delete(["org1", "ord1"])
        XCTAssertTrue(try store.allLeads().isEmpty)
        try store.restore(from: backup)
        XCTAssertEqual(try store.allLeads().count, 2)
    }

    func testExportCSVAndDraft() throws {
        let store = try LeadStore(path: dir.appendingPathComponent("local.db").path)
        try store.importPipelineDatabase(at: try makePipelineDB())
        let leads = try store.allLeads()
        let csv = String(data: Exporter.csv(leads, fields: [.title, .phone, .emails]), encoding: .utf8)!
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}Название,Телефон,Email"))
        XCTAssertTrue(csv.contains("client@example.ru"))
        let json = try Exporter.json(leads, fields: [.id, .score])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: json) as? [[String: String]])

        let org = leads.first { $0.id == "org1" }!
        let draft = DraftWriter.draft(for: org.data, channel: .email, signature: "Максим")
        XCTAssertTrue(draft.contains("сайта"))
        XCTAssertTrue(draft.hasSuffix("Максим"))
        XCTAssertTrue(draft.hasPrefix("Тема:"))
    }

    func testCSVParse() {
        XCTAssertEqual(CSV.parseLine("a,\"b, c\",\"d \"\"e\"\"\""), ["a", "b, c", "d \"e\""])
        XCTAssertEqual(CSV.parseLine("x;y;z"), ["x", "y", "z"])
    }

    func testNormalize() {
        XCTAssertEqual(Normalize.domain("https://www.Example.ru/path?q=1"), "example.ru")
        XCTAssertEqual(Normalize.phone("+7 (843) 212-48-90"), Normalize.phone("8 843 2124890"))
        XCTAssertEqual(Normalize.name("Студия «Лаванда»"), Normalize.name("студия лаванда"))
    }
}
