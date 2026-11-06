import Foundation
import XCTest
@testable import LeadCloud
@testable import LeadGenCore

/// Сквозной тест клиента на локальном стенде Supabase (supabase/tests/stack/up.sh):
/// настоящий Supabase Auth, PostgREST, RLS, функции писем. Без переменных LG_STACK_* пропускается.
final class StackTests: XCTestCase {
    var config: CloudConfig!
    var mailDir: URL!
    var dir: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["LG_STACK_URL"], let anon = env["LG_STACK_ANON"], let mail = env["LG_STACK_MAIL"] else {
            throw XCTSkip("локальный стенд не задан (LG_STACK_URL, LG_STACK_ANON, LG_STACK_MAIL)")
        }
        config = try XCTUnwrap(CloudConfig(url: url, anonKey: anon))
        mailDir = URL(fileURLWithPath: mail)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-stack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func code(for email: String) throws -> String {
        for _ in 0..<50 {
            let files = (try? FileManager.default.contentsOfDirectory(at: mailDir, includingPropertiesForKeys: nil)) ?? []
            for f in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where f.pathExtension == "json" {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any],
                      (obj["to"] as? [String])?.contains(email) == true, let text = obj["text"] as? String,
                      let r = text.range(of: #"Код: \d{6}"#, options: .regularExpression) else { continue }
                return String(text[r].suffix(6))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("письмо не найдено")
    }

    func device(_ name: String) throws -> (CloudAuth, LeadStore, SyncEngine) {
        let store = try LeadStore(path: dir.appendingPathComponent("\(name).db").path)
        try store.enableSyncTracking()
        let auth = CloudAuth(config: config, store: MemorySessionStore(), deviceID: "device-\(name)-\(UUID().uuidString)")
        return (auth, store, SyncEngine(auth: auth, store: store, deviceID: name, batch: 50, pageSize: 100))
    }

    func testTwoDevicesSyncThroughRealServer() async throws {
        let email = "swift-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let password = "Str0ngPassw0rd"
        let (authA, storeA, syncA) = try device("a")
        try await authA.signUp(email: email, password: password)
        do { _ = try await authA.signIn(email: email, password: password); XCTFail("вход до подтверждения") } catch {
            XCTAssertEqual(error as? CloudError, .emailNotConfirmed)
        }
        try await authA.verify(email: email, code: try code(for: email), type: "signup")
        let userA = await authA.user
        XCTAssertEqual(userA?.email, email)

        // Устройство A: 120 лидов (несколько пачек), исключение, настройка.
        for i in 0..<120 {
            try storeA.save(StoreSyncTests.lead("Заказ \(i)"), id: "L\(i)", fingerprint: "fp\(i)")
        }
        try storeA.addExclusion(.domain, "competitor.ru")
        try storeA.setSyncedValue("draft.signature", "\"Максим\"")
        let r1 = try await syncA.sync()
        XCTAssertEqual(r1.pushed, 122)
        XCTAssertTrue(try storeA.pendingChanges(limit: 10).isEmpty)

        // Устройство B: вход на новом Mac — всё загружается.
        let (authB, storeB, syncB) = try device("b")
        try await authB.signIn(email: email, password: password)
        let r2 = try await syncB.sync()
        XCTAssertGreaterThanOrEqual(r2.pulled, 122)
        XCTAssertEqual(try storeB.allLeads().count, 120)
        XCTAssertEqual(try storeB.exclusions().map(\.value), ["competitor.ru"])
        XCTAssertEqual(storeB.value("draft.signature"), "\"Максим\"")
        XCTAssertTrue(try storeB.pendingChanges(limit: 10).isEmpty)  // загруженное не уходит обратно

        // Одновременные изменения разных полей на двух устройствах — сохраняются оба.
        try storeA.setFavorite(["L1"], true)
        try storeB.setNote("L1", "позвонить в понедельник")
        try storeB.delete(["L2"])
        _ = try await syncA.sync()
        _ = try await syncB.sync()
        _ = try await syncA.sync()
        for s in [storeA, storeB] {
            let l1 = try XCTUnwrap(try s.allLeads(includeDeleted: true).first { $0.id == "L1" })
            XCTAssertTrue(l1.favorite)
            XCTAssertEqual(l1.note, "позвонить в понедельник")
            XCTAssertFalse(try s.allLeads().contains { $0.id == "L2" })
        }
        // Повторная синхронизация без изменений ничего не гоняет.
        let idle = try await syncA.sync()
        XCTAssertEqual(idle.pushed, 0)
        XCTAssertEqual(idle.pulled, 0)

        let stats = try await syncB.remoteStats()
        XCTAssertEqual(stats["leads"], 120)
        XCTAssertEqual(stats["leads_active"], 119)

        // Выход: сессия удалена, запросы к данным больше не проходят.
        await authB.signOut()
        do { _ = try await syncB.sync(); XCTFail() } catch { XCTAssertEqual(error as? CloudError, .sessionExpired) }

        // Чужой пользователь не видит этих данных.
        let other = "swift-other-\(UUID().uuidString.prefix(6).lowercased())@example.com"
        let (authC, storeC, syncC) = try device("c")
        try await authC.signUp(email: other, password: password)
        try await authC.verify(email: other, code: try code(for: other), type: "signup")
        _ = try await syncC.sync()
        XCTAssertTrue(try storeC.allLeads(includeDeleted: true).isEmpty)
    }

    func testMailLimitMessageReachesUser() async throws {
        let (auth, _, _) = try device("limit")
        let email = "swift-limit-\(UUID().uuidString.prefix(6).lowercased())@example.com"
        try await auth.signUp(email: email, password: "Str0ngPassw0rd")
        do {
            try await auth.resendConfirmation(email: email)
            XCTFail("повтор раньше 15 минут должен быть отклонён")
        } catch let CloudError.rateLimited(message) {
            XCTAssertTrue(message.contains("Повторите через"), message)
        }
    }
}
