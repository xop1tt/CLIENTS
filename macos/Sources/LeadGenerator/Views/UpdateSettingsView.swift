import LeadGenCore
import SwiftUI

/// «Настройки → Обновления»: автоматическая проверка новых версий на GitHub.
struct UpdateSettingsView: View {
    @State private var updates = UpdateController.shared

    var body: some View {
        @Bindable var updates = updates
        Form {
            Section("Версия") {
                LabeledContent("Установлена", value: updates.current?.description ?? "сборка без номера версии")
                if let at = updates.lastCheck {
                    LabeledContent("Последняя проверка", value: at.fullRu)
                }
                HStack {
                    Button("Проверить сейчас") { updates.check(manual: true) }
                        .disabled(busy || !updates.canUpdate)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Section("Автоматически") {
                Toggle("Проверять обновления автоматически", isOn: $updates.automatic)
                Text("Раз в сутки приложение спрашивает у GitHub, вышел ли новый релиз. Если вышел, покажет, что в нём нового, и предложит установить: скачает установщик, сверит контрольную сумму SHA-256, заменит приложение и перезапустит его. Без вашего согласия ничего не устанавливается.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Link("Все версии на GitHub", destination: Updates.releasesPage)
                Text("Проверка бесплатная и без учётной записи: используется публичная страница релизов. Контрольная сумма защищает от повреждённой или недокачанной загрузки. Приложение подписано без сертификата Apple, поэтому подлинность проверяется только по сумме из того же релиза.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var busy: Bool {
        switch updates.phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var status: String {
        switch updates.phase {
        case .idle: return ""
        case .checking: return "Проверяю…"
        case .upToDate: return "Установлена последняя версия"
        case .available(let v): return "Доступна версия \(v)"
        case .downloading: return "Скачиваю и проверяю…"
        case .installing: return "Устанавливаю…"
        case .failed(let why): return why
        }
    }
}
