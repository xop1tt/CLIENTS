import AppKit
import SwiftUI
import XCTest
import LeadGenCore
@testable import LeadGenerator

/// Интеграции, окно «Написать», кнопки звонка и письма: экраны строятся без сбоев,
/// а модели без базы не трогают Связку ключей.
@MainActor
final class IntegrationViewTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lg-integr-\(UUID().uuidString)")
        model = AppModel(username: "integration-test", dataDirectory: directory, inert: true)
        let withEmail = LeadData(kind: .organization, source: "osm", externalId: "1", title: "Студия «Лаванда»",
                                 contacts: ["email": "info@lavanda.ru", "email2": "boss@lavanda.ru"],
                                 phone: "8 (843) 000-00-00", score: 80, relevance: .high)
        let bare = LeadData(kind: .order, source: "rss", externalId: "2", title: "Нужен сайт", score: 50, relevance: .medium)
        model.leads = [LeadItem(id: "1", data: withEmail, discoveredAt: Date()), LeadItem(id: "2", data: bare, discoveredAt: Date())]
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    private func lay<V: View>(_ view: V, size: CGSize = CGSize(width: 640, height: 700)) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0, "экран ничего не нарисовал")
        return host
    }

    private func env<V: View>(_ view: V) -> some View {
        view.environment(\.appModel, model).environment(\.look, AppearanceSettings.shared).environment(\.session, SessionModel.shared)
    }

    func testIntegrationsSheetRenders() {
        lay(env(IntegrationsSheet(model: model)))
        lay(IntegrationsSheet(model: model), size: CGSize(width: 600, height: 640))
    }

    func testDriveListAndWebDAVSheetRender() {
        let c = IntegrationsController(user: model.username, inert: true)
        lay(env(Form { DriveIntegrationsList(controller: c, backupFile: { nil }) }))
        for s in DriveService.allCases {
            guard case .webdav = s.auth else { continue }
            lay(env(WebDAVConnectSheet(service: s, controller: c)), size: CGSize(width: 480, height: 460))
        }
    }

    func testMailSettingsRenderInBothModes() {
        let mail = MailController(user: model.username, inert: true)
        XCTAssertEqual(mail.delivery, .mailApp, "по умолчанию — программа «Почта»")
        XCTAssertFalse(mail.smtpReady)
        lay(env(Form { MailSettingsSection(mail: mail) }))
        mail.delivery = .smtp
        mail.account = MailAccount.preset(for: "me@gmail.com")
        lay(env(Form { MailSettingsSection(mail: mail) }))
        XCTAssertFalse(mail.smtpReady, "без пароля отправка из приложения не включается")
        mail.setPassword("secret")
        XCTAssertFalse(mail.hasPassword, "модель без базы не пишет в Связку ключей")
    }

    func testInspectorRendersWriteTab() {
        for lead in model.leads { lay(env(LeadInspector(lead: lead)), size: CGSize(width: 360, height: 760)) }
    }

    func testServiceIconsRenderForEveryService() {
        for s in DriveService.allCases { lay(ServiceIcon(kind: .drive(s)), size: CGSize(width: 40, height: 40)) }
        for p in MailProvider.allCases { lay(ServiceIcon(kind: .mail(p)), size: CGSize(width: 40, height: 40)) }
        lay(ServiceIcon(kind: .mailApp), size: CGSize(width: 40, height: 40))
    }

    func testInertControllerHasNoConnectionsAndOAuthNeedsBuildKeys() {
        let c = IntegrationsController(user: "x", inert: true)
        XCTAssertTrue(c.connections.isEmpty)
        // В тестовой сборке ключей OAuth-приложений нет: кнопка у таких дисков недоступна.
        XCTAssertFalse(c.isAvailable(.googleDrive))
        XCTAssertFalse(c.isAvailable(.dropbox))
        XCTAssertFalse(c.isAvailable(.oneDrive))
        XCTAssertTrue(c.isAvailable(.yandexDisk))
        XCTAssertTrue(c.isAvailable(.mega))
        XCTAssertTrue(c.isAvailable(.webdav))
    }

    func testPKCEChallengeMatchesRFC7636() {
        // RFC 7636, приложение B.
        XCTAssertEqual(PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testModelFlagsInert() {
        XCTAssertTrue(model.isInert)
        XCTAssertTrue(AppModel.placeholder.isInert)
    }
}
