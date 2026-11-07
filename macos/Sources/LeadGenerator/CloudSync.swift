import Foundation
import LeadCloud
import LeadGenCore
import Network
import Observation

/// Сессия облака в Связке ключей macOS (не в файлах настроек).
struct KeychainSessionStore: SessionStore {
    static let key = "cloud.session"

    func load() -> CloudSession? {
        guard let text = Keychain.get(Self.key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CloudSession.self, from: data)
    }

    func save(_ session: CloudSession?) {
        guard let session, let data = try? JSONEncoder().encode(session), let text = String(data: data, encoding: .utf8) else {
            Keychain.set(Self.key, "")
            return
        }
        Keychain.set(Self.key, text)
    }
}

/// Идентификатор этого Mac для лимитов писем. Случайный, хранится в Связке ключей.
/// Сервер ему полностью не доверяет: это лишь дополнительный слой к лимитам адреса, IP и общему.
enum DeviceIdentity {
    static var id: String {
        if let v = Keychain.get("cloud.device"), !v.isEmpty { return v }
        let v = UUID().uuidString
        Keychain.set("cloud.device", v)
        return v
    }
}

/// Фоновая синхронизация открытой облачной учётной записи.
///
/// Запускается после входа, после каждого локального изменения (с задержкой 3 с, чтобы
/// собрать пачку), раз в минуту, при возвращении сети и при активации приложения.
/// Одновременно идёт не больше одной синхронизации; изменения во время неё запускают ещё одну.
@MainActor
@Observable
final class CloudSyncController {
    enum State: Equatable {
        case idle
        case syncing
        case offline
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastSync: Date?
    private(set) var pending = 0

    let auth: CloudAuth
    weak var model: AppModel?
    var onSessionExpired: (() -> Void)?

    private var running: Task<Void, Never>?
    private var again = false
    private var debounce: Task<Void, Never>?
    private var timer: Timer?
    private let monitor = NWPathMonitor()
    private var online = true

    init(auth: CloudAuth, model: AppModel) {
        self.auth = auth
        self.model = model
        lastSync = ISODate.parse(model.store?.value("sync.last_at"))
    }

    func start() {
        model?.onLocalChange = { [weak self] in self?.syncSoon() }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let was = self.online
                self.online = path.status == .satisfied
                if self.online && !was { self.syncNow() }          // сеть вернулась
                if !self.online { self.state = .offline }
            }
        }
        monitor.start(queue: DispatchQueue(label: "leadgen.network"))
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        syncNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitor.cancel()
        debounce?.cancel()
        running?.cancel()
        model?.onLocalChange = nil
    }

    func syncSoon() {
        refreshPending()
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func syncNow() {
        guard running == nil else { again = true; return }
        guard let model else { return }
        let path = model.databasePath
        guard online else { state = .offline; return }
        state = .syncing
        let auth = self.auth
        running = Task { [weak self] in
            let result: Result<SyncReport, Error>
            do {
                // Своё соединение с базой: синхронизация не мешает интерфейсу и поиску.
                let store = try LeadStore(path: path, key: try KeychainDatabaseKeyProvider.shared.databaseKey())
                let engine = SyncEngine(auth: auth, store: store, deviceID: DeviceIdentity.id)
                result = .success(try await engine.sync())
                store.db.close()
            } catch {
                result = .failure(error)
            }
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<SyncReport, Error>) {
        running = nil
        switch result {
        case .success(let r):
            state = .idle
            lastSync = r.finishedAt
            try? model?.store?.setValue("sync.last_at", ISODate.now())
            if r.pulled > 0 {
                model?.reload()
                model?.reloadSyncedSettings()
            }
        case .failure(let e):
            switch e as? CloudError {
            case .sessionExpired?:
                state = .failed(CloudError.sessionExpired.localizedDescription)
                onSessionExpired?()
                return
            case .network?:
                state = .offline
            default:
                state = .failed(e.localizedDescription)
            }
        }
        refreshPending()
        if again { again = false; syncNow() }
    }

    private func refreshPending() { pending = model?.store?.pendingSyncCount ?? 0 }

    /// Короткая подпись для боковой панели.
    var summary: String {
        switch state {
        case .syncing: return "Синхронизация…"
        case .offline: return pending > 0 ? "Нет сети · ждут отправки: \(pending)" : "Нет сети · работа без облака"
        case .failed: return "Ошибка синхронизации"
        case .idle:
            if pending > 0 { return "Ждут отправки: \(pending)" }
            return lastSync.map { "Синхронизировано \($0.shortRelative)" } ?? "Облако подключено"
        }
    }

    var icon: String {
        switch state {
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "icloud.slash"
        case .failed: return "exclamationmark.icloud"
        case .idle: return pending > 0 ? "icloud.and.arrow.up" : "checkmark.icloud"
        }
    }
}
