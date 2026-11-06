import Foundation

/// Журнал ошибок приложения: последние сообщения об ошибках, по строке на сообщение.
/// Лежит в ~/Library/Logs/LeadGenerator/errors.log и никуда не отправляется сам.
public enum ErrorLog {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LeadGenerator", isDirectory: true)
            .appendingPathComponent("errors.log")
    }

    /// Добавляет строку и оставляет только последние `keep` строк.
    public static func append(_ message: String, at date: Date = Date(), to url: URL = ErrorLog.url, keep: Int = 300) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: date))  \(message.replacingOccurrences(of: "\n", with: " "))"
        var lines = recent(keep - 1, from: url)
        lines.append(line)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Последние `count` строк журнала, старые сначала.
    public static func recent(_ count: Int, from url: URL = ErrorLog.url) -> [String] {
        guard count > 0, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").map(String.init).suffix(count))
    }

    public static func clear(_ url: URL = ErrorLog.url) { try? FileManager.default.removeItem(at: url) }
}

/// Отчёт о сбое, который macOS сохранила в ~/Library/Logs/DiagnosticReports.
public struct CrashFile: Hashable, Sendable {
    public let url: URL
    public let date: Date
    public var kind: String {
        switch url.pathExtension.lowercased() {
        case "hang", "spin": return "Зависание"
        case "diag": return "Сбой ресурсов"
        default: return "Вылет"
        }
    }
}

public enum CrashReports {
    public static var directories: [URL] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        return [logs, logs.appendingPathComponent("Retired")]
    }

    static let extensions: Set<String> = ["ips", "crash", "hang", "spin", "diag"]

    /// Отчёт относится к этому приложению: macOS называет файлы по имени процесса.
    public static func isOurs(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard extensions.contains(ext) else { return false }
        return fileName.hasPrefix("LeadGenerator") || fileName.hasPrefix("Lead Generator")
    }

    /// Отчёты этого приложения, новые сначала.
    public static func find(in directories: [URL] = CrashReports.directories, newerThan: Date? = nil) -> [CrashFile] {
        let fm = FileManager.default
        var found: [CrashFile] = []
        for dir in directories {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where isOurs(f.lastPathComponent) {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let newerThan, date <= newerThan { continue }
                found.append(CrashFile(url: f, date: date))
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    /// Убирает из текста домашнюю папку и имя пользователя Mac.
    public static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var s = text.replacingOccurrences(of: home, with: "~")
        if user.count >= 3 { s = s.replacingOccurrences(of: user, with: "<user>") }
        return s
    }

    /// Главное из отчёта: тип исключения и стек упавшего потока.
    /// Отчёт .ips — строка-заголовок JSON и тело JSON; если разобрать не вышло, берётся начало текста.
    public static func summary(of text: String, frames: Int = 30, fallbackLimit: Int = 4000) -> String {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any]
        else { return String(text.prefix(fallbackLimit)) }

        var out: [String] = []
        if let v = header["app_version"] as? String { out.append("Версия: \(v)") }
        if let os = header["os_version"] as? String { out.append("macOS: \(os)") }
        if let t = header["timestamp"] as? String { out.append("Время: \(t)") }
        if let e = body["exception"] as? [String: Any] {
            let fields = ["type", "signal", "codes", "subtype"].compactMap { e[$0] as? String }
            out.append("Исключение: \(fields.joined(separator: ", "))")
        }
        if let t = body["termination"] as? [String: Any], let ind = t["indicator"] as? String {
            out.append("Завершение: \(ind)")
        }
        if let asi = body["asi"] as? [String: [String]] {
            for (lib, msgs) in asi { out.append("\(lib): \(msgs.joined(separator: " "))") }
        }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        if let threads = body["threads"] as? [[String: Any]] {
            let faulting = body["faultingThread"] as? Int ?? threads.firstIndex(where: { ($0["triggered"] as? Bool) == true }) ?? 0
            if faulting < threads.count, let fs = threads[faulting]["frames"] as? [[String: Any]] {
                out.append("")
                out.append("Поток \(faulting):")
                for (i, f) in fs.prefix(frames).enumerated() {
                    let idx = f["imageIndex"] as? Int ?? -1
                    let image = idx >= 0 && idx < images.count ? (images[idx]["name"] as? String ?? "?") : "?"
                    let symbol = f["symbol"] as? String ?? String(format: "+0x%llx", (f["imageOffset"] as? Int) ?? 0)
                    out.append("\(i)  \(image)  \(symbol)")
                }
            }
        }
        return out.isEmpty ? String(text.prefix(fallbackLimit)) : out.joined(separator: "\n")
    }

    /// Ссылка на новое обращение (Issue) в репозитории с готовым текстом.
    /// GitHub не принимает очень длинные адреса, поэтому текст в ссылке обрезается.
    public static func issueURL(repository: String = Updates.repository, title: String, body: String,
                                maxBody: Int = 6000) -> URL {
        var text = body
        if text.count > maxBody {
            text = String(text.prefix(maxBody)) + "\n\n…(текст обрезан: полный отчёт скопирован в буфер обмена, вставьте его ниже)"
        }
        var c = URLComponents(string: "https://github.com/\(repository)/issues/new")!
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: text)]
        // «+» в адресе читается как пробел, а в именах функций он встречается.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}
