import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LeadGenCore

final class CRMExportTests: XCTestCase {
    func lead(_ id: String = "l1", title: String = "Кофейня «Зерно»") -> LeadItem {
        let data = LeadData(kind: .organization, source: "osm", externalId: "x", title: title,
                            url: "https://example.com/lead", description: "Описание",
                            budget: 50000, currency: "RUB", region: "Казань",
                            contacts: ["email": "info@zerno.ru", "phone2": "+7 900 000-00-01"],
                            customerName: "ООО Зерно", address: "ул. Баумана, 1", phone: "+7 843 212-48-90",
                            website: "https://zerno.ru", score: 72.4, relevance: .high, scoreReasons: ["нет онлайн-записи"])
        return LeadItem(id: id, data: data, discoveredAt: ISODate.parse("2026-11-05T09:00:00Z")!, favorite: true)
    }

    // MARK: Bitrix24

    func testBitrixWebhookNormalization() throws {
        XCTAssertEqual(try Bitrix24Destination.normalize(" https://acme.bitrix24.ru/rest/1/abc123/ ").absoluteString,
                       "https://acme.bitrix24.ru/rest/1/abc123/")
        XCTAssertEqual(try Bitrix24Destination.normalize("https://acme.bitrix24.ru/rest/12/abc123/crm.lead.add.json").absoluteString,
                       "https://acme.bitrix24.ru/rest/12/abc123/")
        XCTAssertEqual(try Bitrix24Destination.normalize("https://crm.example.com/rest/1/k").absoluteString,
                       "https://crm.example.com/rest/1/k/")
        XCTAssertThrowsError(try Bitrix24Destination.normalize("http://acme.bitrix24.ru/rest/1/abc/"))
        XCTAssertThrowsError(try Bitrix24Destination.normalize("https://acme.bitrix24.ru/crm/lead/"))
        XCTAssertThrowsError(try Bitrix24Destination.normalize("https://acme.bitrix24.ru/rest/x/abc/"))
        XCTAssertThrowsError(try Bitrix24Destination.normalize(""))
    }

    func testBitrixFields() throws {
        let f = Bitrix24Destination.fields(for: lead())
        XCTAssertEqual(f["TITLE"], .string("Кофейня «Зерно»"))
        XCTAssertEqual(f["COMPANY_TITLE"], .string("ООО Зерно"))
        XCTAssertEqual(f["ORIGIN_ID"], .string("l1"))
        XCTAssertEqual(f["OPPORTUNITY"], .number(50000))
        XCTAssertEqual(f["CURRENCY_ID"], .string("RUB"))
        guard case .array(let phones)? = f["PHONE"] else { return XCTFail("нет телефонов") }
        XCTAssertEqual(phones.first?["VALUE"], .string("+7 843 212-48-90"))
        XCTAssertEqual(phones.count, 2)
        guard case .array(let emails)? = f["EMAIL"] else { return XCTFail("нет email") }
        XCTAssertEqual(emails.first?["VALUE"], .string("info@zerno.ru"))
        XCTAssertTrue(f["COMMENTS"]?.stringValue?.contains("https://example.com/lead") == true)
    }

    func testBitrixRequest() throws {
        let d = try Bitrix24Destination(webhook: "https://acme.bitrix24.ru/rest/1/abc123/")
        let r = try d.request(method: "crm.lead.add", body: .object(["fields": .object([:])]))
        XCTAssertEqual(r.url?.absoluteString, "https://acme.bitrix24.ru/rest/1/abc123/crm.lead.add.json")
        XCTAssertEqual(r.httpMethod, "POST")
    }

    func testBitrixResponses() throws {
        XCTAssertEqual(CRMExporter.idString(try Bitrix24Destination.parse(Data(#"{"result": 123, "time": {}}"#.utf8), status: 200)), "123")
        func failure(_ json: String, _ status: Int) -> CRMError? {
            do { _ = try Bitrix24Destination.parse(Data(json.utf8), status: status); return nil } catch { return error as? CRMError }
        }
        XCTAssertEqual(failure(#"{"error":"QUERY_LIMIT_EXCEEDED","error_description":"Too many"}"#, 503), .rateLimited)
        if case .unauthorized? = failure(#"{"error":"INVALID_CREDENTIALS","error_description":"Invalid request credentials"}"#, 401) {} else { XCTFail() }
        if case .forbidden? = failure(#"{"error":"insufficient_scope"}"#, 401) {} else { XCTFail() }
        if case .notFound? = failure("<html>", 404) {} else { XCTFail() }
        if case .badResponse? = failure("{}", 200) {} else { XCTFail() }
        XCTAssertTrue(CRMError.unauthorized("x").stopsExport)
        XCTAssertFalse(CRMError.server(400, "x").stopsExport)
    }

    // MARK: Notion

    func testNotionDatabaseID() throws {
        XCTAssertEqual(try NotionDestination.databaseID(from: "https://www.notion.so/acme/Leads-0123456789abcdef0123456789ABCDEF?v=fedcba9876543210fedcba9876543210"),
                       "01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertEqual(try NotionDestination.databaseID(from: "01234567-89ab-cdef-0123-456789abcdef"),
                       "01234567-89ab-cdef-0123-456789abcdef")
        XCTAssertThrowsError(try NotionDestination.databaseID(from: "https://www.notion.so/acme/Leads"))
    }

    func testNotionSchemaAndAutoMapping() throws {
        let json = """
        {"object":"database","title":[{"plain_text":"Лиды"}],"properties":{
          "Название":{"id":"title","type":"title"},"Телефон":{"id":"a","type":"phone_number"},
          "Email":{"id":"b","type":"email"},"Сайт":{"id":"c","type":"url"},"Оценка":{"id":"d","type":"number"},
          "Статус":{"id":"e","type":"status"},"Город":{"id":"f","type":"select"},"Найден":{"id":"g","type":"date"}}}
        """
        let obj = try NotionDestination.check(Data(json.utf8), status: 200)
        let db = try NotionDestination.parseDatabase(obj, id: "db")
        XCTAssertEqual(db.title, "Лиды")
        XCTAssertEqual(db.properties.first?.type, "title")
        let m = NotionDestination.autoMapping(db.properties)
        XCTAssertEqual(m["Название"], .title)
        XCTAssertEqual(m["Телефон"], .phone)
        XCTAssertEqual(m["Email"], .emails)
        XCTAssertEqual(m["Сайт"], .website)
        XCTAssertEqual(m["Оценка"], .score)
        XCTAssertEqual(m["Город"], .region)
        XCTAssertEqual(m["Найден"], .discoveredAt)
        XCTAssertNil(m["Статус"], "status писать не умеем")
    }

    func testNotionValues() {
        let l = lead()
        XCTAssertEqual(NotionDestination.value(.score, of: l, type: "number"), .object(["number": .number(72)]))
        XCTAssertEqual(NotionDestination.value(.emails, of: l, type: "email"), .object(["email": .string("info@zerno.ru")]))
        XCTAssertEqual(NotionDestination.value(.phone, of: l, type: "phone_number"), .object(["phone_number": .string("+7 843 212-48-90")]))
        XCTAssertEqual(NotionDestination.value(.region, of: l, type: "select"), .object(["select": .object(["name": .string("Казань")])]))
        XCTAssertEqual(NotionDestination.value(.discoveredAt, of: l, type: "date"), .object(["date": .object(["start": .string("2026-11-05T09:00:00Z")])]))
        XCTAssertEqual(NotionDestination.value(.favorite, of: l, type: "checkbox"), .object(["checkbox": .bool(true)]))
        XCTAssertNil(NotionDestination.value(.note, of: l, type: "rich_text"), "пустое поле не отправляется")
        XCTAssertNil(NotionDestination.value(.title, of: l, type: "status"))
    }

    func testNotionPageBody() throws {
        let d = NotionDestination(token: " secret_x ", databaseID: "db-1",
                                  properties: [NotionProperty(name: "Название", type: "title"), NotionProperty(name: "Сайт", type: "url")],
                                  mapping: ["Название": .title, "Сайт": .website])
        XCTAssertEqual(d.token, "secret_x")
        let body = d.pageBody(for: lead())
        XCTAssertEqual(body["parent"], .object(["database_id": .string("db-1")]))
        XCTAssertEqual(body["properties"]?["Сайт"], .object(["url": .string("https://zerno.ru")]))
        XCTAssertNotNil(body["properties"]?["Название"])
        let text = String(data: try body.data(), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("secret_x"), "ключ не попадает в тело")
    }

    func testNotionErrors() {
        func err(_ status: Int, _ code: String) -> CRMError? {
            let json = #"{"object":"error","status":\#(status),"code":"\#(code)","message":"msg"}"#
            do { _ = try NotionDestination.check(Data(json.utf8), status: status); return nil } catch { return error as? CRMError }
        }
        if case .unauthorized? = err(401, "unauthorized") {} else { XCTFail() }
        if case .notFound? = err(404, "object_not_found") {} else { XCTFail() }
        XCTAssertEqual(err(429, "rate_limited"), .rateLimited)
        if case .server(400, let m)? = err(400, "validation_error") { XCTAssertTrue(m.contains("msg")) } else { XCTFail() }
    }

    // MARK: Вебхук, журнал, отправка

    func testWebhook() throws {
        XCTAssertThrowsError(try WebhookDestination(url: "http://hook.example.com"))
        XCTAssertNoThrow(try WebhookDestination(url: "https://hook.eu1.make.com/abc"))
        let p = WebhookDestination.payload(for: lead())
        XCTAssertEqual(p["lead_id"], .string("l1"))
        XCTAssertEqual(p["lead"]?["title"], .string("Кофейня «Зерно»"))
        XCTAssertEqual(p["lead"]?["score"], .number(72))
    }

    func testLedger() {
        var l = ExportLedger()
        l.sent["a"] = "1"
        XCTAssertEqual(ExportLedger.decode(l.encoded()), l)
        XCTAssertEqual(ExportLedger.decode(nil), ExportLedger())
        XCTAssertEqual(ExportLedger.decode("мусор"), ExportLedger())
        let k = ExportLedger.storageKey(kind: .webhook, target: "https://hook.example.com/secret-token")
        XCTAssertFalse(k.contains("secret"), "секрет из адреса не попадает в ключ")
        XCTAssertEqual(k, ExportLedger.storageKey(kind: .webhook, target: "HTTPS://hook.example.com/SECRET-token"))
    }

    struct Fake: CRMDestination {
        let kind = CRMKind.webhook
        let target = "fake"
        let pause: TimeInterval = 0
        let failing: Set<String>
        let fatal: Set<String>
        func send(_ item: LeadItem, session: URLSession) async throws -> String {
            if fatal.contains(item.id) { throw CRMError.unauthorized("нет") }
            if failing.contains(item.id) { throw CRMError.server(400, "плохие данные") }
            return "r-\(item.id)"
        }
    }

    func testRunnerSkipsDuplicatesAndReportsErrors() async {
        let items = ["a", "b", "c", "d"].map { lead($0, title: "Лид \($0)") }
        let (report, ledger) = await CRMExporter.run(items, to: Fake(failing: ["c"], fatal: []),
                                                     ledger: ExportLedger(sent: ["a": "old"]))
        XCTAssertEqual(report.exported, 2)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.failures.map(\.title), ["Лид c"])
        XCTAssertEqual(ledger.sent, ["a": "old", "b": "r-b", "d": "r-d"])
        XCTAssertFalse(report.stoppedEarly)

        let (again, _) = await CRMExporter.run(items, to: Fake(failing: [], fatal: []), ledger: ledger)
        XCTAssertEqual(again.exported, 1, "повторно уходит только c")
        XCTAssertEqual(again.skipped, 3)

        let (resent, _) = await CRMExporter.run(items, to: Fake(failing: [], fatal: []), ledger: ledger, resend: true)
        XCTAssertEqual(resent.exported, 4)
    }

    func testRunnerStopsOnAuthError() async {
        let items = ["a", "b", "c"].map { lead($0) }
        let (report, ledger) = await CRMExporter.run(items, to: Fake(failing: [], fatal: ["b"]), ledger: ExportLedger())
        XCTAssertEqual(report.exported, 1)
        XCTAssertTrue(report.stoppedEarly)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(ledger.sent.keys.sorted(), ["a"])
    }
}
