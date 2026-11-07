import AppKit
import LeadGenCore
import Observation

/// Отчёты о вылетах, зависаниях и ошибках.
///
/// Ничего не отправляется само: приложение собирает текст, показывает его, и по кнопке
/// открывает в браузере новое обращение в Issues репозитория с этим текстом. Отправляет его
/// сам пользователь со своей учётной записью GitHub, поэтому в приложении нет ни ключей, ни сервера.
@MainActor
@Observable
final class ReportController {
    static let shared = ReportController()

    enum Key {
        static let offerAfterCrash = "reports.offerAfterCrash"
        static let logErrors = "reports.logErrors"
        static let includeLog = "reports.includeLog"
        static let lastSeen = "reports.lastSeen"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    private(set) var crashes: [CrashFile] = []

    private func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }

    var offerAfterCrash: Bool {
        get { access(keyPath: \.offerAfterCrash); return flag(Key.offerAfterCrash) }
        set { withMutation(keyPath: \.offerAfterCrash) { defaults.set(newValue, forKey: Key.offerAfterCrash) } }
    }
    var logErrors: Bool {
        get { access(keyPath: \.logErrors); return flag(Key.logErrors) }
        set { withMutation(keyPath: \.logErrors) { defaults.set(newValue, forKey: Key.logErrors) } }
    }
    var includeLog: Bool {
        get { access(keyPath: \.includeLog); return flag(Key.includeLog) }
        set { withMutation(keyPath: \.includeLog) { defaults.set(newValue, forKey: Key.includeLog) } }
    }

    private init() {}

    /// Записать ошибку в журнал, если журнал включён.
    nonisolated static func log(_ message: String) {
        guard UserDefaults.standard.object(forKey: Key.logErrors) as? Bool ?? true else { return }
        ErrorLog.append(message)
    }

    func refresh() { crashes = CrashReports.find() }

    /// При запуске: если с прошлого раза появился отчёт о вылете, предложить его отправить.
    func checkAfterLaunch() {
        refresh()
        // Первый запуск с этой функцией: смотрим отчёты за последнюю неделю.
        let lastSeen = defaults.object(forKey: Key.lastSeen) as? Date ?? Date().addingTimeInterval(-7 * 86400)
        guard let newest = crashes.first else { return }
        defaults.set(newest.date, forKey: Key.lastSeen)
        guard offerAfterCrash, newest.date > lastSeen else { return }

        let a = NSAlert()
        a.messageText = "Customers в прошлый раз завершился аварийно"
        a.informativeText = "macOS сохранила отчёт: \(newest.kind.lowercased()), \(newest.date.fullRu). Можно отправить его разработчику, чтобы ошибку исправили. Перед отправкой вы увидите весь текст."
        a.addButton(withTitle: "Посмотреть и отправить…")
        a.addButton(withTitle: "Не сейчас")
        a.addButton(withTitle: "Больше не предлагать")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: compose(crash: newest)
        case .alertThirdButtonReturn: offerAfterCrash = false
        default: break
        }
    }

    /// Текст отчёта: что за сборка, сводка сбоя и последние ошибки из журнала.
    func reportText(crash: CrashFile?) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var arch = "?"
        #if arch(arm64)
        arch = "Apple Silicon"
        #elseif arch(x86_64)
        arch = "Intel"
        #endif
        var out = """
        ### Что случилось
        <!-- Опишите, что вы делали перед сбоем. -->


        ### Сборка
        - Customers \(version) (\(build))
        - \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch)
        """
        if let crash, let text = try? String(contentsOf: crash.url, encoding: .utf8) {
            out += "\n\n### \(crash.kind): \(crash.url.lastPathComponent)\n```\n\(CrashReports.summary(of: text))\n```"
        }
        if includeLog {
            let lines = ErrorLog.recent(40)
            if !lines.isEmpty { out += "\n\n### Последние ошибки\n```\n\(lines.joined(separator: "\n"))\n```" }
        }
        return CrashReports.redact(out)
    }

    /// Показать текст отчёта с возможностью правки и отправить через браузер.
    func compose(crash: CrashFile?) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        text.string = reportText(crash: crash)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = true
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text

        let a = NSAlert()
        a.messageText = crash == nil ? "Сообщить о проблеме" : "Отчёт о сбое"
        a.informativeText = "Проверьте текст: домашняя папка и имя пользователя уже скрыты. Контакты лидов в отчёт не попадают. «Открыть в GitHub» откроет новое обращение в браузере, отправите его вы сами (нужна бесплатная учётная запись GitHub)."
        a.accessoryView = scroll
        a.addButton(withTitle: "Открыть в GitHub")
        a.addButton(withTitle: "Скопировать")
        a.addButton(withTitle: "Отмена")
        if crash != nil { a.addButton(withTitle: "Показать файл") }
        NSApp.activate(ignoringOtherApps: true)
        let response = a.runModal()
        let body = text.string
        switch response {
        case .alertFirstButtonReturn:
            copy(body)
            let title = crash.map { "\($0.kind) Customers \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")" }
                ?? "Проблема в Customers"
            NSWorkspace.shared.open(CrashReports.issueURL(title: title, body: body))
        case .alertSecondButtonReturn:
            copy(body)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            if let crash { NSWorkspace.shared.activateFileViewerSelecting([crash.url]) }
        default: break
        }
    }

    func showLog() {
        if FileManager.default.fileExists(atPath: ErrorLog.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([ErrorLog.url])
        } else {
            NSWorkspace.shared.open(ErrorLog.url.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
