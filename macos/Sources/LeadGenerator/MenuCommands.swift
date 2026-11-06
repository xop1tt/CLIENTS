import AppKit
import LeadGenCore
import SwiftUI
import UniformTypeIdentifiers

/// Действия, которые верхнее меню берёт из окна (SwiftUI отдаёт их только представлениям).
@MainActor
enum MenuActions {
    static var openSettingsAction: (() -> Void)?

    /// Открыть настройки на разделе.
    static func openSettings(_ section: SettingsSection? = nil) {
        if let section { UserDefaults.standard.set(section.rawValue, forKey: "settings.section") }
        openSettingsAction?()
    }

    /// Показать главное окно (если оно закрыто, а приложение работает в фоне).
    static func showMainWindow() {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { StatusItemController.openMainWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func restore(_ model: AppModel) {
        let p = NSOpenPanel()
        p.message = "Выберите резервную копию базы (.db). Текущие лиды будут заменены её содержимым."
        p.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        if p.runModal() == .OK, let url = p.url { model.restore(from: url) }
    }

    static var releaseNotesPage: URL {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let v, AppVersion(v) != nil else { return Updates.releasesPage }
        return Updates.releasesPage.appendingPathComponent("tag").appendingPathComponent("v\(v)")
    }
}

/// Верхнее меню macOS.
///
/// Команды не читают часто меняющееся состояние (выделение, ход поиска, прогресс синхронизации):
/// иначе SwiftUI перестраивает главное меню на каждое изменение, и при частых обновлениях
/// приложение зависало (1.0.3). Доступность зависит только от того, выполнен ли вход;
/// остальное действия проверяют сами в момент нажатия.
struct AppCommands: Commands {
    let session: SessionModel
    let look: AppearanceSettings

    private var model: AppModel? { session.current }

    /// Выполнить действие с выбранными лидами. Без выделения — ничего не делать.
    private func withSelection(_ body: (AppModel, Set<String>) -> Void) {
        guard let m = session.current, !m.selection.isEmpty else { NSSound.beep(); return }
        body(m, m.selection)
    }

    var body: some Commands {
        // MARK: Lead Generator
        CommandGroup(after: .appInfo) {
            Button("Проверить обновления…") { UpdateController.shared.check(manual: true) }
        }
        CommandGroup(after: .appSettings) {
            Button("Учётная запись…") { MenuActions.openSettings(.account) }
                .disabled(model == nil)
            Button("Синхронизировать сейчас") { session.sync?.syncNow() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Выйти из учётной записи") { session.logout() }
                .disabled(model == nil)
        }

        // MARK: Файл
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .importExport) {
            Menu("Экспорт в") {
                ForEach(ExportTab.allCases) { t in
                    Button(t.menuTitle) { MenuActions.showMainWindow(); model?.openExport(t) }
                }
            }
            .disabled(model == nil)
            Button("Экспорт в…") { MenuActions.showMainWindow(); model?.openExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
            Divider()
            Button("Создать резервную копию") { model?.backupNow() }
                .disabled(model == nil)
            Button("Восстановить из резервной копии…") { if let m = model { MenuActions.restore(m) } }
                .disabled(model == nil)
            Button("Показать резервные копии в Finder") {
                if let m = model {
                    let dir = URL(fileURLWithPath: m.backupDirectory)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
            }
            .disabled(model == nil)
        }

        // MARK: Поиск
        CommandMenu("Поиск") {
            Button("Найти лиды") { model?.runSearch() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model == nil)
            Button("Остановить поиск") { model?.stopSearch() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Источники") { MenuActions.showMainWindow(); model?.section = .sources }
                .disabled(model == nil)
            Button("Журнал поиска") { MenuActions.showMainWindow(); model?.section = .runs }
                .disabled(model == nil)
            Divider()
            Button("Настройки поиска…") { MenuActions.openSettings(.search) }
                .disabled(model == nil)
            Button("Исключения…") { MenuActions.openSettings(.exclusions) }
                .disabled(model == nil)
        }

        // MARK: Лиды
        CommandMenu("Лиды") {
            Button("Открыть оригинал") {
                withSelection { m, ids in
                    for id in ids.prefix(10) {
                        if let url = m.lead(id).flatMap({ URL(string: $0.data.url) }), url.scheme?.hasPrefix("http") == true {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model == nil)
            Button("Скопировать ссылку") {
                withSelection { m, ids in
                    let links = ids.compactMap { m.lead($0)?.data.url }.filter { !$0.isEmpty }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model == nil)
            Divider()
            Button("В избранное или из избранного") { withSelection { m, ids in m.toggleFavorite(ids) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("В архив") { withSelection { m, ids in m.setArchived(ids, true) } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model == nil)
            Button("Вернуть из архива") { withSelection { m, ids in m.setArchived(ids, false) } }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
            Button("Отметить все как просмотренные") { model?.markAllSeen() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Снять выбор") { if let m = model, !m.selection.isEmpty { m.selection = [] } }
                .keyboardShortcut(.escape, modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Шаблоны обращений…") { MenuActions.openSettings(.outreach) }
                .disabled(model == nil)
        }

        // MARK: Вид
        CommandGroup(before: .sidebar) {
            ForEach(Array(NavSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { MenuActions.showMainWindow(); model?.section = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(model == nil)
            }
            Divider()
        }
        CommandGroup(after: .sidebar) {
            Button("Показать или скрыть правую панель") { model?.inspectorShown.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model == nil)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Увеличить интерфейс") { look.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Увеличить интерфейс") { look.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Уменьшить интерфейс") { look.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Фактический размер") { look.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Picker("Тема", selection: Binding(get: { look.theme }, set: { look.theme = $0 })) {
                ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
            }
            Button("Настройки внешнего вида…") { MenuActions.openSettings(.appearance) }
        }

        // MARK: Справка
        CommandGroup(replacing: .help) {
            Link("Справка Lead Generator (Wiki)", destination: Updates.wikiPage)
            Link("Что нового в этой версии", destination: MenuActions.releaseNotesPage)
            Link("Все выпуски", destination: Updates.releasesPage)
            Divider()
            Button("Сообщить о проблеме…") { ReportController.shared.compose(crash: nil) }
            Button("Отправить отчёт о последнем сбое…") {
                ReportController.shared.refresh()
                ReportController.shared.compose(crash: ReportController.shared.crashes.first)
            }
            Button("Показать журнал ошибок в Finder") {
                let url = ErrorLog.url
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
                }
            }
            Divider()
            Link("Страница проекта на GitHub", destination: Updates.releasesPage.deletingLastPathComponent())
        }
    }
}
