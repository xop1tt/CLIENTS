import AppKit
import SwiftUI
import XCTest
import LeadGenCore
@testable import LeadGenerator

/// Каждый экран строится и раскладывается без сбоя, с общими объектами окружения и без них.
///
/// Вылеты «EXC_BREAKPOINT в EnvironmentValues.subscript» (issue #27) возникали, когда содержимое
/// окна оказывалось в NSHostingView без окружения. Проверка «без окружения» ловит этот класс ошибок.
@MainActor
final class ViewRenderTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lg-render-\(UUID().uuidString)")
        model = AppModel(username: "render-test", dataDirectory: directory, inert: true)
        let d = LeadData(kind: .organization, source: "osm", externalId: "1", title: "Студия «Лаванда»", region: "Казань",
                         phone: "+7 843 000-00-00", score: 80, relevance: .high)
        model.leads = [LeadItem(id: "1", data: d, discoveredAt: Date()),
                       LeadItem(id: "2", data: d, discoveredAt: Date(), favorite: true, seen: true)]
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// Размещает представление в NSHostingView и заставляет SwiftUI вычислить раскладку.
    @discardableResult
    private func lay<V: View>(_ view: V, size: CGSize = CGSize(width: 900, height: 640), file: StaticString = #filePath, line: UInt = #line) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0, "экран ничего не нарисовал", file: file, line: line)
        return host
    }

    private func withEnvironment<V: View>(_ view: V) -> some View {
        view.environment(\.appModel, model)
            .environment(\.look, AppearanceSettings.shared)
            .environment(\.session, SessionModel.shared)
    }

    // MARK: окна

    func testRootViewRendersInEveryLeadSection() {
        for section in NavSection.allCases {
            model.section = section
            lay(withEnvironment(RootView()), size: CGSize(width: 1100, height: 700))
        }
    }

    func testMainScreensRenderWithoutEnvironment() {
        lay(DashboardView())
        lay(LeadsView())
        lay(SourcesView())
        lay(SearchLogView())
        lay(SidebarView())
    }

    func testMainScreensRenderWithEnvironment() {
        lay(withEnvironment(DashboardView()))
        lay(withEnvironment(LeadsView()))
        lay(withEnvironment(SourcesView()))
        lay(withEnvironment(SearchLogView()))
        lay(withEnvironment(SidebarView()))
    }

    func testEmptyStateRendersForEveryLeadSection() {
        let empty = AppModel(username: "empty-test", dataDirectory: directory, inert: true)
        for section in NavSection.allCases {
            empty.section = section
            lay(LeadsView().environment(\.appModel, empty))
            lay(DashboardView().environment(\.appModel, empty))
        }
    }

    func testInspectorRendersSelectedLead() {
        for lead in model.leads { lay(withEnvironment(LeadInspector(lead: lead)), size: CGSize(width: 360, height: 700)) }
        model.selection = ["1"]
        lay(withEnvironment(InspectorView()), size: CGSize(width: 360, height: 700))
        model.selection = ["1", "2"]
        lay(withEnvironment(InspectorView()), size: CGSize(width: 360, height: 700))
        model.selection = []
        lay(withEnvironment(InspectorView()), size: CGSize(width: 360, height: 700))
    }

    // MARK: настройки

    func testEverySettingsSectionRenders() {
        lay(withEnvironment(AppearanceSettingsView()), size: CGSize(width: 640, height: 700))
        lay(withEnvironment(SearchSettingsView()), size: CGSize(width: 640, height: 700))
        lay(withEnvironment(AccountSettingsView()), size: CGSize(width: 640, height: 700))
        lay(withEnvironment(DataSettingsView()), size: CGSize(width: 640, height: 700))
        lay(withEnvironment(ExclusionsSettingsView()), size: CGSize(width: 640, height: 700))
        lay(withEnvironment(OutreachSettingsView()), size: CGSize(width: 640, height: 700))
        lay(withEnvironment(ReportSettingsView()), size: CGSize(width: 640, height: 700))
        lay(withEnvironment(UpdateSettingsView()), size: CGSize(width: 640, height: 700))
    }

    func testSettingsWindowRendersEverySection() {
        let saved = UserDefaults.standard.string(forKey: "settings.section")
        defer { UserDefaults.standard.set(saved, forKey: "settings.section") }
        for section in SettingsSection.allCases {
            UserDefaults.standard.set(section.rawValue, forKey: "settings.section")
            lay(SettingsView(), size: CGSize(width: 820, height: 640))
            lay(withEnvironment(SettingsView()), size: CGSize(width: 820, height: 640))
        }
    }

    // MARK: экспорт

    func testExportSheetRendersEveryTab() {
        for tab in ExportTab.allCases {
            lay(withEnvironment(ExportSheet(items: model.leads, tab: tab)), size: CGSize(width: 720, height: 640))
            lay(ExportSheet(items: [], tab: tab), size: CGSize(width: 720, height: 640))
        }
    }

    func testExportMenuButtonRenders() {
        lay(withEnvironment(ExportMenuButton(model: model)), size: CGSize(width: 200, height: 60))
    }

    // MARK: боковая панель и внешний вид

    func testSidebarFooterRendersForLocalAccount() {
        lay(SidebarFooter(model: model, session: SessionModel.shared, look: AppearanceSettings.shared), size: CGSize(width: 260, height: 80))
    }

    func testViewsRenderAtEveryScaleAndTheme() {
        let look = AppearanceSettings()
        let savedScale = look.scale
        defer { look.scale = savedScale }
        for scale in AppearanceSettings.scaleSteps {
            look.scale = scale
            lay(LeadsView().environment(\.appModel, model).environment(\.look, look))
            lay(DashboardView().environment(\.appModel, model).environment(\.look, look))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = lay(withEnvironment(LeadsView()))
            host.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
        }
    }

    func testPaletteViewsRender() {
        lay(ScoreView(score: 87), size: CGSize(width: 120, height: 40))
        lay(Card(title: "Заголовок") { Text("Содержимое") }, size: CGSize(width: 300, height: 100))
    }
}
