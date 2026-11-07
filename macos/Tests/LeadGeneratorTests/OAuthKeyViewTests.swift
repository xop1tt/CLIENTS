import AppKit
import SwiftUI
import XCTest
import LeadGenCore
@testable import LeadGenerator

/// Кнопка «Добавить ключ»: окно ввода строится, контроллер сохраняет и удаляет ключ (без Связки ключей в тестах).
@MainActor
final class OAuthKeyViewTests: XCTestCase {
    private func lay<V: View>(_ view: V, size: CGSize = CGSize(width: 540, height: 460)) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0, "экран ничего не нарисовал")
    }

    func testKeySheetRendersForEveryProvider() {
        let c = IntegrationsController(user: "key-test", inert: true)
        for p in OAuthProvider.allCases {
            lay(OAuthKeySheet(provider: p, controller: c).environment(\.look, AppearanceSettings.shared))
        }
    }

    func testDriveListRendersWithAndWithoutKeys() {
        let c = IntegrationsController(user: "key-test", inert: true)
        lay(Form { DriveIntegrationsList(controller: c, backupFile: { nil }) }.environment(\.look, AppearanceSettings.shared),
            size: CGSize(width: 640, height: 700))
        XCTAssertNil(c.saveKey(OAuthKey(clientID: "abc"), for: .dropbox))
        lay(Form { DriveIntegrationsList(controller: c, backupFile: { nil }) }.environment(\.look, AppearanceSettings.shared),
            size: CGSize(width: 640, height: 700))
    }

    func testSaveAndRemoveKeyMakesDriveAvailable() {
        let c = IntegrationsController(user: "key-test", inert: true)
        XCTAssertFalse(c.isAvailable(.dropbox))
        XCTAssertNotNil(c.saveKey(OAuthKey(clientID: ""), for: .dropbox), "пустой ключ отклоняется")
        XCTAssertFalse(c.isAvailable(.dropbox))
        XCTAssertNil(c.saveKey(OAuthKey(clientID: "  abc  "), for: .dropbox))
        XCTAssertEqual(c.keys[.dropbox]?.clientID, "abc", "пробелы по краям убираются")
        XCTAssertTrue(c.isAvailable(.dropbox))
        XCTAssertFalse(c.isBuiltIn(.dropbox))
        XCTAssertFalse(c.isAvailable(.oneDrive), "ключ одного сервиса не открывает другой")
        c.removeKey(for: .dropbox)
        XCTAssertNil(c.keys[.dropbox])
        XCTAssertFalse(c.isAvailable(.dropbox))
    }

    func testGoogleNeedsSecret() {
        let c = IntegrationsController(user: "key-test", inert: true)
        XCTAssertNotNil(c.saveKey(OAuthKey(clientID: "id.apps.googleusercontent.com"), for: .google))
        XCTAssertFalse(c.isAvailable(.googleDrive))
        XCTAssertNil(c.saveKey(OAuthKey(clientID: "id.apps.googleusercontent.com", clientSecret: "GOCSPX-x"), for: .google))
        XCTAssertTrue(c.isAvailable(.googleDrive))
    }

    func testSecretIsDroppedForProvidersWithoutIt() {
        let c = IntegrationsController(user: "key-test", inert: true)
        XCTAssertNil(c.saveKey(OAuthKey(clientID: "abc", clientSecret: "лишний"), for: .dropbox))
        XCTAssertNil(c.keys[.dropbox]?.clientSecret)
    }

    func testKeySheetItemIsIdentifiable() {
        XCTAssertEqual(Set(OAuthProvider.allCases.map { KeySheetItem(provider: $0).id }).count, OAuthProvider.allCases.count)
    }
}
