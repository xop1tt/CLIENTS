import XCTest
import LeadGenCore
@testable import LeadGenerator

/// Эталонные проверки состояния интерфейса: разделы, фильтры, выбор лидов, экспорт, внешний вид.
/// Без настоящей Связки ключей и без данных пользователя: модель «inert» не открывает базу.
@MainActor
final class UIStateTests: XCTestCase {
    func data(_ id: String, kind: LeadKind = .order, source: String = "fl_ru", title: String = "Нужен бот",
              region: String? = nil, score: Double = 50, relevance: Relevance = .medium) -> LeadData {
        LeadData(kind: kind, source: source, externalId: id, title: title, region: region, score: score, relevance: relevance)
    }

    func item(_ id: String, _ d: LeadData? = nil, favorite: Bool = false, archived: Bool = false,
              excluded: Bool = false, seen: Bool = false, note: String = "") -> LeadItem {
        LeadItem(id: id, data: d ?? data(id), discoveredAt: Date(), favorite: favorite, archived: archived,
                 excluded: excluded, seen: seen, note: note)
    }

    func model(_ leads: [LeadItem] = []) -> AppModel {
        let m = AppModel(username: "ui-test", dataDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("lg-ui-\(UUID().uuidString)"), inert: true)
        m.leads = leads
        return m
    }

    // MARK: разделы

    func testEverySectionHasTitleAndIcon() {
        XCTAssertEqual(NavSection.allCases.count, 8)
        for s in NavSection.allCases {
            XCTAssertFalse(s.title.isEmpty); XCTAssertFalse(s.icon.isEmpty)
        }
        XCTAssertEqual(Set(NavSection.allCases.map(\.title)).count, 8, "названия разделов не повторяются")
    }

    func testOnlyLeadSectionsAreLeadLists() {
        XCTAssertEqual(Set(NavSection.allCases.filter(\.isLeadList)), [.all, .new, .favorites, .archive, .excluded])
    }

    func testSectionsFilterLeads() {
        let m = model([
            item("a"), item("b", seen: true), item("c", favorite: true, seen: true),
            item("d", archived: true), item("e", excluded: true),
        ])
        m.section = .all;       XCTAssertEqual(Set(m.visibleLeads.map(\.id)), ["a", "b", "c"])
        m.section = .new;       XCTAssertEqual(Set(m.visibleLeads.map(\.id)), ["a"])
        m.section = .favorites; XCTAssertEqual(Set(m.visibleLeads.map(\.id)), ["c"])
        m.section = .archive;   XCTAssertEqual(Set(m.visibleLeads.map(\.id)), ["d"])
        m.section = .excluded;  XCTAssertEqual(Set(m.visibleLeads.map(\.id)), ["e"])
        m.section = .home;      XCTAssertTrue(m.visibleLeads.isEmpty)
        m.section = .sources;   XCTAssertTrue(m.visibleLeads.isEmpty)
    }

    func testCountsMatchVisibleLeadsAndHonourRejectedSwitch() {
        let m = model([item("a"), item("b", data("b", relevance: .rejected)), item("c", excluded: true)])
        m.section = .all
        XCTAssertEqual(m.count(.all), 1, "неподходящие скрыты по умолчанию")
        XCTAssertEqual(m.count(.excluded), 1)
        m.filter.hideRejected = false
        XCTAssertEqual(m.count(.all), 2)
        XCTAssertEqual(m.count(.home), 0)
    }

    func testChangingSectionOrFilterClearsSelection() {
        let m = model([item("a"), item("b")])
        m.selection = ["a"]
        m.section = .all
        XCTAssertEqual(m.selection, ["a"], "тот же раздел — выбор сохраняется")
        m.section = .new
        XCTAssertTrue(m.selection.isEmpty)
        m.selection = ["a"]
        m.filter.search = "x"
        XCTAssertTrue(m.selection.isEmpty)
    }

    // MARK: фильтры

    func testFiltersByKindSourceRegionAndScore() {
        let m = model([
            item("o1", data("o1", kind: .organization, source: "osm", region: "Казань", score: 80)),
            item("o2", data("o2", kind: .organization, source: "osm", region: "Москва", score: 30)),
            item("r1", data("r1", kind: .order, source: "fl_ru", score: 90)),
        ])
        m.filter.kind = .organization;   XCTAssertEqual(Set(m.visibleLeads.map(\.id)), ["o1", "o2"])
        m.filter = LeadFilter(); m.filter.source = "fl_ru"; XCTAssertEqual(m.visibleLeads.map(\.id), ["r1"])
        m.filter = LeadFilter(); m.filter.region = "Казань"; XCTAssertEqual(m.visibleLeads.map(\.id), ["o1"])
        m.filter = LeadFilter(); m.filter.minScore = 60; XCTAssertEqual(Set(m.visibleLeads.map(\.id)), ["o1", "r1"])
        m.filter = LeadFilter(); XCTAssertEqual(m.visibleLeads.count, 3)
        XCTAssertEqual(m.allSources, ["fl_ru", "osm"])
        XCTAssertEqual(m.allRegions, ["Казань", "Москва"])
    }

    func testSearchIsCaseInsensitiveTrimsAndLooksInNotesAndContacts() {
        var withContact = data("c", title: "Без слов")
        withContact.contacts = ["email": "Client@Example.ru"]
        let m = model([item("a", data("a", title: "Сайт для кофейни")), item("b", note: "позвонить завтра"), item("c", withContact)])
        m.filter.search = "  КОФЕЙНИ "
        XCTAssertEqual(m.visibleLeads.map(\.id), ["a"])
        m.filter.search = "ЗАВТРА"; XCTAssertEqual(m.visibleLeads.map(\.id), ["b"])
        m.filter.search = "client@example"; XCTAssertEqual(m.visibleLeads.map(\.id), ["c"])
        m.filter.search = "   "; XCTAssertEqual(m.visibleLeads.count, 3, "пробелы — пустой поиск")
        m.filter.search = "нет такого"; XCTAssertTrue(m.visibleLeads.isEmpty)
    }

    func testSelectedLeadOnlyForSingleSelection() {
        let m = model([item("a"), item("b")])
        XCTAssertNil(m.selectedLead)
        m.selection = ["a"]; XCTAssertEqual(m.selectedLead?.id, "a")
        m.selection = ["a", "b"]; XCTAssertNil(m.selectedLead)
        m.selection = ["нет"]; XCTAssertNil(m.selectedLead)
    }

    func testReloadWithoutStoreKeepsState() {
        let m = model([item("a")])
        m.selection = ["a"]
        m.reload()
        XCTAssertEqual(m.leads.count, 1); XCTAssertEqual(m.selection, ["a"])
    }

    // MARK: экспорт

    func testExportTabsAreCompleteAndConsistent() {
        XCTAssertEqual(ExportTab.allCases, [.file, .bitrix, .notion, .webhook])
        for t in ExportTab.allCases {
            XCTAssertFalse(t.title.isEmpty); XCTAssertFalse(t.menuTitle.isEmpty); XCTAssertFalse(t.icon.isEmpty)
            XCTAssertEqual(ExportTab(rawValue: t.rawValue), t)
        }
        XCTAssertNil(ExportTab.file.crm, "файл — не CRM")
        XCTAssertEqual(ExportTab.bitrix.crm, .bitrix)
        XCTAssertEqual(ExportTab.notion.crm, .notion)
        XCTAssertEqual(ExportTab.webhook.crm, .webhook)
    }

    func testLastExportTabIsRemembered() {
        let saved = UserDefaults.standard.string(forKey: ExportTab.lastKey)
        defer { UserDefaults.standard.set(saved, forKey: ExportTab.lastKey) }
        UserDefaults.standard.set("notion", forKey: ExportTab.lastKey)
        XCTAssertEqual(ExportTab.last, .notion)
        UserDefaults.standard.set("мусор", forKey: ExportTab.lastKey)
        XCTAssertEqual(ExportTab.last, .file, "неизвестное значение — вкладка «Файл»")
        UserDefaults.standard.removeObject(forKey: ExportTab.lastKey)
        XCTAssertEqual(ExportTab.last, .file)
    }

    func testExportItemsAreSelectedOrAllVisibleSortedByScore() {
        let m = model([item("low", data("low", score: 10)), item("high", data("high", score: 90)), item("mid", data("mid", score: 50))])
        XCTAssertEqual(m.exportItems.map(\.id), ["high", "mid", "low"], "без выбора — все показанные, лучшие первыми")
        m.selection = ["mid", "low"]
        XCTAssertEqual(m.exportItems.map(\.id), ["mid", "low"])
        m.selection = ["нет"]
        XCTAssertTrue(m.exportItems.isEmpty)
    }

    func testOpenExportPicksTabAndLeavesLeadListsAlone() {
        let m = model([item("a")])
        m.section = .favorites
        m.openExport(.bitrix)
        XCTAssertEqual(m.exportTab, .bitrix)
        XCTAssertEqual(m.section, .favorites, "в списке лидов раздел не меняется")
        m.section = .home
        m.openExport(.webhook)
        XCTAssertEqual(m.section, .all, "с главной экспорт открывается над списком всех лидов")
        XCTAssertEqual(m.exportTab, .webhook)
    }

    func testNotionLinkRoundTripsAndMapsFields() throws {
        let link = NotionLink(databaseID: "db1", title: "Лиды",
                              properties: [.init(name: "Название", type: "title"), .init(name: "Телефон", type: "phone_number")],
                              mapping: ["Название": "title", "Телефон": "phone", "Мусор": "нет-такого-поля"])
        let back = try JSONDecoder().decode(NotionLink.self, from: JSONEncoder().encode(link))
        XCTAssertEqual(back, link)
        XCTAssertEqual(back.notionProperties.map(\.name), ["Название", "Телефон"])
        XCTAssertNil(back.fieldMapping["Мусор"], "неизвестное поле отбрасывается")
    }

    // MARK: внешний вид

    func testZoomStepsStayInRangeAndReset() {
        let look = AppearanceSettings()
        let saved = look.scale
        defer { look.scale = saved }
        look.resetZoom(); XCTAssertEqual(look.scale, 1.0)
        for _ in 0..<20 { look.zoomIn() }
        XCTAssertEqual(look.scale, AppearanceSettings.scaleRange.upperBound)
        for _ in 0..<20 { look.zoomOut() }
        XCTAssertEqual(look.scale, AppearanceSettings.scaleRange.lowerBound)
        look.resetZoom(); look.zoomIn()
        XCTAssertGreaterThan(look.scale, 1.0)
        look.zoomOut(); XCTAssertEqual(look.scale, 1.0, accuracy: 0.001)
    }

    func testControlSizeFollowsScale() {
        let look = AppearanceSettings()
        let saved = look.scale
        defer { look.scale = saved }
        look.scale = 0.8; XCTAssertEqual(look.controlSize, .small)
        look.scale = 1.0; XCTAssertEqual(look.controlSize, .regular)
        look.scale = 1.4; XCTAssertEqual(look.controlSize, .large)
    }

    func testThemeDensityAndAccentOptionsAreComplete() {
        XCTAssertEqual(ThemeMode.allCases.count, 3)
        XCTAssertNil(ThemeMode.system.nsAppearance)
        XCTAssertNotNil(ThemeMode.light.nsAppearance); XCTAssertNotNil(ThemeMode.dark.nsAppearance)
        XCTAssertEqual(Density.allCases.map(\.rowPadding), [1, 4, 8])
        XCTAssertEqual(AccentChoice.allCases.count, 5)
        for t in ThemeMode.allCases { XCTAssertFalse(t.title.isEmpty) }
        for a in AccentChoice.allCases { XCTAssertFalse(a.title.isEmpty) }
    }

    func testScaleStepsAreSortedAndInsideRange() {
        let steps = AppearanceSettings.scaleSteps
        XCTAssertEqual(steps, steps.sorted())
        XCTAssertTrue(steps.allSatisfy { AppearanceSettings.scaleRange.contains($0) })
        XCTAssertTrue(steps.contains(1.0))
    }

    // MARK: меню и настройки

    func testSettingsSectionsAreComplete() {
        XCTAssertEqual(SettingsSection.allCases.count, 8)
        for s in SettingsSection.allCases {
            XCTAssertFalse(s.title.isEmpty); XCTAssertFalse(s.icon.isEmpty)
            XCTAssertEqual(SettingsSection(rawValue: s.rawValue), s)
        }
    }

    func testOpenSettingsRemembersSectionAndCallsOpener() {
        let saved = UserDefaults.standard.string(forKey: "settings.section")
        let opener = MenuActions.openSettingsAction
        defer { UserDefaults.standard.set(saved, forKey: "settings.section"); MenuActions.openSettingsAction = opener }
        var opened = 0
        MenuActions.openSettingsAction = { opened += 1 }
        MenuActions.openSettings(.data)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.section"), SettingsSection.data.rawValue)
        XCTAssertEqual(opened, 1)
        MenuActions.openSettings()
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.section"), SettingsSection.data.rawValue, "без раздела прежний выбор остаётся")
    }

    func testReleaseNotesPageIsAnHTTPSLink() {
        let url = MenuActions.releaseNotesPage
        XCTAssertEqual(url.scheme, "https")
        XCTAssertTrue(url.absoluteString.contains("/releases"))
    }
}
