import AppKit
import LeadGenCore
import SwiftUI

enum NavSection: String, Hashable, CaseIterable, Identifiable {
    case home, all, new, favorites, archive, excluded, sources, runs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Главная"
        case .all: return "Все лиды"
        case .new: return "Новые"
        case .favorites: return "Избранное"
        case .archive: return "Архив"
        case .excluded: return "Исключённые"
        case .sources: return "Источники"
        case .runs: return "История запусков"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .all: return "tray.full"
        case .new: return "sparkles"
        case .favorites: return "star"
        case .archive: return "archivebox"
        case .excluded: return "nosign"
        case .sources: return "cylinder.split.1x2"
        case .runs: return "clock.arrow.circlepath"
        }
    }
    var isLeadList: Bool { [.all, .new, .favorites, .archive, .excluded].contains(self) }
}

/// Фильтры списка лидов.
struct LeadFilter: Equatable {
    var search = ""
    var kind: LeadKind?
    var source: String?
    var minScore: Double = 0
    var hideRejected = true
    var region: String?
}

@MainActor
@Observable
final class AppModel {
    private(set) var store: LeadStore?
    var startupError: String?

    var leads: [LeadItem] = []
    var sources: [SourceState] = []
    var pipelineErrors: [PipelineError] = []
    var exclusions: [Exclusion] = []
    var syncLog: [SyncLogEntry] = []
    var runs: [WorkflowRun] = []

    var section: NavSection = .all
    var filter = LeadFilter()
    var selection: Set<String> = []
    var inspectorShown = true
    var selectedSource: String?

    var syncing = false
    var dispatching = false
    var lastMessage: String?
    var lastError: String?

    private var syncTimer: Timer?
    private let defaults = UserDefaults.standard

    // MARK: Настройки синхронизации

    var githubOwner: String { didSet { defaults.set(githubOwner, forKey: "sync.owner") } }
    var githubRepo: String { didSet { defaults.set(githubRepo, forKey: "sync.repo") } }
    var githubBranch: String { didSet { defaults.set(githubBranch, forKey: "sync.branch") } }
    var autoSyncMinutes: Int { didSet { defaults.set(autoSyncMinutes, forKey: "sync.interval"); scheduleAutoSync() } }
    var signature: String { didSet { defaults.set(signature, forKey: "draft.signature") } }
    var backupDirectory: String { didSet { defaults.set(backupDirectory, forKey: "data.backupDir") } }
    var autoBackup: Bool { didSet { defaults.set(autoBackup, forKey: "data.autoBackup") } }
    var keepBackups: Int { didSet { defaults.set(keepBackups, forKey: "data.keepBackups") } }

    var githubConfig: GitHubConfig { GitHubConfig(owner: githubOwner, repo: githubRepo, branch: githubBranch) }
    var hasToken: Bool { !(Keychain.get("github.token") ?? "").isEmpty }
    var hasSecret: Bool { !(Keychain.get("state.secret") ?? "").isEmpty }
    var syncConfigured: Bool { githubConfig.isComplete && hasToken && hasSecret }

    static var defaultDatabasePath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lead Generator/leads.db").path
    }

    var databasePath: String { store?.path ?? (defaults.string(forKey: "data.path") ?? Self.defaultDatabasePath) }

    init() {
        githubOwner = defaults.string(forKey: "sync.owner") ?? "xop1tt"
        githubRepo = defaults.string(forKey: "sync.repo") ?? "CLIENTS"
        githubBranch = defaults.string(forKey: "sync.branch") ?? "main"
        let interval = defaults.integer(forKey: "sync.interval")
        autoSyncMinutes = defaults.object(forKey: "sync.interval") == nil ? 30 : interval
        signature = defaults.string(forKey: "draft.signature") ?? ""
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        backupDirectory = defaults.string(forKey: "data.backupDir") ?? docs.appendingPathComponent("Lead Generator Backups").path
        autoBackup = defaults.object(forKey: "data.autoBackup") as? Bool ?? true
        let keep = defaults.integer(forKey: "data.keepBackups")
        keepBackups = keep == 0 ? 14 : keep

        do {
            store = try LeadStore(path: defaults.string(forKey: "data.path") ?? Self.defaultDatabasePath)
            reload()
            dailyBackupIfNeeded()
        } catch {
            startupError = "Не удалось открыть базу: \(error.localizedDescription)"
        }
        scheduleAutoSync()
    }

    // MARK: Данные

    func reload() {
        guard let store else { return }
        do {
            leads = try store.allLeads()
            sources = try store.sourceStates()
            pipelineErrors = try store.pipelineErrors()
            exclusions = try store.exclusions()
            syncLog = try store.syncLog()
            selection = selection.intersection(Set(leads.map(\.id)))
        } catch { lastError = error.localizedDescription }
    }

    func count(_ s: NavSection) -> Int {
        leads.filter { matchesSection($0, s) && (s == .excluded || !(filter.hideRejected && $0.data.relevance == .rejected)) }.count
    }

    private func matchesSection(_ l: LeadItem, _ s: NavSection) -> Bool {
        switch s {
        case .all: return !l.archived && !l.excluded
        case .new: return !l.seen && !l.archived && !l.excluded
        case .favorites: return l.favorite && !l.excluded
        case .archive: return l.archived && !l.excluded
        case .excluded: return l.excluded
        default: return false
        }
    }

    var visibleLeads: [LeadItem] {
        let q = filter.search.trimmingCharacters(in: .whitespaces)
        return leads.filter { l in
            guard matchesSection(l, section) else { return false }
            if filter.hideRejected && section != .excluded && l.data.relevance == .rejected { return false }
            if let k = filter.kind, l.data.kind != k { return false }
            if let s = filter.source, l.data.source != s { return false }
            if let r = filter.region, l.data.region != r { return false }
            if l.data.score < filter.minScore { return false }
            if !q.isEmpty {
                let d = l.data
                let hay = [d.title, d.description, d.address ?? "", d.phone ?? "", d.website ?? "", d.region ?? "",
                           d.category ?? "", d.customerName ?? "", l.note] + Array(d.contacts.values)
                if !hay.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return false }
            }
            return true
        }
    }

    var allSources: [String] { Array(Set(leads.map(\.data.source))).sorted() }
    var allRegions: [String] { Array(Set(leads.compactMap(\.data.region))).filter { !$0.isEmpty }.sorted() }

    func lead(_ id: String) -> LeadItem? { leads.first { $0.id == id } }

    var selectedLead: LeadItem? { selection.count == 1 ? selection.first.flatMap(lead) : nil }

    private func act(_ body: (LeadStore) throws -> Void) {
        guard let store else { return }
        do { try body(store); reload() } catch { lastError = error.localizedDescription }
    }

    func toggleFavorite(_ ids: Set<String>) {
        let on = !ids.compactMap(lead).allSatisfy(\.favorite)
        act { try $0.setFavorite(Array(ids), on) }
    }
    func setArchived(_ ids: Set<String>, _ on: Bool) { act { try $0.setArchived(Array(ids), on) } }
    func delete(_ ids: Set<String>) { act { try $0.delete(Array(ids)) }; selection.subtract(ids) }
    func markSeen(_ ids: Set<String>) {
        guard ids.contains(where: { lead($0)?.seen == false }) else { return }
        act { try $0.markSeen(Array(ids)) }
    }
    func markAllSeen() { act { try $0.markAllSeen() } }
    func setNote(_ id: String, _ note: String) { act { try $0.setNote(id, note) } }
    func events(_ id: String) -> [LeadEvent] { (try? store?.events(for: id)) ?? [] }

    func exclude(_ kind: ExclusionKind, _ value: String) {
        act { try $0.addExclusion(kind, value) }
        lastMessage = "Добавлено исключение: \(kind.title.lowercased()) \(value)"
    }
    func removeExclusion(_ id: Int64) { act { try $0.removeExclusion(id) } }

    func importExclusions(from url: URL) {
        guard let store else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = try store.importExclusions(csv: text)
            reload()
            lastMessage = "Из файла добавлено исключений: \(n)"
        } catch { lastError = "Не удалось прочитать файл: \(error.localizedDescription)" }
    }

    // MARK: Синхронизация с GitHub Actions

    private func client() -> GitHubClient? {
        guard githubConfig.isComplete, let token = Keychain.get("github.token"), !token.isEmpty else { return nil }
        return GitHubClient(config: githubConfig, token: token)
    }

    func syncNow(force: Bool = false) async {
        guard !syncing, let store else { return }
        guard let client = client(), let secret = Keychain.get("state.secret"), !secret.isEmpty else {
            lastError = "Синхронизация не настроена: укажите репозиторий, токен GitHub и ключ шифрования в настройках."
            return
        }
        syncing = true
        defer { syncing = false }
        do {
            let outcome = try await StateSync.sync(store: store, client: client, secret: secret, force: force)
            if outcome.skipped {
                lastMessage = "Новых результатов поиска нет"
            } else {
                try store.addSyncLog(ok: true, added: outcome.result.added, updated: outcome.result.updated,
                                     message: "Новых: \(outcome.result.added), обновлено: \(outcome.result.updated)")
                lastMessage = "Синхронизировано: новых \(outcome.result.added), обновлено \(outcome.result.updated)"
            }
            reload()
            await loadRuns()
        } catch {
            try? store.addSyncLog(ok: false, message: error.localizedDescription)
            lastError = error.localizedDescription
            reload()
        }
    }

    func loadRuns() async {
        guard let client = client() else { return }
        do { runs = try await client.runs() } catch { lastError = error.localizedDescription }
    }

    func dispatchSearch(force: Bool = false) async {
        guard let client = client() else {
            lastError = "Укажите репозиторий и токен GitHub в настройках, чтобы запускать поиск."
            return
        }
        dispatching = true
        defer { dispatching = false }
        do {
            try await client.dispatch(force: force)
            lastMessage = "Поиск запущен в GitHub Actions. Результаты появятся после следующей синхронизации."
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await loadRuns()
        } catch { lastError = error.localizedDescription }
    }

    func rerun(_ run: WorkflowRun) async {
        guard let client = client() else { return }
        do {
            try await client.rerunFailed(run.id)
            lastMessage = "Запуск №\(run.runNumber) отправлен на повтор"
            await loadRuns()
        } catch { lastError = error.localizedDescription }
    }

    var lastSyncAt: Date? { ISODate.parse(store?.value("last_sync_at")) }
    var lastStateAt: Date? { ISODate.parse(store?.value("last_state_at")) }

    func scheduleAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        guard autoSyncMinutes > 0 else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(autoSyncMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.syncConfigured else { return }
                await self.syncNow()
            }
        }
    }

    // MARK: Экспорт, резервные копии

    func export(_ items: [LeadItem], format: ExportFormat, fields: [ExportField], to url: URL) {
        do {
            try Exporter.export(items, format: format, fields: fields).write(to: url)
            lastMessage = "Экспортировано лидов: \(items.count)"
        } catch { lastError = "Экспорт не удался: \(error.localizedDescription)" }
    }

    func backups() -> [URL] {
        let dir = URL(fileURLWithPath: backupDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("leadgen-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    @discardableResult
    func backupNow() -> URL? {
        guard let store else { return nil }
        let dir = URL(fileURLWithPath: backupDirectory)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        let url = dir.appendingPathComponent("leadgen-\(f.string(from: Date())).db")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try store.backup(to: url)
            for old in backups().dropFirst(max(keepBackups, 1)) { try? FileManager.default.removeItem(at: old) }
            try store.setValue("last_backup_at", ISODate.now())
            lastMessage = "Резервная копия сохранена"
            return url
        } catch {
            lastError = "Резервная копия не создана: \(error.localizedDescription)"
            return nil
        }
    }

    private func dailyBackupIfNeeded() {
        guard autoBackup, let store else { return }
        let last = ISODate.parse(store.value("last_backup_at")) ?? .distantPast
        if Date().timeIntervalSince(last) > 20 * 3600 { backupNow() }
    }

    func restore(from url: URL) {
        guard let store else { return }
        do {
            try store.restore(from: url)
            reload()
            lastMessage = "База восстановлена из копии. Предыдущая версия сохранена как before-restore.db"
        } catch { lastError = "Восстановление не удалось: \(error.localizedDescription)" }
    }

    func moveDatabase(to dir: URL) {
        guard let store else { return }
        do {
            let path = try store.move(toDirectory: dir)
            defaults.set(path, forKey: "data.path")
            lastMessage = "База перенесена: \(path)"
        } catch { lastError = "Перенос не удался: \(error.localizedDescription)" }
    }

    var databaseSize: Int64 { store?.fileSize ?? 0 }
}
