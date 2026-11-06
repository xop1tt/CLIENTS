import SwiftUI

// Модели передаются через собственные ключи окружения со значением по умолчанию.
//
// `@Environment(Type.self)` для @Observable-объекта завершает приложение, если объекта
// в окружении нет. SwiftUI на macOS размещает часть содержимого (панель инструментов,
// инспектор, вкладки настроек, листы, меню) в отдельных NSHostingView, и туда окружение
// доходит не всегда: так появлялись вылеты EXC_BREAKPOINT в EnvironmentValues.subscript.
// С ключами ниже в таком случае берётся общий объект приложения, а не аварийное завершение.

private struct AppModelKey: EnvironmentKey {
    static var defaultValue: AppModel {
        MainActor.assumeIsolated { SessionModel.shared.current ?? AppModel.placeholder }
    }
}

private struct SessionKey: EnvironmentKey {
    static var defaultValue: SessionModel { MainActor.assumeIsolated { SessionModel.shared } }
}

private struct LookKey: EnvironmentKey {
    static var defaultValue: AppearanceSettings { AppearanceSettings.shared }
}

extension EnvironmentValues {
    var appModel: AppModel {
        get { self[AppModelKey.self] }
        set { self[AppModelKey.self] = newValue }
    }
    var session: SessionModel {
        get { self[SessionKey.self] }
        set { self[SessionKey.self] = newValue }
    }
    var look: AppearanceSettings {
        get { self[LookKey.self] }
        set { self[LookKey.self] = newValue }
    }
}
