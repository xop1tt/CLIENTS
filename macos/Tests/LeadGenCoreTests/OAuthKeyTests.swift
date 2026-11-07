import Foundation
import XCTest
@testable import LeadGenCore

/// «Добавить ключ»: ключ OAuth-приложения, введённый пользователем, и выбор между ним и ключом сборки.
final class OAuthKeyTests: XCTestCase {
    func testKeyValidation() {
        XCTAssertNil(OAuthKey(clientID: "abc123").problem(for: .dropbox))
        XCTAssertNil(OAuthKey(clientID: "0000-1111", clientSecret: nil).problem(for: .microsoft))
        XCTAssertNotNil(OAuthKey(clientID: "").problem(for: .dropbox))
        XCTAssertNotNil(OAuthKey(clientID: "   ").problem(for: .dropbox))
        XCTAssertNotNil(OAuthKey(clientID: "a b").problem(for: .dropbox), "пробел внутри")
        XCTAssertNotNil(OAuthKey(clientID: "$(DROPBOX_APP_KEY)").problem(for: .dropbox))
        XCTAssertNotNil(OAuthKey(clientID: "id.apps.googleusercontent.com").problem(for: .google), "Google без секрета")
        XCTAssertNotNil(OAuthKey(clientID: "id", clientSecret: "  ").problem(for: .google))
        XCTAssertNil(OAuthKey(clientID: "id.apps.googleusercontent.com", clientSecret: "GOCSPX-x").problem(for: .google))
    }

    func testKeyRoundTrip() {
        let k = OAuthKey(clientID: "id", clientSecret: "secret")
        XCTAssertEqual(OAuthKey.decode(k.encoded()), k)
        XCTAssertEqual(OAuthKey.decode(OAuthKey(clientID: "x").encoded()), OAuthKey(clientID: "x"))
        XCTAssertNil(OAuthKey.decode("не json"))
        XCTAssertNil(OAuthKey.decode(""))
        XCTAssertNil(OAuthKey.decode(nil))
    }

    func testClientFromKey() throws {
        let c = try XCTUnwrap(OAuthClient(provider: .dropbox, key: OAuthKey(clientID: " abc ")))
        XCTAssertEqual(c.clientID, "abc")
        XCTAssertNil(c.clientSecret)
        XCTAssertNil(OAuthClient(provider: .google, key: OAuthKey(clientID: "id")))
        let g = try XCTUnwrap(OAuthClient(provider: .google, key: OAuthKey(clientID: "id", clientSecret: "s")))
        XCTAssertEqual(g.clientSecret, "s")
        XCTAssertNil(OAuthClient(provider: .dropbox, key: OAuthKey(clientID: "")))
    }

    func testResolveUsesStoredKeyWhenBuildHasNone() throws {
        // В тестовом пакете ключей сборки нет: берётся введённый вручную.
        let bundle = Bundle(for: Self.self)
        XCTAssertNil(OAuthClient.resolve(.dropbox, bundle: bundle, stored: nil))
        let c = try XCTUnwrap(OAuthClient.resolve(.dropbox, bundle: bundle, stored: OAuthKey(clientID: "mine")))
        XCTAssertEqual(c.clientID, "mine")
        XCTAssertNil(OAuthClient.resolve(.google, bundle: bundle, stored: OAuthKey(clientID: "id")), "неполный ключ не годится")
        XCTAssertNil(OAuthClient.resolve(.dropbox, bundle: bundle, stored: OAuthKey(clientID: "")))
    }

    func testBuildKeyBeatsStoredKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-bundle-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = ["CFBundleIdentifier": "test.bundle", "LGDropboxAppKey": "from-build"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Contents/Info.plist"))
        guard let bundle = Bundle(url: dir), bundle.object(forInfoDictionaryKey: "LGDropboxAppKey") != nil else {
            throw XCTSkip("не удалось создать тестовый пакет на этой платформе")
        }
        let c = try XCTUnwrap(OAuthClient.resolve(.dropbox, bundle: bundle, stored: OAuthKey(clientID: "typed")))
        XCTAssertEqual(c.clientID, "from-build")
    }

    func testKeychainAccountsAreSeparateAndFreeOfSecrets() {
        XCTAssertEqual(Set(OAuthProvider.allCases.map(\.keychainAccount)).count, OAuthProvider.allCases.count)
        for p in OAuthProvider.allCases {
            XCTAssertTrue(p.keychainAccount.hasPrefix("integration.oauthkey."))
            XCTAssertEqual(p.consolePage.scheme, "https")
            XCTAssertFalse(p.clientIDLabel.isEmpty)
        }
        XCTAssertEqual(OAuthProvider.dropbox.clientIDLabel, "App key")
    }

    func testNotConfiguredErrorPointsToAddKey() {
        let text = IntegrationError.notConfigured(.google).localizedDescription
        XCTAssertTrue(text.contains("Добавить ключ"))
        XCTAssertTrue(text.contains("GOOGLE_OAUTH_CLIENT_ID"))
    }
}
