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
    @State private var model = AppModel()
    @State private var look = AppearanceSettings()

    var body: some Scene {
        WindowGroup("Lead Generator", id: "main") {
            RootView()
                .environment(model)
                .modifier(LookRoot(look: look))
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { look.apply() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Лиды") {
                Button("Синхронизировать") { Task { await model.syncNow() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Запустить поиск в GitHub Actions") { Task { await model.dispatchSearch() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Отметить все как просмотренные") { model.markAllSeen() }
                Button("В избранное") { model.toggleFavorite(model.selection) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
                Button("В архив") { model.setArchived(model.selection, true) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selection.isEmpty)
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
                Button(model.inspectorShown ? "Скрыть правую панель" : "Показать правую панель") {
                    model.inspectorShown.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .modifier(LookRoot(look: look))
        }
    }
}
