import AppKit
import LeadGenCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var themeObserver: NSObjectProtocol?

    private let statusItem = StatusItemController()
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запуск из `swift run` / без .app-обёртки: показать окно и значок в Dock.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updateDockIcon()
        statusItem.setVisible(BackgroundMode.enabled)
        // Переключатель «Продолжать работу в фоне» хранится в UserDefaults.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.statusItem.setVisible(BackgroundMode.enabled) } }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateDockIcon() } }
        UpdateController.shared.startAutomaticChecks()
        // Отчёт о прошлом вылете предлагается, когда окно уже на экране.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ReportController.shared.checkAfterLaunch() }
    }

    /// Значок в Dock следует теме macOS: светлый (из AppIcon.icns) или тёмный (AppIcon-Dark.png).
    private func updateDockIcon() {
        let systemDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        if systemDark, let url = Bundle.main.url(forResource: "AppIcon-Dark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        } else {
            NSApp.applicationIconImage = nil  // вернуть значок из бандла
        }
    }

    /// Работа в фоне: при закрытом окне приложение остаётся в строке меню и ищет по расписанию.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !BackgroundMode.enabled }
}

enum BackgroundMode {
    static let key = "app.keepRunning"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

@main
struct LeadGeneratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = SessionModel.shared
    @State private var look = AppearanceSettings.shared

    var body: some Scene {
        WindowGroup("Lead Generator", id: "main") {
            SessionRoot()
                .environment(\.session, session)
                .modifier(LookRoot(look: look))
                .frame(minWidth: 980, minHeight: 620)
                .background(OpenWindowBridge())
                .onAppear { look.apply() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { UpdateController.shared.check(manual: true) }
            }
            CommandGroup(replacing: .help) {
                Button("Сообщить о проблеме…") { ReportController.shared.compose(crash: nil) }
                Button("Отправить отчёт о последнем сбое…") {
                    ReportController.shared.refresh()
                    ReportController.shared.compose(crash: ReportController.shared.crashes.first)
                }
                Divider()
                Link("Страница проекта на GitHub", destination: Updates.releasesPage.deletingLastPathComponent())
            }
            // Команды не зависят от часто меняющегося состояния (выделение, ход поиска):
            // иначе SwiftUI перестраивает главное меню на каждое изменение, и при частых
            // обновлениях приложение зависало. Действия сами проверяют, можно ли их выполнить.
            CommandMenu("Лиды") {
                Button("Найти лиды") { session.current?.runSearch() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(session.current == nil)
                Button("Остановить поиск") { session.current?.stopSearch() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(session.current == nil)
                Divider()
                Button("Отметить все как просмотренные") { session.current?.markAllSeen() }
                    .disabled(session.current == nil)
                Button("В избранное") { if let m = session.current, !m.selection.isEmpty { m.toggleFavorite(m.selection) } }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(session.current == nil)
                Button("В архив") { if let m = session.current, !m.selection.isEmpty { m.setArchived(m.selection, true) } }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(session.current == nil)
                Divider()
                Button("Выйти из учётной записи") { session.logout() }
                    .disabled(session.current == nil)
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
            }
            CommandGroup(after: .sidebar) {
                Button("Показать или скрыть правую панель") {
                    session.current?.inspectorShown.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(session.current == nil)
            }
        }

        Settings {
            SettingsRoot()
                .environment(\.session, session)
                .modifier(LookRoot(look: look))
        }

    }
}

/// Окно приложения: вход или рабочее пространство пользователя.
struct SessionRoot: View {
    @Environment(\.session) private var session

    var body: some View {
        Group {
            if let model = session.current {
                RootView()
                    .environment(\.appModel, model)
                    .id(model.username)
            } else {
                AuthView()
            }
        }
        // Ссылки из писем (leadgenerator://auth/callback) открываются в этом же окне.
        .onOpenURL { session.handle(url: $0) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

struct SettingsRoot: View {
    @Environment(\.session) private var session

    var body: some View {
        if let model = session.current {
            SettingsView().environment(\.appModel, model)
        } else {
            ContentUnavailableView("Войдите в учётную запись", systemImage: "person.crop.circle",
                                   description: Text("Настройки поиска и данных у каждого пользователя свои."))
                .frame(width: 480, height: 300)
        }
    }
}
