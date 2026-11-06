import AppKit
import LeadGenCore
import LeadSearch
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
        case .runs: return "Журнал поиска"
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
    let username: String
    private(set) var store: LeadStore?
    var startupError: String?

    var leads: [LeadItem] = []
    var sources: [SourceState] = []
    var pipelineErrors: [PipelineError] = []
    var exclusions: [Exclusion] = []
    var syncLog: [SyncLogEntry] = []

    /// Выделение сбрасывается при смене раздела и фильтров, чтобы массовые действия
    /// не задели лиды, которых пользователь больше не видит.
    var section: NavSection = .all { didSet { if oldValue != section { selection = [] } } }
    var filter = LeadFilter() { didSet { if oldValue != filter { selection = [] } } }
    var selection: Set<String> = []
    var inspectorShown = true
    var selectedSource: String? = SourceKey.rss

    var lastMessage: String?
    var lastError: String?

    // MARK: Поиск

    /// Настройки источников и ключевых слов. Хранятся в базе пользователя.
    var searchSettings = SearchSettings() {
        didSet { if oldValue != searchSettings { try? store?.setValue("search.settings", searchSettings.encoded()) } }
    }
    private(set) var searching = false
    private(set) var searchProgress: String?
    private(set) var lastReport: SearchReport?
    private var searchTask: Task<Void, Never>?
    private var autoTimer: Timer?
    private var searchActivity: NSObjectProtocol?
    private var backupTimer: Timer?

    private let defaults = UserDefaults.standard
    private func key(_ k: String) -> String { "\(k).\(username.lowercased())" }

    var autoSearchMinutes: Int { didSet { defaults.set(autoSearchMinutes, forKey: key("search.auto")); scheduleAutoSearch() } }
    var signature: String { didSet { defaults.set(signature, forKey: key("draft.signature")) } }
    var backupDirectory: String { didSet { defaults.set(backupDirectory, forKey: key("data.backupDir")) } }
    var autoBackup: Bool { didSet { defaults.set(autoBackup, forKey: key("data.autoBackup")) } }
    var keepBackups: Int { didSet { defaults.set(keepBackups, forKey: key("data.keepBackups")) } }

    /// Сервисный ключ VK — в Связке ключей, отдельно для каждого пользователя.
    /// Читается из Связки ключей один раз при входе: представления обращаются к ключу при каждой перерисовке.
    var vkToken: String {
        get { vkTokenValue }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Keychain.set(key("vk.token"), value)
            vkTokenValue = value
        }
    }
    private var vkTokenValue = ""
    var hasVKToken: Bool { !vkTokenValue.isEmpty }

    let defaultDatabasePath: String
    var databasePath: String { store?.path ?? (defaults.string(forKey: key("data.path")) ?? defaultDatabasePath) }

    init(username: String, dataDirectory: URL) {
        self.username = username
        defaultDatabasePath = dataDirectory.appendingPathComponent("leads.db").path
        let interval = defaults.object(forKey: "search.auto.\(username.lowercased())") as? Int
        autoSearchMinutes = interval ?? 60
        signature = defaults.string(forKey: "draft.signature.\(username.lowercased())") ?? ""
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        backupDirectory = defaults.string(forKey: "data.backupDir.\(username.lowercased())")
            ?? docs.appendingPathComponent("Lead Generator Backups").appendingPathComponent(username).path
        autoBackup = defaults.object(forKey: "data.autoBackup.\(username.lowercased())") as? Bool ?? true
        let keep = defaults.integer(forKey: "data.keepBackups.\(username.lowercased())")
        keepBackups = keep == 0 ? 14 : keep
        vkTokenValue = Keychain.get("vk.token.\(username.lowercased())") ?? ""

        do {
            let store = try LeadStore(path: defaults.string(forKey: "data.path.\(username.lowercased())") ?? defaultDatabasePath)
            self.store = store
            searchSettings = SearchSettings.decode(store.value("search.settings"))
            reload()
            dailyBackupIfNeeded()
            // Приложение может работать в фоне днями: проверяем суточную копию каждый час,
            // независимо от того, включён ли автопоиск.
            backupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.dailyBackupIfNeeded() }
            }
        } catch {
            startupError = "Не удалось открыть базу: \(error.localizedDescription)"
        }
        scheduleAutoSearch()
    }

    /// Выход из учётной записи: остановить поиск и таймеры.
    func shutdown() {
        searchTask?.cancel()
        autoTimer?.invalidate()
        autoTimer = nil
        backupTimer?.invalidate()
        backupTimer = nil
        if let activity = searchActivity { ProcessInfo.processInfo.endActivity(activity) }
        searchActivity = nil
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
            let last = ISODate.parse(store.value("last_search_at"))
            if last != lastSearchAt { lastSearchAt = last }
            // Присваиваем только при изменении: любое присваивание заставляет перестраивать
            // главное меню и таблицу, даже если значение то же самое.
            let kept = selection.intersection(Set(leads.map(\.id)))
            if kept != selection { selection = kept }
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

    // MARK: Поиск лидов на этом Mac

    /// Время последнего поиска. Хранится в памяти и обновляется в `reload()`,
    /// чтобы не читать базу и не разбирать дату при каждой перерисовке.
    private(set) var lastSearchAt: Date?

    func problem(_ source: String) -> String? {
        SearchEngine.problem(source, searchSettings, SearchSecrets(vkToken: vkToken))
    }

    /// Запуск поиска. `force` — без учёта интервалов источников; `only` — только эти источники.
    func runSearch(force: Bool = true, only: Set<String>? = nil, quiet: Bool = false) {
        guard !searching else { return }
        // Отдельное соединение с базой: поиск пишет, не мешая интерфейсу.
        let repository: LeadStore
        do { repository = try LeadStore(path: databasePath) } catch {
            lastError = "Поиск не запущен: \(error.localizedDescription)"
            return
        }
        let engine = SearchEngine(settings: searchSettings, secrets: SearchSecrets(vkToken: vkToken),
                                  transport: URLSessionTransport(), repository: repository)
        searching = true
        searchProgress = "Подготовка…"
        // Не даём macOS усыпить поиск (App Nap), когда окно закрыто или свёрнуто.
        searchActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                               reason: "Поиск лидов")
        searchTask = Task { [weak self] in
            let report = await engine.run(SearchOptions(force: force, only: only)) { text in
                Task { @MainActor [weak self] in
                    if self?.searching == true { self?.searchProgress = text }
                }
            }
            repository.db.close()
            guard let self else { return }
            self.searching = false
            if let activity = self.searchActivity { ProcessInfo.processInfo.endActivity(activity) }
            self.searchActivity = nil
            self.searchProgress = nil
            self.searchTask = nil
            self.lastReport = report
            self.reload()
            // При работе в фоне приложение может не перезапускаться днями: копия раз в сутки и после поиска.
            self.dailyBackupIfNeeded()
            if !quiet || report.added > 0 || !report.failed.isEmpty {
                if report.failed.isEmpty { self.lastMessage = report.summary } else { self.lastError = report.summary }
            }
        }
    }

    func stopSearch() {
        searchTask?.cancel()
        searchProgress = "Останавливаю…"
    }

    /// Автопоиск, пока приложение открыто: только источники, у которых подошёл интервал.
    func scheduleAutoSearch() {
        autoTimer?.invalidate()
        autoTimer = nil
        guard autoSearchMinutes > 0 else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(autoSearchMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runSearch(force: false, quiet: true) }
        }
    }

    func resetSourceMemory(_ source: String) {
        act { try $0.resetSourceMemory(source) }
        lastMessage = "Память источника «\(SourceCatalog.title(source))» сброшена"
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
        guard !searching else { lastError = "Дождитесь окончания поиска или остановите его, затем восстановите базу."; return }
        do {
            try store.restore(from: url)
            reload()
            lastMessage = "База восстановлена из копии. Предыдущая версия сохранена как before-restore.db"
        } catch { lastError = "Восстановление не удалось: \(error.localizedDescription)" }
    }

    func moveDatabase(to dir: URL) {
        guard let store else { return }
        guard !searching else { lastError = "Дождитесь окончания поиска или остановите его, затем перенесите базу."; return }
        do {
            let path = try store.move(toDirectory: dir)
            defaults.set(path, forKey: key("data.path"))
            lastMessage = "База перенесена: \(path)"
        } catch { lastError = "Перенос не удался: \(error.localizedDescription)" }
    }

    var databaseSize: Int64 { store?.fileSize ?? 0 }
}
