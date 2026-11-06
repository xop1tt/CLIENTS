import Foundation
import XCTest
@testable import LeadGenCore

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

    static let org = LeadData(
        kind: .organization, source: "osm_organizations", externalId: "node/1", title: "Студия красоты «Лаванда»",
        url: "https://www.openstreetmap.org/node/1", discoveredAt: ISODate.parse("2026-11-05T09:42:00+00:00"),
        region: "Казань", contacts: ["vk": "vk.com/lavanda"], category: "Салоны красоты", address: "ул. Баумана, 44",
        phone: "+7 (843) 212-48-90", facts: ["В OpenStreetMap не указан сайт"], assumptions: ["Возможно, нужна онлайн-запись"],
        score: 84, relevance: .high, scoreReasons: ["нет сайта (+35)"])

    static func order(_ title: String = "Нужен Telegram-бот") -> LeadData {
        LeadData(kind: .order, source: "fl_ru", externalId: "55", title: title, url: "https://www.fl.ru/projects/55",
                 description: "Ищу разработчика бота. Пишите: client@example.ru",
                 publishedAt: ISODate.parse("2026-11-05T08:00:00+00:00"), discoveredAt: ISODate.parse("2026-11-05T09:15:00+00:00"),
                 budget: 40000, currency: "RUB", contacts: ["email": "client@example.ru"], projectType: "telegram_bot",
                 website: "https://shop.example.ru/about", score: 88, relevance: .high)
    }

    /// База с двумя лидами: организация «org1» и заказ «ord1».
    func makeStore() throws -> LeadStore {
        let store = try LeadStore(path: dir.appendingPathComponent("local.db").path)
        XCTAssertEqual(try store.save(Self.org, id: "org1", fingerprint: "fp1"), .added)
        XCTAssertEqual(try store.save(Self.order(), id: "ord1", fingerprint: "fp2"), .added)
        return store
    }

    func testSaveKeepsUserState() throws {
        let store = try makeStore()
        var leads = try store.allLeads()
        XCTAssertEqual(leads.count, 2)
        let org = try XCTUnwrap(leads.first { $0.id == "org1" })
        XCTAssertEqual(org.data.facts, ["В OpenStreetMap не указан сайт"])
        XCTAssertFalse(org.seen)

        try store.setFavorite(["org1"], true)
        try store.setNote("org1", "позвонить")
        try store.delete(["ord1"])

        XCTAssertEqual(try store.save(Self.org, id: "org1", fingerprint: "fp1"), .unchanged)
        XCTAssertEqual(try store.save(Self.order("Нужен Telegram-бот (обновлено)"), id: "ord1", fingerprint: "fp2"), .updated)
        XCTAssertEqual(try store.save(Self.order(), id: "other", fingerprint: "fp2"), .duplicate, "тот же отпечаток из другого места")

        leads = try store.allLeads()
        XCTAssertEqual(leads.map(\.id), ["org1"], "удалённый лид не должен вернуться")
        XCTAssertTrue(leads[0].favorite)
        XCTAssertEqual(leads[0].note, "позвонить")
        XCTAssertFalse(try store.events(for: "org1").isEmpty)
    }

    func testSourceStateAndMemory() throws {
        let store = try makeStore()
        store.markAttempt("fl_ru")
        store.finishSource("fl_ru", ok: true, partial: false, error: nil, cursor: "{\"a\":1}")
        XCTAssertEqual(store.sourceCursor("fl_ru"), "{\"a\":1}")
        XCTAssertNotNil(store.lastSuccess("fl_ru"))
        store.finishSource("fl_ru", ok: false, partial: false, error: "timeout", cursor: nil)
        XCTAssertEqual(store.sourceCursor("fl_ru"), "{\"a\":1}", "ошибка не стирает курсор")
        XCTAssertEqual(try store.sourceStates().first?.consecutiveFailures, 1)
        store.logError(module: "fl_ru", message: "timeout")
        XCTAssertEqual(try store.pipelineErrors().first?.message, "timeout")

        store.recordQuery("q1", source: "osm_organizations", label: "Казань|beauty", results: 3)
        XCTAssertNotNil(store.queryLastRun("q1"))
        store.markObjectChecked(source: "osm_organizations", objectId: "node/1")
        XCTAssertNotNil(store.objectCheckedAt(source: "osm_organizations", objectId: "node/1"))
        try store.resetSourceMemory("osm_organizations")
        XCTAssertNil(store.queryLastRun("q1"))
        XCTAssertNil(store.objectCheckedAt(source: "osm_organizations", objectId: "node/1"))
    }

    func testExclusions() throws {
        let store = try makeStore()
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
        let store = try makeStore()
        let backup = dir.appendingPathComponent("b.db")
        try store.backup(to: backup)
        try store.delete(["org1", "ord1"])
        XCTAssertTrue(try store.allLeads().isEmpty)
        try store.restore(from: backup)
        XCTAssertEqual(try store.allLeads().count, 2)

        let current = dir.appendingPathComponent("local.db")
        XCTAssertThrowsError(try store.restore(from: current), "восстановление из самой себя запрещено")
        XCTAssertEqual(try store.allLeads().count, 2, "база осталась на месте и открыта")
    }

    func testExportCSVAndDraft() throws {
        let store = try makeStore()
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

    func testCSVFormulaNeutralized() {
        XCTAssertEqual(CSV.escape("=HYPERLINK(\"http://x\")"), "\"'=HYPERLINK(\"\"http://x\"\")\"")
        XCTAssertEqual(CSV.escape("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(CSV.escape("-1+2"), "-1+2")
        XCTAssertEqual(CSV.escape("-cmd|x"), "'-cmd|x")
        XCTAssertEqual(CSV.escape("+7 (843) 212-48-90"), "+7 (843) 212-48-90")
        XCTAssertEqual(CSV.escape("Студия"), "Студия")
    }

    func testCSVParse() {
        XCTAssertEqual(CSV.parseLine("a,\"b, c\",\"d \"\"e\"\"\""), ["a", "b, c", "d \"e\""])
        XCTAssertEqual(CSV.parseLine("x;y;z"), ["x", "y", "z"])
        XCTAssertEqual(CSV.parseLine("\"ООО Ромашка, Казань, РФ\";info@r.ru;+7 900 1112233"),
                       ["ООО Ромашка, Казань, РФ", "info@r.ru", "+7 900 1112233"], "запятые в кавычках не меняют разделитель")
    }

    func testNormalize() {
        XCTAssertEqual(Normalize.domain("https://www.Example.ru/path?q=1"), "example.ru")
        XCTAssertEqual(Normalize.phone("+7 (843) 212-48-90"), Normalize.phone("8 843 2124890"))
        XCTAssertEqual(Normalize.name("Студия «Лаванда»"), Normalize.name("студия лаванда"))
    }
}
