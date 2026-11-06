import Foundation
import LeadGenCore

/// Куда поиск складывает результаты. Сейчас это локальная база (LeadStore), позже — база на сервере.
public protocol SearchRepository: SearchMemory {
    func sourceCursor(_ source: String) -> String?
    func lastSuccess(_ source: String) -> Date?
    func markAttempt(_ source: String)
    func finishSource(_ source: String, ok: Bool, partial: Bool, error: String?, cursor: String?)
    func save(_ lead: LeadData, id: String, fingerprint: String) throws -> SaveOutcome
    func logError(module: String, message: String)
    func logRun(ok: Bool, added: Int, updated: Int, message: String)
    func searchFinished() throws
}

public struct SearchOptions: Sendable {
    /// Не смотреть на интервалы источников (кнопка «Найти лиды»).
    public var force: Bool
    /// Только эти источники (кнопка «Проверить сейчас» у источника).
    public var only: Set<String>?
    public init(force: Bool = true, only: Set<String>? = nil) { self.force = force; self.only = only }
}

public struct SourceReport: Sendable, Identifiable {
    public var id: String { source }
    public var source: String
    public var found = 0
    public var added = 0
    public var updated = 0
    public var duplicates = 0
    public var skipped: String?
    public var warnings: [String] = []
    public var errors: [String] = []
    public var failed = false
}

public struct SearchReport: Sendable {
    public var sources: [SourceReport] = []
    public var cancelled = false
    public var added: Int { sources.map(\.added).reduce(0, +) }
    public var updated: Int { sources.map(\.updated).reduce(0, +) }
    public var failed: [SourceReport] { sources.filter(\.failed) }

    public var summary: String {
        if cancelled { return "Поиск остановлен. Новых лидов: \(added)" }
        let ran = sources.filter { $0.skipped == nil }
        if ran.isEmpty {
            return sources.first?.skipped.map { "Поиск не выполнен: \($0)" } ?? "Нет включённых источников"
        }
        var s = "Поиск завершён: новых \(added), обновлено \(updated)"
        if !failed.isEmpty { s += ". С ошибками: " + failed.map { SourceCatalog.title($0.source) }.joined(separator: ", ") }
        return s
    }
}

/// Поиск лидов по всем источникам. Не зависит от интерфейса: тот же код можно запускать на сервере.
public final class SearchEngine {
    let settings: SearchSettings
    let secrets: SearchSecrets
    let transport: HTTPTransport
    let repo: SearchRepository
    let scorer: Scorer
    let sleep: Sleeper
    let now: () -> Date

    public init(settings: SearchSettings, secrets: SearchSecrets, transport: HTTPTransport, repository: SearchRepository,
                scorer: Scorer = Scorer(), sleep: @escaping Sleeper = realSleep, now: @escaping () -> Date = Date.init) {
        self.settings = settings; self.secrets = secrets; self.transport = transport; self.repo = repository
        self.scorer = scorer; self.sleep = sleep; self.now = now
    }

    /// Проверка настроек источника: nil — готов, иначе причина.
    public static func problem(_ key: String, _ s: SearchSettings, _ secrets: SearchSecrets) -> String? {
        switch key {
        case SourceKey.rss: return s.rss.feeds.isEmpty ? "не добавлено ни одной ленты" : nil
        case SourceKey.telegram: return s.telegram.channels.isEmpty ? "не добавлено ни одного канала" : nil
        case SourceKey.vk:
            if (secrets.vkToken ?? "").isEmpty { return "нет сервисного ключа VK" }
            return s.vk.communities.isEmpty ? "не добавлено ни одного сообщества" : nil
        case SourceKey.osm:
            if s.osm.regions.isEmpty { return "не добавлено ни одного региона" }
            return s.osm.categories.contains(where: \.enabled) ? nil : "не выбрано ни одной категории"
        default: return "неизвестный источник"
        }
    }

    public func run(_ options: SearchOptions = SearchOptions(), progress: @escaping @Sendable (String) -> Void = { _ in }) async -> SearchReport {
        var report = SearchReport()
        for key in SourceKey.all {
            if let only = options.only, !only.contains(key) { continue }
            var r = SourceReport(source: key)
            guard settings.isEnabled(key) else {
                if options.only != nil { r.skipped = "источник выключен"; report.sources.append(r) }
                continue
            }
            if let p = Self.problem(key, settings, secrets) {
                r.skipped = p
                report.sources.append(r)
                continue
            }
            if !options.force, let last = repo.lastSuccess(key),
               now().timeIntervalSince(last) < settings.intervalHours(key) * 3600 {
                continue  // ещё рано
            }
            if Task.isCancelled { report.cancelled = true; break }
            progress("\(SourceCatalog.title(key)): поиск…")
            repo.markAttempt(key)
            do {
                let fetched = try await fetch(key)
                r.warnings = fetched.warnings
                r.errors = fetched.partialErrors
                r.found = fetched.candidates.count
                progress("\(SourceCatalog.title(key)): оценка \(fetched.candidates.count)")
                for c in fetched.candidates { try store(c, into: &r) }
                let allFailed = !fetched.partialErrors.isEmpty && fetched.partialErrors.count >= fetched.items
                r.failed = allFailed
                for e in fetched.partialErrors { repo.logError(module: key, message: e) }
                for w in fetched.warnings { repo.logError(module: key, message: "Предупреждение: \(w)") }
                repo.finishSource(key, ok: !allFailed, partial: !fetched.partialErrors.isEmpty,
                                  error: fetched.partialErrors.first, cursor: fetched.cursor)
            } catch is CancellationError {
                report.cancelled = true
                report.sources.append(r)
                break
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                r.failed = true
                r.errors.append(msg)
                repo.logError(module: key, message: msg)
                repo.finishSource(key, ok: false, partial: false, error: msg, cursor: nil)
            }
            report.sources.append(r)
        }
        try? repo.searchFinished()
        let ok = report.failed.isEmpty && !report.cancelled
        if report.sources.contains(where: { $0.skipped == nil }) {
            repo.logRun(ok: ok, added: report.added, updated: report.updated, message: report.summary)
        }
        return report
    }

    private func fetch(_ key: String) async throws -> FetchResult {
        let cursor = repo.sourceCursor(key)
        switch key {
        case SourceKey.rss:
            let http = SourceHTTP(name: "FL.ru и RSS", transport: transport, minInterval: 2,
                                  maxRequests: max(5, settings.rss.feeds.count * 2), sleep: sleep)
            return try await RSSSource.fetch(settings.rss, cursor: cursor, http: http)
        case SourceKey.telegram:
            let http = SourceHTTP(name: "Telegram", transport: transport, minInterval: 3,
                                  maxRequests: max(40, settings.telegram.channels.count * settings.telegram.maxPages + 5), sleep: sleep)
            return try await TelegramSource.fetch(settings.telegram, cursor: cursor, http: http)
        case SourceKey.vk:
            let http = SourceHTTP(name: "VK", transport: transport, minInterval: 0.4,
                                  maxRequests: max(40, settings.vk.communities.count * settings.vk.maxPages + 5), sleep: sleep)
            return try await VKSource.fetch(settings.vk, token: secrets.vkToken ?? "", cursor: cursor, http: http)
        case SourceKey.osm:
            let http = SourceHTTP(name: "OpenStreetMap", transport: transport, minInterval: 5, maxRequests: 10,
                                  timeout: 120, sleep: sleep)
            let site = SourceHTTP(name: "Проверка сайтов", transport: transport, minInterval: 1, maxRequests: 40,
                                  maxAttempts: 2, timeout: 12, sleep: sleep)
            return try await OSMSource.fetch(settings.osm, memory: repo, http: http,
                                             siteHTTP: settings.osm.checkWebsites ? site : nil, now: now())
        default:
            return FetchResult()
        }
    }

    private func store(_ c: Candidate, into r: inout SourceReport) throws {
        var data = c.data
        data.discoveredAt = now()
        if data.kind == .organization {
            scorer.scoreOrganization(&data, categoryWeight: c.categoryWeight, signals: c.signals)
        } else {
            scorer.scoreOrder(&data, now: now())
        }
        let id = SearchText.leadId(source: data.source, externalId: data.externalId)
        switch try repo.save(data, id: id, fingerprint: SearchText.fingerprint(data)) {
        case .added: r.added += 1
        case .updated: r.updated += 1
        case .duplicate: r.duplicates += 1
        case .unchanged: break
        }
    }
}

extension LeadStore: SearchRepository {}

extension LeadData: LeadDataLike {
    public var isOrganization: Bool { kind == .organization }
}
