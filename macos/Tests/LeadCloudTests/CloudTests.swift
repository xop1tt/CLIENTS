import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LeadCloud
@testable import LeadGenCore

final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudSession?
    init(_ v: CloudSession? = nil) { value = v }
    func load() -> CloudSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ s: CloudSession?) { lock.lock(); value = s; lock.unlock() }
}

/// Заглушка сервера: отвечает по сценарию и записывает запросы.
final class MockTransport: CloudTransport, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (Int, Any)
    private let lock = NSLock()
    var handler: Handler
    private(set) var requests: [URLRequest] = []
    init(_ h: @escaping Handler) { handler = h }
    private func record(_ r: URLRequest) -> Handler { lock.withLock { requests.append(r); return handler } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = record(request)(request)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    var paths: [String] { lock.withLock { requests.map { $0.url!.path } } }
}

let testConfig = CloudConfig(url: "https://example.supabase.co", anonKey: "sb_publishable_test")!

func tokenBody(access: String = "a1", refresh: String = "r1", expiresIn: Int = 3600, email: String = "u@example.com") -> [String: Any] {
    ["access_token": access, "refresh_token": refresh, "expires_in": expiresIn,
     "user": ["id": "11111111-1111-1111-1111-111111111111", "email": email, "email_confirmed_at": "2026-11-06T10:00:00Z"]]
}

final class ConfigTests: XCTestCase {
    func testRejectsSecretKeysAndPlainHTTP() {
        XCTAssertNotNil(CloudConfig(url: "https://abc.supabase.co/", anonKey: "sb_publishable_x"))
        XCTAssertNil(CloudConfig(url: "https://abc.supabase.co", anonKey: "sb_secret_x"))
        XCTAssertNil(CloudConfig(url: "http://abc.supabase.co", anonKey: "sb_publishable_x"))
        // JWT с ролью service_role (секретный ключ) встроить нельзя.
        let service = "eyJhbGciOiJIUzI1NiJ9." + Data(#"{"role":"service_role"}"#.utf8).base64EncodedString() + ".sig"
        XCTAssertNil(CloudConfig(url: "https://abc.supabase.co", anonKey: service))
        let anon = "eyJhbGciOiJIUzI1NiJ9." + Data(#"{"role":"anon"}"#.utf8).base64EncodedString() + ".sig"
        XCTAssertNotNil(CloudConfig(url: "https://abc.supabase.co", anonKey: anon))
    }
}

final class ValidationTests: XCTestCase {
    func testEmailAndPassword() {
        XCTAssertEqual(Validation.normalizedEmail("  User@Example.COM "), "user@example.com")
        for bad in ["", "a@b", "no-at", "a b@c.ru", "a@b.ru\r\nBcc: x@y.ru"] { XCTAssertNil(Validation.normalizedEmail(bad), bad) }
        XCTAssertNil(Validation.passwordProblem("Str0ngPass"))
        XCTAssertNotNil(Validation.passwordProblem("short1A"))
        XCTAssertNotNil(Validation.passwordProblem("alllowercase1"))
        XCTAssertNotNil(Validation.passwordProblem("NoDigitsHere"))
        XCTAssertEqual(Validation.code(" 123 456 "), "123456")
        XCTAssertNil(Validation.code("12"))
    }

    func testAuthErrorMapping() {
        func map(_ status: Int, _ body: [String: Any]) -> CloudError {
            CloudError.fromAuth(status: status, data: try! JSONSerialization.data(withJSONObject: body))
        }
        XCTAssertEqual(map(400, ["error_code": "invalid_credentials", "msg": "x"]), .invalidCredentials)
        XCTAssertEqual(map(400, ["error_code": "email_not_confirmed"]), .emailNotConfirmed)
        XCTAssertEqual(map(422, ["error_code": "weak_password"]), .weakPassword(nil))
        XCTAssertEqual(map(403, ["error_code": "otp_expired"]), .invalidCode)
        XCTAssertEqual(map(400, ["error_code": "refresh_token_already_used"]), .sessionExpired)
        XCTAssertEqual(map(500, ["error_code": "unexpected_failure", "msg": "Service currently unavailable due to hook"]), .mailUnavailable)
        if case .rateLimited = map(429, ["error_code": "over_request_rate_limit"]) {} else { XCTFail() }
    }
}

final class AuthClientTests: XCTestCase {
    func testSignUpAsksGateFirstAndStopsOnLimit() async throws {
        let t = MockTransport { req in
            if req.url!.path.hasSuffix("email-gate") {
                return (429, ["allowed": false, "reason": "cooldown", "retry_after": 600,
                              "message": "Письмо уже отправлено, проверьте почту. Повторите через 10 мин."])
            }
            return (200, [:])
        }
        let auth = CloudAuth(config: testConfig, transport: t, store: MemorySessionStore(), deviceID: "dev")
        do {
            try await auth.signUp(email: "u@example.com", password: "Str0ngPass")
            XCTFail("ожидался отказ")
        } catch let CloudError.rateLimited(m) {
            XCTAssertTrue(m.contains("10 мин"))
        }
        XCTAssertEqual(t.paths, ["/functions/v1/email-gate"])  // до Auth дело не дошло
        let gateBody = try JSONSerialization.jsonObject(with: t.requests[0].httpBody!) as! [String: String]
        XCTAssertEqual(gateBody["device_id"], "dev")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
    }

    func testWeakPasswordAndBadEmailNeverHitNetwork() async {
        let t = MockTransport { _ in (200, [:]) }
        let auth = CloudAuth(config: testConfig, transport: t, store: MemorySessionStore(), deviceID: "d")
        do { try await auth.signUp(email: "bad", password: "Str0ngPass"); XCTFail() } catch { XCTAssertEqual(error as? CloudError, .invalidEmail) }
        do { try await auth.signUp(email: "a@b.ru", password: "weak"); XCTFail() } catch {
            if case .weakPassword = error as? CloudError {} else { XCTFail("\(error)") }
        }
        XCTAssertTrue(t.paths.isEmpty)
    }

    func testSignInStoresSessionAndRefreshesWhenExpiring() async throws {
        let store = MemorySessionStore()
        var refreshes = 0
        let t = MockTransport { req in
            let q = req.url!.query ?? ""
            if q.contains("grant_type=password") { return (200, tokenBody(access: "old", refresh: "r1", expiresIn: 10)) }
            if q.contains("grant_type=refresh_token") { refreshes += 1; return (200, tokenBody(access: "new", refresh: "r2")) }
            return (200, [])
        }
        let auth = CloudAuth(config: testConfig, transport: t, store: store, deviceID: "d")
        try await auth.signIn(email: "u@example.com", password: "Str0ngPass")
        XCTAssertEqual(store.load()?.accessToken, "old")
        // Токен истекает через 10 с — перед запросом он обновляется один раз даже при параллельных вызовах.
        async let a = auth.validSession()
        async let b = auth.validSession()
        let (s1, s2) = try await (a, b)
        XCTAssertEqual(s1.accessToken, "new"); XCTAssertEqual(s2.accessToken, "new")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(store.load()?.refreshToken, "r2")
    }

    func testRevokedSessionSignsOut() async throws {
        let expired = CloudSession(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(-5),
                                   user: CloudUser(id: "1", email: "u@example.com"))
        let store = MemorySessionStore(expired)
        let t = MockTransport { _ in (400, ["error_code": "refresh_token_not_found", "msg": "Invalid Refresh Token"]) }
        let auth = CloudAuth(config: testConfig, transport: t, store: store, deviceID: "d")
        do { _ = try await auth.validSession(); XCTFail() } catch { XCTAssertEqual(error as? CloudError, .sessionExpired) }
        XCTAssertNil(store.load())
    }

    func testRetryOnceOn401() async throws {
        let s = CloudSession(accessToken: "stale", refreshToken: "r", expiresAt: Date().addingTimeInterval(3000),
                             user: CloudUser(id: "1", email: "u@example.com"))
        let t = MockTransport { req in
            if req.url!.query?.contains("refresh_token") == true { return (200, tokenBody(access: "fresh")) }
            return req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" ? (200, []) : (401, ["message": "JWT expired"])
        }
        let auth = CloudAuth(config: testConfig, transport: t, store: MemorySessionStore(s), deviceID: "d")
        let (_, res) = try await auth.authorized("GET", "/rest/v1/leads")
        XCTAssertEqual(res.statusCode, 200)
    }

    func testCallbackParsing() async throws {
        let t = MockTransport { req in
            req.url!.path == "/auth/v1/user" ? (200, ["id": "u1", "email": "u@example.com"]) : (404, [:])
        }
        let auth = CloudAuth(config: testConfig, transport: t, store: MemorySessionStore(), deviceID: "d")
        let ok = try await auth.handleCallback(URL(string: "leadgenerator://auth/callback#access_token=A&refresh_token=R&expires_in=3600&type=recovery")!)
        XCTAssertEqual(ok, .signedIn(type: "recovery"))
        let user = await auth.user
        XCTAssertEqual(user?.email, "u@example.com")
        let msg = try await auth.handleCallback(URL(string: "leadgenerator://auth/callback#message=Confirmation+link+accepted")!)
        XCTAssertEqual(msg, .message("Confirmation link accepted"))
        do {
            _ = try await auth.handleCallback(URL(string: "leadgenerator://auth/callback#error=access_denied&error_code=otp_expired&error_description=expired")!)
            XCTFail()
        } catch { XCTAssertEqual(error as? CloudError, .invalidCode) }
    }
}

/// Локальная база ↔ облако на заглушке сервера с той же логикой слияния, что и sync_push.
final class StoreSyncTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func store(_ name: String) throws -> LeadStore {
        let s = try LeadStore(path: dir.appendingPathComponent("\(name).db").path)
        try s.enableSyncTracking()
        return s
    }

    static func lead(_ title: String = "Нужен сайт") -> LeadData {
        LeadData(kind: .order, source: "fl_ru", externalId: "1", title: title, discoveredAt: Date(timeIntervalSince1970: 1_790_000_000),
                 score: 70, relevance: .medium)
    }

    func testJournalSurvivesReopenAndClearsAfterPush() throws {
        let s = try store("a")
        try s.save(Self.lead(), id: "L1", fingerprint: "fp")
        try s.setFavorite(["L1"], true)
        try s.setNote("L1", "позвонить")
        try s.addExclusion(.domain, "example.ru")
        try s.setSyncedValue("draft.signature", "\"Максим\"")
        // «Аварийное завершение»: открываем базу заново — журнал на месте.
        let reopened = try LeadStore(path: s.path)
        XCTAssertTrue(reopened.syncTracking)
        let p = try reopened.pendingChanges(limit: 100)
        XCTAssertEqual(p.leads.count, 1)
        XCTAssertEqual(Set(p.leads[0].ts.keys), ["data", "favorite", "note"])
        XCTAssertTrue(p.leads[0].favorite)
        XCTAssertEqual(p.exclusions, [ExclusionChange(kind: "domain", value: "example.ru", deleted: false, changed_at: p.exclusions[0].changed_at)])
        XCTAssertEqual(p.settings.first?.value, .string("Максим"))
        try reopened.markPushed(p)
        XCTAssertTrue(try reopened.pendingChanges(limit: 100).isEmpty)
    }

    func testChangeDuringPushStaysInJournal() throws {
        let s = try store("a")
        try s.save(Self.lead(), id: "L1", fingerprint: "fp")
        let p = try s.pendingChanges(limit: 100)
        Thread.sleep(forTimeInterval: 0.01)
        try s.setNote("L1", "изменено во время выгрузки")
        try s.markPushed(p)
        let left = try s.pendingChanges(limit: 100)
        XCTAssertEqual(left.leads.first.map { Set($0.ts.keys) }, ["note"])
    }

    func testApplyRemoteDoesNotEchoAndRespectsNewerLocal() throws {
        let s = try store("a")
        try s.save(Self.lead(), id: "L1", fingerprint: "fp")
        try s.markPushed(try s.pendingChanges(limit: 100))
        try s.setNote("L1", "локально новее")
        let older = "2001-01-01T00:00:00Z"
        let remote = RemoteLead(lead_id: "L1", fingerprint: "fp", kind: "order", source: "fl_ru", title: "Нужен сайт", score: 70,
                                relevance: "medium", discovered_at: "2026-09-21T13:46:40+00:00",
                                data: JSONValue.parse(String(data: try JSONEncoder().encode(Self.lead()), encoding: .utf8)!)!,
                                favorite: true, archived: false, deleted: false, seen: true, note: "старое с сервера",
                                field_ts: ["favorite": "2099-01-01T00:00:00Z", "note": older, "seen": "2099-01-01T00:00:00Z"],
                                server_seq: 5)
        try s.applyRemote(leads: [remote], exclusions: [], settings: [])
        let item = try XCTUnwrap(try s.allLeads().first)
        XCTAssertTrue(item.favorite)            // с сервера
        XCTAssertEqual(item.note, "локально новее")  // локальное новее — не затёрто
        // Применённое с сервера не попало в журнал (нет эха), осталась только заметка.
        XCTAssertEqual(try s.pendingChanges(limit: 10).leads.first.map { Set($0.ts.keys) }, ["note"])
    }

    func testRemoteDeletionAndNewLeadFromOtherDevice() throws {
        let s = try store("a")
        try s.addExclusion(.domain, "old.ru")
        try s.markPushed(try s.pendingChanges(limit: 100))
        let data = JSONValue.parse(String(data: try JSONEncoder().encode(Self.lead("С другого Mac")), encoding: .utf8)!)!
        try s.applyRemote(
            leads: [RemoteLead(lead_id: "L9", fingerprint: "x", kind: "order", source: "fl_ru", title: "С другого Mac", score: 1,
                               relevance: "low", discovered_at: "2026-11-01T10:00:00Z", data: data, favorite: false, archived: false,
                               deleted: true, seen: false, note: "", field_ts: [:], server_seq: 3)],
            exclusions: [RemoteExclusion(kind: "domain", value: "old.ru", deleted: true, changed_at: "2099-01-01T00:00:00Z", server_seq: 4)],
            settings: [RemoteSetting(key: "search.auto", value: .number(30), changed_at: "2026-11-01T10:00:00Z", server_seq: 5),
                       RemoteSetting(key: "evil.key", value: .string("x"), changed_at: "2026-11-01T10:00:00Z", server_seq: 6)])
        XCTAssertTrue(try s.exclusions().isEmpty)
        XCTAssertEqual(try s.allLeads(includeDeleted: true).map(\.id), ["L9"])
        XCTAssertTrue(try s.allLeads().isEmpty)  // удалённый на другом устройстве — скрыт, поиск его не вернёт
        XCTAssertEqual(s.value("search.auto"), "30")
        XCTAssertNil(s.value("evil.key"))
        XCTAssertTrue(try s.pendingChanges(limit: 10).isEmpty)
    }

    func testImportLocalAccountCopiesWithoutDuplicatesAndEarlyStamp() throws {
        let local = try LeadStore(path: dir.appendingPathComponent("local-src.db").path)
        try local.save(Self.lead("Первый"), id: "A", fingerprint: "fpA")
        try local.save(Self.lead("Второй"), id: "B", fingerprint: "fpB")
        try local.setFavorite(["A"], true)
        try local.addExclusion(.domain, "spam.ru")
        try local.setValue("draft.signature", "\"Подпись\"")
        let cloud = try store("cloud")
        try cloud.save(Self.lead("Уже в облаке"), id: "B2", fingerprint: "fpB")   // тот же отпечаток
        try cloud.markPushed(try cloud.pendingChanges(limit: 100))

        XCTAssertEqual(try cloud.importFrom(local), 1)
        XCTAssertEqual(try cloud.allLeads().map(\.id).sorted(), ["A", "B2"])
        XCTAssertEqual(try cloud.allLeads().first { $0.id == "A" }?.favorite, true)
        XCTAssertEqual(cloud.value("draft.signature"), "\"Подпись\"")
        let p = try cloud.pendingChanges(limit: 100)
        XCTAssertEqual(p.leads.map(\.lead_id), ["A"])
        XCTAssertEqual(p.leads[0].ts["favorite"], LeadStore.stamp(LeadStore.importStamp))
        XCTAssertEqual(p.exclusions.map(\.value), ["spam.ru"])
        XCTAssertEqual(p.settings.map(\.key), ["draft.signature"])
        // Источник не изменился и журнала не ведёт.
        XCTAssertEqual(try local.allLeads().count, 2)
        XCTAssertFalse(local.syncTracking)
        // Повторный перенос ничего не дублирует.
        XCTAssertEqual(try cloud.importFrom(local), 0)
    }

    func testLocalOnlyAccountsDoNotJournal() throws {
        let s = try LeadStore(path: dir.appendingPathComponent("local.db").path)
        try s.save(Self.lead(), id: "L1", fingerprint: "fp")
        try s.setFavorite(["L1"], true)
        XCTAssertTrue(try s.pendingChanges(limit: 10).isEmpty)
    }
}
