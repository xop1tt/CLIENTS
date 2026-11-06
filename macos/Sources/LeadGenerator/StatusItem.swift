import AppKit
import SwiftUI

/// Значок в строке меню для работы в фоне.
///
/// Сделан на AppKit, а не через `MenuBarExtra`: меню собирается только в момент открытия
/// и не участвует в графе обновлений SwiftUI. В 1.0.3 `MenuBarExtra` с привязкой к настройке
/// вместе с командами главного меню перестраивались по кругу, и приложение зависало.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static var openMainWindow: (() -> Void)?

    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "megaphone", accessibilityDescription: "Lead Generator")
            item.button?.image?.isTemplate = true
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Пункты меню собираются заново при каждом открытии: так в них всегда свежее состояние.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = SessionModel.shared.current
        if let model {
            let status: String
            if model.searching {
                status = model.searchProgress ?? "Идёт поиск…"
            } else if let at = model.lastSearchAt {
                status = "Последний поиск: \(at.shortRelative)"
            } else {
                status = "Поиск ещё не запускался"
            }
            let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(action(model.searching ? "Остановить поиск" : "Найти лиды", #selector(toggleSearch)))
        } else {
            let info = NSMenuItem(title: "Вход не выполнен", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        menu.addItem(action("Открыть Lead Generator", #selector(openWindow)))
        menu.addItem(.separator())
        menu.addItem(action("Завершить Lead Generator", #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func toggleSearch() {
        guard let model = SessionModel.shared.current else { return }
        if model.searching { model.stopSearch() } else { model.runSearch() }
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            Self.openMainWindow?()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Запоминает действие «открыть окно», чтобы значок в строке меню мог открыть закрытое окно.
struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let open = openWindow
                StatusItemController.openMainWindow = { open(id: "main") }
            }
    }
}
