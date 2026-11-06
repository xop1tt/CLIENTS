import Foundation
import LeadGenCore

/// Найденный, но ещё не оценённый лид.
public struct Candidate: Sendable {
    public var data: LeadData
    /// Для организаций: проверенные сигналы и вес категории.
    public var signals: [String: Bool] = [:]
    public var categoryWeight: Double?
}

/// Итог опроса одного источника.
public struct FetchResult: Sendable {
    public var candidates: [Candidate] = []
    public var cursor: String?
    public var warnings: [String] = []
    /// Ошибки отдельных лент, каналов и сообществ.
    public var partialErrors: [String] = []
    /// Сколько независимых подзапросов было (чтобы отличить частичный сбой от полного).
    public var items = 1
}

/// Хранилище служебного состояния поиска (история запросов OSM, проверенные объекты).
public protocol SearchMemory: AnyObject {
    func queryLastRun(_ hash: String) -> Date?
    func recordQuery(_ hash: String, source: String, label: String, results: Int)
    func forgetQuery(_ hash: String)
    func objectCheckedAt(source: String, objectId: String) -> Date?
    func markObjectChecked(source: String, objectId: String)
}

private func encodeCursor<T: Encodable>(_ v: T) -> String? {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) }
}

private func decodeCursor<T: Decodable>(_ s: String?, _ type: T.Type) -> T? {
    guard let s, let d = s.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: d)
}

// MARK: - RSS

public struct FeedCursor: Codable, Equatable, Sendable {
    public var etag: String?
    public var lastModified: String?
    public var seen: [String] = []
}

public enum RSSSource {
    static let maxSeen = 500

    public static func fetch(_ cfg: FeedSourceSettings, cursor raw: String?, http: SourceHTTP) async throws -> FetchResult {
        var res = FetchResult()
        var cursors = decodeCursor(raw, [String: FeedCursor].self) ?? [:]
        res.items = max(1, cfg.feeds.count)
        for feed in cfg.feeds {
            try Task.checkCancellation()
            guard let url = URL(string: feed) else { res.partialErrors.append("\(feed): некорректный адрес"); continue }
            var fc = cursors[feed] ?? FeedCursor()
            var headers: [String: String] = [:]
            if let e = fc.etag { headers["If-None-Match"] = e }
            if let m = fc.lastModified { headers["If-Modified-Since"] = m }
            let resp: HTTPResponse
            do { resp = try await http.get(url, headers: headers) }
            catch let e as HTTPError { res.partialErrors.append("\(feed): \(e.message)"); continue }
            if resp.status == 304 { continue }
            guard let entries = FeedParser.parse(resp.data) else {
                res.partialErrors.append("\(feed): не удалось разобрать ленту")
                continue
            }
            let seen = Set(fc.seen)
            var newIds: [String] = []
            for e in entries {
                guard !e.id.isEmpty, !seen.contains(e.id) else { continue }
                newIds.append(e.id)
                let title = String(SearchText.htmlToText(e.title).prefix(300))
                let desc = SearchText.htmlToText(e.summary)
                guard SearchText.prefilter("\(title) \(desc)", cfg.keywords) else { continue }
                res.candidates.append(Candidate(data: LeadData(
                    kind: .order, source: SourceKey.rss, externalId: e.id, title: title, url: e.link,
                    description: String(desc.prefix(4000)), publishedAt: e.published,
                    contacts: SearchText.contacts(desc), category: e.category)))
            }
            // Ни одной уже виденной записи: лента короче пропущенного периода.
            if !seen.isEmpty, !entries.isEmpty, seen.isDisjoint(with: entries.map(\.id)) {
                res.warnings.append("\(feed): лента короче пропущенного периода, часть заявок могла не попасть")
            }
            fc.seen = Array((newIds + fc.seen.filter { !newIds.contains($0) }).prefix(maxSeen))
            fc.etag = resp.headers["etag"]
            fc.lastModified = resp.headers["last-modified"]
            cursors[feed] = fc
        }
        res.cursor = encodeCursor(cursors)
        return res
    }
}

// MARK: - Telegram

public struct TelegramPost: Equatable, Sendable {
    public var channel: String
    public var id: Int
    public var text: String
    public var published: Date?
    public var url: String { "https://t.me/\(channel)/\(id)" }
}

public enum TelegramSource {
    static let postRx = Rx(#"data-post="([^"/]+)/(\d+)""#)
    // Сначала основной текст (js-message_text): у ответов выше идёт цитата с похожим классом.
    static let mainTextRx = Rx(#"<div class="tgme_widget_message_text js-message_text[^"]*"[^>]*>(.*?)</div>"#, [.dotMatchesLineSeparators])
    static let textRx = Rx(#"<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>"#, [.dotMatchesLineSeparators])
    static let timeRx = Rx(#"<time[^>]*datetime="([^"]+)""#)

    /// Разбор страницы https://t.me/s/<канал>.
    public static func parse(_ html: String) -> [TelegramPost] {
        let ns = html as NSString
        let marks = postRx.re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var posts: [TelegramPost] = []
        for (i, m) in marks.enumerated() {
            let end = i + 1 < marks.count ? marks[i + 1].range.location : ns.length
            let chunk = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
            let channel = ns.substring(with: m.range(at: 1))
            guard let id = Int(ns.substring(with: m.range(at: 2))) else { continue }
            let text = (mainTextRx.first(chunk) ?? textRx.first(chunk))?[1].map { SearchText.htmlToText($0, lines: true) } ?? ""
            let published = timeRx.first(chunk)?[1].flatMap { ISODate.parse($0) }
            posts.append(TelegramPost(channel: channel, id: id, text: text, published: published))
        }
        return posts
    }

    public static func fetch(_ cfg: TelegramSourceSettings, cursor raw: String?, http: SourceHTTP) async throws -> FetchResult {
        var res = FetchResult()
        var cursors = decodeCursor(raw, [String: Int].self) ?? [:]
        res.items = max(1, cfg.channels.count)
        for channel in cfg.channels {
            try Task.checkCancellation()
            let lastId = cursors[channel] ?? 0
            var newest = lastId
            var before: Int?
            var reached = lastId == 0  // первый запуск: только первая страница
            for page in 0..<max(1, cfg.maxPages) {
                let s = "https://t.me/s/\(channel)" + (before.map { "?before=\($0)" } ?? "")
                guard let url = URL(string: s) else { break }
                let resp: HTTPResponse
                do { resp = try await http.get(url) }
                catch let e as HTTPError { res.partialErrors.append("\(channel): \(e.message)"); break }
                let posts = parse(resp.text)
                if posts.isEmpty {
                    if page == 0 { res.partialErrors.append("\(channel): нет публичного превью или канал не найден") }
                    break
                }
                for p in posts {
                    if p.id <= lastId { reached = true; continue }
                    newest = max(newest, p.id)
                    guard !p.text.isEmpty, SearchText.prefilter(p.text, cfg.keywords) else { continue }
                    let firstLine = String((p.text.split(separator: "\n").first.map(String.init) ?? p.text).prefix(200))
                    res.candidates.append(Candidate(data: LeadData(
                        kind: .order, source: SourceKey.telegram, externalId: "\(channel)/\(p.id)", title: firstLine,
                        url: p.url, description: String(p.text.prefix(4000)), publishedAt: p.published,
                        contacts: SearchText.contacts(p.text))))
                }
                let minId = posts.map(\.id).min() ?? 0
                if reached || minId <= lastId + 1 { reached = true; break }
                before = minId
            }
            if !reached {
                res.warnings.append("\(channel): за \(cfg.maxPages) стр. не дошли до последнего обработанного поста — возможен пропуск")
            }
            cursors[channel] = newest
        }
        res.cursor = encodeCursor(cursors)
        return res
    }
}

// MARK: - ВКонтакте

public enum VKSource {
    static let api = "https://api.vk.com/method/wall.get"
    static let version = "5.199"

    public static func fetch(_ cfg: VKSourceSettings, token: String, cursor raw: String?, http: SourceHTTP) async throws -> FetchResult {
        var res = FetchResult()
        var cursors = decodeCursor(raw, [String: Int].self) ?? [:]
        res.items = max(1, cfg.communities.count)
        for domain in cfg.communities {
            try Task.checkCancellation()
            let lastId = cursors[domain] ?? 0
            var newest = lastId
            var reached = lastId == 0
            pages: for page in 0..<max(1, cfg.maxPages) {
                var comps = URLComponents(string: api)!
                comps.queryItems = [
                    URLQueryItem(name: "domain", value: domain), URLQueryItem(name: "count", value: "\(cfg.pageSize)"),
                    URLQueryItem(name: "offset", value: "\(page * cfg.pageSize)"),
                    URLQueryItem(name: "access_token", value: token), URLQueryItem(name: "v", value: version),
                ]
                let json: [String: Any]
                do {
                    let resp = try await http.get(comps.url!)
                    guard let obj = try JSONSerialization.jsonObject(with: resp.data) as? [String: Any] else {
                        throw HTTPError(message: "неожиданный ответ VK")
                    }
                    json = obj
                } catch let e as HTTPError { res.partialErrors.append("\(domain): \(e.message)"); break }
                catch let e as BudgetExceeded { throw e }
                catch is CancellationError { throw CancellationError() }
                catch { res.partialErrors.append("\(domain): ответ VK не разобран"); break }
                if let err = json["error"] as? [String: Any] {
                    res.partialErrors.append("\(domain): VK API \(err["error_code"] ?? "?"): \(err["error_msg"] ?? "")")
                    break
                }
                let response = json["response"] as? [String: Any] ?? [:]
                let items = response["items"] as? [[String: Any]] ?? []
                if items.isEmpty { break }
                for it in items {
                    guard let pid = (it["id"] as? NSNumber)?.intValue else { continue }
                    if pid <= lastId {
                        if (it["is_pinned"] as? NSNumber)?.boolValue != true { reached = true }
                        continue
                    }
                    newest = max(newest, pid)
                    let text = it["text"] as? String ?? ""
                    guard !text.isEmpty, SearchText.prefilter(text, cfg.keywords) else { continue }
                    let owner = (it["owner_id"] as? NSNumber)?.intValue ?? 0
                    let date = (it["date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    res.candidates.append(Candidate(data: LeadData(
                        kind: .order, source: SourceKey.vk, externalId: "\(owner)_\(pid)",
                        title: String((text.split(separator: "\n").first.map(String.init) ?? text).prefix(200)),
                        url: "https://vk.com/wall\(owner)_\(pid)", description: String(text.prefix(4000)),
                        publishedAt: date, contacts: SearchText.contacts(text))))
                }
                let count = (response["count"] as? NSNumber)?.intValue ?? 0
                if reached || cfg.pageSize * (page + 1) >= count { reached = true; break pages }
            }
            if !reached { res.warnings.append("\(domain): возможен пропуск постов (увеличьте число страниц)") }
            cursors[domain] = newest
        }
        res.cursor = encodeCursor(cursors)
        return res
    }
}

// MARK: - OpenStreetMap

public enum OSMSource {
    static let needsBooking: Set<String> = ["beauty", "dance", "fitness", "medical", "education", "restaurant"]

    /// Запрос Overpass: город ищется по name, name:ru и name:en (Ереван в OSM — «Երևան»).
    public static func buildQuery(region: String, filters: [String], timeout: Int = 90) -> String {
        let name = region.replacingOccurrences(of: "\"", with: "")
        let body = filters.map { "nwr\($0)(area.a);" }.joined()
        let alt = ["name", "name:ru", "name:en"].enumerated()
            .map { i, k in "area[\"\(k)\"=\"\(name)\"][\"boundary\"=\"administrative\"]->.a\(i);" }.joined()
        return "[out:json][timeout:\(timeout)];\(alt)(.a0;.a1;.a2;)->.a;(\(body));out center tags;"
    }

    public static func fetch(_ cfg: OSMSourceSettings, memory: SearchMemory, http: SourceHTTP, siteHTTP: SourceHTTP?,
                             now: Date = Date()) async throws -> FetchResult {
        var res = FetchResult()
        let cats = cfg.categories.filter { $0.enabled && !$0.filters.isEmpty }
        res.items = max(1, cfg.regions.count * cats.count)
        guard let endpoint = URL(string: cfg.endpoint) else {
            res.partialErrors.append("некорректный адрес Overpass API")
            return res
        }
        var added = 0
        var siteCache: [String: SiteCheck] = [:]
        for region in cfg.regions {
            for cat in cats {
                try Task.checkCancellation()
                let query = buildQuery(region: region, filters: cat.filters)
                let qhash = SearchText.shortHash(query)
                if let last = memory.queryLastRun(qhash), now.timeIntervalSince(last) < cfg.refreshDays * 86400 {
                    continue  // этот запрос недавно выполнялся — не тратим квоту
                }
                let elements: [[String: Any]]
                do {
                    let resp = try await http.postForm(endpoint, ["data": query])
                    guard let obj = try JSONSerialization.jsonObject(with: resp.data) as? [String: Any] else {
                        throw HTTPError(message: "неожиданный ответ Overpass")
                    }
                    elements = obj["elements"] as? [[String: Any]] ?? []
                } catch let e as BudgetExceeded {
                    res.warnings.append(e.message)
                    return res
                } catch let e as HTTPError {
                    res.partialErrors.append("\(region)/\(cat.label): \(e.message)")
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    res.partialErrors.append("\(region)/\(cat.label): ответ не разобран")
                    continue
                }
                memory.recordQuery(qhash, source: SourceKey.osm, label: "\(region)|\(cat.key)", results: elements.count)
                for el in elements {
                    if added >= cfg.maxNewPerRun {
                        res.warnings.append("достигнут лимит \(cfg.maxNewPerRun) новых организаций за запуск, остальные — в следующий раз")
                        // Запрос обработан частично: забываем его, чтобы дочитать в следующий раз.
                        memory.forgetQuery(qhash)
                        return res
                    }
                    if let c = try await candidate(el, cat: cat, region: region, cfg: cfg, memory: memory,
                                                   siteHTTP: siteHTTP, cache: &siteCache, now: now) {
                        res.candidates.append(c)
                        added += 1
                    }
                }
            }
        }
        return res
    }

    static func candidate(_ el: [String: Any], cat: OSMCategory, region: String, cfg: OSMSourceSettings,
                          memory: SearchMemory, siteHTTP: SourceHTTP?, cache: inout [String: SiteCheck],
                          now: Date) async throws -> Candidate? {
        let tags = el["tags"] as? [String: String] ?? [:]
        guard let name = tags["name"], !name.isEmpty else { return nil }
        let oid = "\(el["type"] as? String ?? "node")/\((el["id"] as? NSNumber)?.int64Value ?? 0)"
        if let checked = memory.objectCheckedAt(source: SourceKey.osm, objectId: oid),
           now.timeIntervalSince(checked) < cfg.recheckDays * 86400 {
            return nil  // уже обработан, перепроверять рано
        }
        let website = tags["website"] ?? tags["contact:website"] ?? tags["url"]
        let phone = tags["phone"] ?? tags["contact:phone"]
        var contacts: [String: String] = [:]
        for (k, v) in [("phone", phone), ("email", tags["email"] ?? tags["contact:email"]),
                       ("vk", tags["contact:vk"]), ("telegram", tags["contact:telegram"])] {
            if let v, !v.isEmpty { contacts[k] = v }
        }
        var signals: [String: Bool] = [:]
        var facts = ["Данные © участники OpenStreetMap (ODbL)"]
        var assumptions: [String] = []
        if website == nil || website!.isEmpty {
            signals["no_website"] = true
            facts.append("В OpenStreetMap у организации не указан сайт (сам сайт при этом может существовать)")
            if needsBooking.contains(cat.group) { assumptions.append("Возможно, пригодится сайт с онлайн-записью") }
        } else if cfg.checkWebsites, let siteHTTP, let website {
            let key = Normalize.domain(website)
            var chk = cache[key]
            if chk == nil {
                do {
                    chk = try await SiteChecker.check(website, http: siteHTTP, now: now)
                    cache[key] = chk
                } catch is BudgetExceeded {
                    assumptions.append("Сайт не проверен: исчерпан лимит проверок на этот запуск")
                }
            }
            if let chk {
                facts.append(contentsOf: chk.facts)
                signals["site_unreachable"] = !chk.reachable
                if chk.reachable {
                    signals["no_https"] = !chk.https
                    signals["no_viewport"] = !chk.viewport
                    let year = Calendar(identifier: .gregorian).component(.year, from: now)
                    if let y = chk.copyrightYear, y <= year - 4 { signals["outdated"] = true }
                    if !chk.hasBooking && needsBooking.contains(cat.group) {
                        signals["no_booking"] = true
                        assumptions.append("Возможно, нужна онлайн-запись (на сайте её признаков не найдено)")
                    }
                }
            }
        }
        memory.markObjectChecked(source: SourceKey.osm, objectId: oid)
        let address = [tags["addr:city"], tags["addr:street"], tags["addr:housenumber"]]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let data = LeadData(
            kind: .organization, source: SourceKey.osm, externalId: oid, title: name,
            url: "https://www.openstreetmap.org/\(oid)", description: "\(cat.label) · \(region)",
            region: region, contacts: contacts, category: cat.label, customerName: name,
            address: address.isEmpty ? nil : address, phone: phone, website: website,
            facts: facts, assumptions: assumptions)
        return Candidate(data: data, signals: signals, categoryWeight: cat.weight)
    }
}

// MARK: - Проверка сайта

public struct SiteCheck: Sendable {
    public var url: String
    public var reachable: Bool
    public var status: Int?
    public var https = false
    public var viewport = false
    public var copyrightYear: Int?
    public var hasBooking = false
    public var facts: [String] = []
}

/// Один запрос к главной странице. Возвращает только проверенные факты.
public enum SiteChecker {
    static let bookingMarkers = ["онлайн-запис", "онлайн запис", "записаться", "запись онлайн", "yclients", "dikidi",
                                 "sonline", "booking", "забронировать", "бронирование", "arnica", "altegio"]
    static let yearRx = Rx(#"(?:©|&copy;|copyright)\s*(?:\d{4}\s*[-–—]\s*)?(20\d{2}|19\d{2})"#, [.caseInsensitive])
    static let viewportRx = Rx(#"<meta\b[^>]*\bname\s*=\s*["']?viewport\b"#, [.caseInsensitive])
    static let privateRx = Rx(#"^(127|10|192\.168|169\.254|0)\."#)
    static let private172Rx = Rx(#"^172\.(1[6-9]|2\d|3[01])\."#)

    public static func normalizeURL(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = s.lowercased()
        return low.hasPrefix("http://") || low.hasPrefix("https://") ? s : "http://" + s
    }

    /// Только http(s) и не локальные адреса.
    public static func isPublicHTTPURL(_ s: String) -> Bool {
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
              ["http", "https"].contains(scheme), !host.isEmpty, host.contains(".") else { return false }
        if host == "localhost" || host.hasSuffix(".local") || privateRx.matches(host) || private172Rx.matches(host) { return false }
        return true
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    public static func check(_ raw: String, http: SourceHTTP, now: Date) async throws -> SiteCheck {
        let urlString = normalizeURL(raw)
        let day = dateFormatter.string(from: now)
        guard isPublicHTTPURL(urlString), let url = URL(string: urlString) else {
            return SiteCheck(url: urlString, reachable: false, facts: ["В источнике указан некорректный адрес сайта"])
        }
        let resp: HTTPResponse
        do { resp = try await http.get(url) }
        catch let e as HTTPError {
            return SiteCheck(url: urlString, reachable: false, status: e.status,
                             facts: ["Сайт не открылся при проверке \(day): \(e.message)"])
        }
        let final = resp.url?.absoluteString ?? urlString
        let html = String(resp.text.prefix(500_000))
        var chk = SiteCheck(url: final, reachable: true, status: resp.status,
                            https: final.lowercased().hasPrefix("https://"), viewport: viewportRx.matches(html))
        chk.copyrightYear = yearRx.all(html).compactMap { $0[1].flatMap { Int($0) } }.max()
        let low = html.lowercased()
        chk.hasBooking = bookingMarkers.contains { low.contains($0) }
        chk.facts.append("Сайт открылся (\(resp.status)) при проверке \(day)")
        if !chk.https { chk.facts.append("Сайт работает без HTTPS") }
        if !chk.viewport { chk.facts.append("На главной нет meta viewport — мобильная вёрстка вероятно не адаптивна") }
        if let y = chk.copyrightYear { chk.facts.append("Последний год в копирайте: \(y)") }
        if !chk.hasBooking { chk.facts.append("На главной не найдено признаков онлайн-записи/бронирования") }
        return chk
    }
}
