import AppKit
import LeadGenCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var themeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запуск из `swift run` / без .app-обёртки: показать окно и значок в Dock.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updateDockIcon()
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateDockIcon() } }
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
    @State private var session = SessionModel()
    @State private var look = AppearanceSettings()
    @AppStorage(BackgroundMode.key) private var keepRunning = true

    var body: some Scene {
        WindowGroup("Lead Generator", id: "main") {
            SessionRoot()
                .environment(session)
                .modifier(LookRoot(look: look))
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { look.apply() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Лиды") {
                Button(session.current?.searching == true ? "Остановить поиск" : "Найти лиды") {
                    guard let model = session.current else { return }
                    if model.searching { model.stopSearch() } else { model.runSearch() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session.current == nil)
                Divider()
                Button("Отметить все как просмотренные") { session.current?.markAllSeen() }
                    .disabled(session.current == nil)
                Button("В избранное") { if let m = session.current { m.toggleFavorite(m.selection) } }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(session.current?.selection.isEmpty ?? true)
                Button("В архив") { if let m = session.current { m.setArchived(m.selection, true) } }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(session.current?.selection.isEmpty ?? true)
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
                Button(session.current?.inspectorShown == false ? "Показать правую панель" : "Скрыть правую панель") {
                    session.current?.inspectorShown.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(session.current == nil)
            }
        }

        Settings {
            SettingsRoot()
                .environment(session)
                .modifier(LookRoot(look: look))
        }

        // Значок в строке меню: поиск и окно, пока приложение работает в фоне.
        MenuBarExtra(isInserted: $keepRunning) {
            StatusMenu(session: session)
        } label: {
            Image(systemName: session.current?.searching == true ? "magnifyingglass.circle.fill" : "megaphone")
        }
    }
}

/// Меню значка в строке меню. Модель передаётся параметром: у этого меню своё окружение.
struct StatusMenu: View {
    let session: SessionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let model = session.current {
            Text(model.searching ? (model.searchProgress ?? "Идёт поиск…")
                 : model.lastSearchAt.map { "Последний поиск: \($0.shortRelative)" } ?? "Поиск ещё не запускался")
            Button(model.searching ? "Остановить поиск" : "Найти лиды") {
                if model.searching { model.stopSearch() } else { model.runSearch() }
            }
        } else {
            Text("Вход не выполнен")
        }
        Divider()
        Button("Открыть Lead Generator") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }
        Divider()
        Button("Завершить Lead Generator") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Окно приложения: вход или рабочее пространство пользователя.
struct SessionRoot: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let model = session.current {
            RootView()
                .environment(model)
                .id(model.username)
        } else {
            AuthView()
        }
    }
}

struct SettingsRoot: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let model = session.current {
            SettingsView().environment(model)
        } else {
            ContentUnavailableView("Войдите в учётную запись", systemImage: "person.crop.circle",
                                   description: Text("Настройки поиска и данных у каждого пользователя свои."))
                .frame(width: 480, height: 300)
        }
    }
}
