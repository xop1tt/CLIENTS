import AppKit
import LeadGenCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запуск из `swift run` / без .app-обёртки: показать окно и значок в Dock.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        statusItem.setVisible(BackgroundMode.enabled)
        // Переключатель «Продолжать работу в фоне» хранится в UserDefaults.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.statusItem.setVisible(BackgroundMode.enabled) } }
        UpdateController.shared.startAutomaticChecks()
        // Отчёт о прошлом вылете предлагается, когда окно уже на экране.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ReportController.shared.checkAfterLaunch() }
    }

    // Значок приложения один и тёмный, он берётся из пакета (AppIcon.icns). Значок в Dock не
    // подменяется (NSApp.applicationIconImage): при выходе Dock показывает значок из пакета, и подмена
    // «слетала» на светлый. Это проверяет IconTests.

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
        WindowGroup("Customers", id: "main") {
            SessionRoot()
                .environment(\.session, session)
                .modifier(LookRoot(look: look))
                .frame(minWidth: 980, minHeight: 620)
                .background(OpenWindowBridge())
                .onAppear { look.apply() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(session: session, look: look) }

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
