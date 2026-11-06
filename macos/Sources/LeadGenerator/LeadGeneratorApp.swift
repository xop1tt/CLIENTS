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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct LeadGeneratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = SessionModel()
    @State private var look = AppearanceSettings()

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
