import Foundation
import XCTest
@testable import LeadGenCore

/// Проверка адреса вебхука: в адресе ключ сценария, поэтому он уходит только по https
/// (code scanning: swift/cleartext-transmission).
final class WebhookAddressTests: XCTestCase {
    func testKeepsFullHttpsAddress() throws {
        let raw = "https://hook.eu1.make.com/abc123?token=xyz&a=1#frag"
        let u = try WebhookDestination.normalize(raw)
        XCTAssertEqual(u.absoluteString, raw)
        XCTAssertEqual(u.scheme, "https")
        XCTAssertEqual(u.host, "hook.eu1.make.com")
        XCTAssertEqual(u.path, "/abc123")
        XCTAssertEqual(u.query, "token=xyz&a=1")
    }

    func testTrimsWhitespaceAndKeepsPort() throws {
        let u = try WebhookDestination.normalize("  https://n8n.example.com:5678/webhook/lead \n")
        XCTAssertEqual(u.absoluteString, "https://n8n.example.com:5678/webhook/lead")
        XCTAssertEqual(u.port, 5678)
    }

    func testUppercaseSchemeBecomesHttps() throws {
        let u = try WebhookDestination.normalize("HTTPS://hook.example.com/x")
        XCTAssertEqual(u.scheme, "https")
        XCTAssertEqual(u.host, "hook.example.com")
        XCTAssertEqual(u.path, "/x")
    }

    func testRejectsEverythingButHttps() {
        for raw in ["http://hook.example.com/x", "HTTP://hook.example.com/x", "ftp://hook.example.com/x",
                    "ws://hook.example.com/x", "file:///etc/passwd", "hook.example.com/x",
                    "https://", "https:///path-only", "", "   ", "не адрес"] {
            XCTAssertThrowsError(try WebhookDestination.normalize(raw), raw) { error in
                guard case CRMError.invalidAddress = error else { return XCTFail("\(raw): \(error)") }
            }
            XCTAssertThrowsError(try WebhookDestination(url: raw), raw)
        }
    }

    func testDestinationUsesNormalizedAddress() throws {
        let d = try WebhookDestination(url: " https://hook.example.com/abc ")
        XCTAssertEqual(d.url.absoluteString, "https://hook.example.com/abc")
        XCTAssertEqual(d.target, "https://hook.example.com/abc")
    }
}
