import Foundation
import XCTest
@testable import LeadGenCore
@testable import LeadSearch

final class SearchTextTests: XCTestCase {
    /// Значения посчитаны Python-версией: старые лиды и новые совпадают по ID и отпечатку.
    func testParityWithPython() {
        XCTAssertEqual(SearchText.shortHash("abc"), "ba7816bf8f01cfea414140de")
        XCTAssertEqual(SearchText.leadId(source: "fl_ru", externalId: "55"), "f799338367e4bad8e2cc757d")
        let order = LeadData(kind: .order, source: "fl_ru", externalId: "55", title: "Нужен Telegram-бот!",
                             description: "Ищу разработчика ёлки: https://x.ru/a, бюджет 40к")
        XCTAssertEqual(SearchText.fingerprint(order), "de84251497b9b137f0137d6e")
        let org = LeadData(kind: .organization, source: "osm_organizations", externalId: "node/1", title: "Лаванда",
                           website: "https://www.Lavanda.ru/about")
        XCTAssertEqual(SearchText.fingerprint(org), "de37bc45ae1a1ab67798eb98")
        XCTAssertEqual(SearchText.normalize("Нужен Telegram-бот! Ёлка https://x.ru/a, 40к"), "нужен telegram бот елка 40к")
    }

    func testHTMLAndContacts() {
        XCTAssertEqual(SearchText.htmlToText("<p>Нужен сайт &amp; форма &#171;записи&#187;</p>"), "Нужен сайт & форма «записи»")
        XCTAssertEqual(SearchText.htmlToText("Строка 1<br/>Строка <b>2</b>", lines: true), "Строка 1\nСтрока 2")
        let c = SearchText.contacts("Пишите на mail@studio.ru. или +7 (900) 123-45-67, tg @client_manager")
        XCTAssertEqual(c["email"], "mail@studio.ru")
        XCTAssertEqual(c["phone"], "+79001234567")
        XCTAssertEqual(c["telegram"], "@client_manager")
        XCTAssertTrue(SearchText.prefilter("Разработка сайта", ["разработ"]))
        XCTAssertFalse(SearchText.prefilter("Дизайн логотипа", ["разработ", "бот"]))
        XCTAssertTrue(SearchText.prefilter("что угодно", []))
    }

    func testBudget() {
        XCTAssertEqual(Budget.parse("Бюджет: 50к")?.value, 50000)
        XCTAssertEqual(Budget.parse("500 $")?.currency, "USD")
        XCTAssertEqual(Budget.parse("Оплата 1.500.000 руб")?.value, 1_500_000)
        XCTAssertNil(Budget.parse("$500"))
        XCTAssertNil(Budget.parse("Нужно 3 страницы"))
    }

    func testSourceInput() {
        XCTAssertEqual(SourceInput.telegramChannel("https://t.me/s/freetasks"), "freetasks")
        XCTAssertEqual(SourceInput.telegramChannel("@freetasks"), "freetasks")
        XCTAssertNil(SourceInput.telegramChannel("плохое имя"))
        XCTAssertEqual(SourceInput.vkCommunity("https://vk.com/club_orders"), "club_orders")
        XCTAssertEqual(SourceInput.feedURL("www.fl.ru/rss/all.xml"), "https://www.fl.ru/rss/all.xml")
        XCTAssertNil(SourceInput.feedURL("http://localhost/rss"))
        XCTAssertEqual(SourceInput.split("сайт, бот;\nпарсер\n\n"), ["сайт", "бот", "парсер"])
    }

    func testSettingsKeepUnknownAndMissingFields() {
        var s = SearchSettings()
        s.telegram.channels = ["mychannel"]
        let restored = SearchSettings.decode(s.encoded())
        XCTAssertEqual(restored, s)
        // Старый JSON без новых полей: значения по умолчанию, а не сброс.
        let partial = SearchSettings.decode(#"{"telegram":{"channels":["a_channel"]}}"#)
        XCTAssertEqual(partial.telegram.channels, ["a_channel"])
        XCTAssertEqual(partial.telegram.maxPages, 3)
        XCTAssertTrue(partial.rss.enabled)
    }
}

final class ScoringTests: XCTestCase {
    let now = ISODate.parse("2026-11-06T11:00:00+00:00")!

    func testOrderMatchesPython() {
        // Тот же пример в Python-версии даёт 80, «high», telegram_bot, бюджет 30 000.
        let text = "Ищу разработчика Telegram-бота для записи клиентов.\nБюджет 30 000 руб. Пишите @client_manager"
        var lead = LeadData(kind: .order, source: "telegram_channels", externalId: "freetasks/1201",
                            title: "Ищу разработчика Telegram-бота для записи клиентов.", description: text,
                            publishedAt: now.addingTimeInterval(-3600))
        Scorer().scoreOrder(&lead, now: now)
        XCTAssertEqual(lead.score, 80)
        XCTAssertEqual(lead.relevance, .high)
        XCTAssertEqual(lead.projectType, "telegram_bot")
        XCTAssertEqual(lead.budget, 30000)
        XCTAssertEqual(lead.scoreReasons.first, "тематика «telegram_bot» (+30)")
    }

    func testRejections() {
        var stop = LeadData(kind: .order, source: "x", externalId: "1", title: "Разработчик сайтов в штат, оклад")
        Scorer().scoreOrder(&stop, now: now)
        XCTAssertEqual(stop.relevance, .rejected)
        var offtopic = LeadData(kind: .order, source: "x", externalId: "2", title: "Ищу дизайнера логотипа")
        Scorer().scoreOrder(&offtopic, now: now)
        XCTAssertEqual(offtopic.scoreReasons, ["нет признаков разработки"])
        var old = LeadData(kind: .order, source: "x", externalId: "3", title: "Нужен лендинг", publishedAt: now.addingTimeInterval(-30 * 86400))
        Scorer().scoreOrder(&old, now: now)
        XCTAssertEqual(old.scoreReasons.last, "устарело")
    }

    func testOrganization() {
        var lead = LeadData(kind: .organization, source: "osm_organizations", externalId: "node/1", title: "Лаванда",
                            category: "Салоны красоты", phone: "+7 843 000-00-00")
        Scorer().scoreOrganization(&lead, categoryWeight: 20, signals: ["no_website": true])
        XCTAssertEqual(lead.score, 65)  // 20 + 35 + 10
        XCTAssertEqual(lead.relevance, .high)
    }
}

final class SourceParsingTests: XCTestCase {
    static let rss = """
    <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>FL</title>
    <item><title><![CDATA[Сделать лендинг для студии]]></title><link>https://www.fl.ru/projects/1/</link>
    <guid>https://www.fl.ru/projects/1/</guid><description><![CDATA[<p>Нужен сайт &amp; форма записи. Бюджет 20 000 руб.</p>]]></description>
    <pubDate>Thu, 05 Nov 2026 10:00:00 +0300</pubDate><category>Сайты</category></item>
    <item><title>Ищу дизайнера логотипа</title><link>https://www.fl.ru/projects/2/</link><guid>https://www.fl.ru/projects/2/</guid>
    <description>Логотип для кафе</description></item>
    </channel></rss>
    """

    static let telegram = """
    <div class="tgme_widget_message_wrap js-widget_message_wrap"><div class="tgme_widget_message text_not_supported_wrap js-widget_message" data-post="freetasks/1201" data-view="x">
    <div class="tgme_widget_message_bubble"><div class="tgme_widget_message_text js-message_text" dir="auto">Ищу разработчика <b>Telegram-бота</b> для записи клиентов.<br/>Бюджет 30 000 руб. Пишите @client_manager</div>
    <div class="tgme_widget_message_footer"><a class="tgme_widget_message_date" href="https://t.me/freetasks/1201"><time datetime="2026-11-06T10:00:00+00:00" class="time">10:00</time></a></div></div></div></div>
    <div class="tgme_widget_message_wrap"><div class="tgme_widget_message js-widget_message" data-post="freetasks/1200">
    <div class="tgme_widget_message_text js-message_text" dir="auto">Продам курс по маркетингу</div>
    <time datetime="2026-11-06T09:00:00+00:00"></time></div></div>
    """

    func testRSS() throws {
        let entries = try XCTUnwrap(FeedParser.parse(Data(Self.rss.utf8)))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "Сделать лендинг для студии")
        XCTAssertEqual(entries[0].id, "https://www.fl.ru/projects/1/")
        XCTAssertEqual(entries[0].category, "Сайты")
        XCTAssertEqual(entries[0].published, ISODate.parse("2026-11-05T07:00:00+00:00"))
        XCTAssertEqual(SearchText.htmlToText(entries[0].summary), "Нужен сайт & форма записи. Бюджет 20 000 руб.")
        XCTAssertNil(FeedParser.parse(Data("не xml".utf8)))
    }

    func testTelegram() {
        let posts = TelegramSource.parse(Self.telegram)
        XCTAssertEqual(posts.map(\.id), [1201, 1200])
        XCTAssertEqual(posts[0].text, "Ищу разработчика Telegram-бота для записи клиентов.\nБюджет 30 000 руб. Пишите @client_manager")
        XCTAssertEqual(posts[0].published, ISODate.parse("2026-11-06T10:00:00+00:00"))
        XCTAssertEqual(posts[0].url, "https://t.me/freetasks/1201")
    }

    func testOverpassQuery() {
        let q = OSMSource.buildQuery(region: "Ереван", filters: [#"["shop"="beauty"]"#])
        XCTAssertEqual(q, #"[out:json][timeout:90];area["name"="Ереван"]["boundary"="administrative"]->.a0;area["name:ru"="Ереван"]["boundary"="administrative"]->.a1;area["name:en"="Ереван"]["boundary"="administrative"]->.a2;(.a0;.a1;.a2;)->.a;(nwr["shop"="beauty"](area.a););out center tags;"#)
    }

    func testPublicURL() {
        XCTAssertTrue(SiteChecker.isPublicHTTPURL("https://example.ru"))
        XCTAssertFalse(SiteChecker.isPublicHTTPURL("http://192.168.1.1"))
        XCTAssertFalse(SiteChecker.isPublicHTTPURL("ftp://example.ru"))
        XCTAssertFalse(SiteChecker.isPublicHTTPURL("http://172.20.0.1"))
    }
}

/// Подмена сети для тестов.
struct MockTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> HTTPResponse
    func send(_ request: URLRequest) async throws -> HTTPResponse { handler(request) }
}

final class EngineTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    static let overpass = """
    {"elements":[
      {"type":"node","id":42,"lat":55.79,"lon":49.12,"tags":{"name":"Студия «Лаванда»","shop":"beauty","phone":"+7 843 212-48-90","addr:street":"Баумана","addr:housenumber":"44"}},
      {"type":"node","id":43,"tags":{"shop":"beauty"}}
    ]}
    """

    func transport() -> MockTransport {
        MockTransport { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://example.com/rss") {
                return HTTPResponse(status: 200, data: Data(SourceParsingTests.rss.utf8), headers: ["ETag": "v1"], url: req.url)
            }
            if url.hasPrefix("https://t.me/s/freetasks") {
                return HTTPResponse(status: 200, data: Data(SourceParsingTests.telegram.utf8), url: req.url)
            }
            if url.hasPrefix("https://overpass.example") {
                return HTTPResponse(status: 200, data: Data(Self.overpass.utf8), url: req.url)
            }
            return HTTPResponse(status: 404, data: Data(), url: req.url)
        }
    }

    func settings() -> SearchSettings {
        var s = SearchSettings()
        s.rss.feeds = ["https://example.com/rss"]
        s.telegram.channels = ["freetasks"]
        s.vk.enabled = true  // без ключа: должен быть пропущен с понятной причиной
        s.osm.regions = ["Казань"]
        s.osm.endpoint = "https://overpass.example/api/interpreter"
        s.osm.checkWebsites = false
        for i in s.osm.categories.indices { s.osm.categories[i].enabled = s.osm.categories[i].key == "beauty" }
        return s
    }

    func testFullRunAndRepeat() async throws {
        let store = try LeadStore(path: dir.appendingPathComponent("leads.db").path)
        let now = ISODate.parse("2026-11-06T11:00:00+00:00")!
        let engine = SearchEngine(settings: settings(), secrets: SearchSecrets(), transport: transport(), repository: store,
                                  sleep: { _ in }, now: { now })
        let first = await engine.run()
        XCTAssertEqual(first.added, 4, first.summary)  // 2 из RSS, 1 из Telegram (второй пост не прошёл фильтр), 1 организация
        XCTAssertTrue(first.failed.isEmpty)
        XCTAssertEqual(first.sources.first { $0.source == SourceKey.vk }?.skipped, "нет сервисного ключа VK")

        let leads = try store.allLeads()
        let tg = try XCTUnwrap(leads.first { $0.id == SearchText.leadId(source: SourceKey.telegram, externalId: "freetasks/1201") })
        XCTAssertEqual(tg.data.relevance, .high)
        XCTAssertEqual(tg.data.contacts["telegram"], "@client_manager")
        let org = try XCTUnwrap(leads.first { $0.data.kind == .organization })
        XCTAssertEqual(org.data.category, "Салоны красоты")
        XCTAssertEqual(org.data.address, "Баумана, 44")
        XCTAssertTrue(org.data.facts.contains { $0.contains("не указан сайт") })
        XCTAssertNotNil(store.value("last_search_at"))
        XCTAssertEqual(try store.syncLog().count, 1)

        // Повторный запуск: всё уже обработано, курсоры и история запросов не дают дублей.
        let second = await engine.run()
        XCTAssertEqual(second.added, 0, second.summary)
        XCTAssertEqual(try store.allLeads().count, 4)

        // Без force источники не проверяются раньше своего интервала.
        let scheduled = await engine.run(SearchOptions(force: false))
        XCTAssertTrue(scheduled.sources.allSatisfy { $0.skipped != nil }, "проверены только пропущенные с причиной")
    }

    func testFailingSourceIsReported() async throws {
        let store = try LeadStore(path: dir.appendingPathComponent("leads.db").path)
        var s = settings()
        s.rss.feeds = ["https://broken.example/rss"]
        let engine = SearchEngine(settings: s, secrets: SearchSecrets(), transport: transport(), repository: store,
                                  sleep: { _ in })
        let report = await engine.run(SearchOptions(force: true, only: [SourceKey.rss]))
        XCTAssertEqual(report.sources.count, 1)
        XCTAssertTrue(report.sources[0].failed)
        XCTAssertEqual(try store.sourceStates().first { $0.source == SourceKey.rss }?.consecutiveFailures, 1)
        XCTAssertFalse(try store.pipelineErrors().isEmpty)
    }
}

final class AccountTests: XCTestCase {
    func testRegisterLoginAndPassword() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = try LocalAuthService(root: dir)
        XCTAssertFalse(auth.hasUsers)
        XCTAssertThrowsError(try auth.register(username: "ab", password: "password1")) { XCTAssertEqual($0 as? AuthError, .invalidUsername) }
        XCTAssertThrowsError(try auth.register(username: "maksim", password: "short")) { XCTAssertEqual($0 as? AuthError, .weakPassword) }
        let user = try auth.register(username: "Maksim", password: "correct horse")
        XCTAssertTrue(auth.hasUsers)
        XCTAssertThrowsError(try auth.register(username: "maksim", password: "another pass")) { XCTAssertEqual($0 as? AuthError, .exists) }
        XCTAssertEqual(try auth.login(username: "maksim", password: "correct horse").username, "Maksim")
        XCTAssertThrowsError(try auth.login(username: "maksim", password: "wrong pass")) { XCTAssertEqual($0 as? AuthError, .wrongCredentials) }
        XCTAssertThrowsError(try auth.login(username: "nobody", password: "correct horse"))
        try auth.changePassword(username: "Maksim", old: "correct horse", new: "new password")
        XCTAssertNoThrow(try auth.login(username: "Maksim", password: "new password"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: auth.dataDirectory(for: user.username).path))
        XCTAssertNotEqual(auth.dataDirectory(for: "Maksim"), auth.dataDirectory(for: "anna"))
    }
}
