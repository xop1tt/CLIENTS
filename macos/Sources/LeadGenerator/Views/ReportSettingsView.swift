import LeadGenCore
import SwiftUI

/// «Настройки → Отчёты»: вылеты, зависания и журнал ошибок.
struct ReportSettingsView: View {
    @State private var reports = ReportController.shared

    var body: some View {
        @Bindable var reports = reports
        Form {
            Section("Отчёты о сбоях") {
                Toggle("Предлагать отправить отчёт после вылета", isOn: $reports.offerAfterCrash)
                if let last = reports.crashes.first {
                    LabeledContent("Последний отчёт", value: "\(last.kind), \(last.date.fullRu)")
                    LabeledContent("Всего на этом Mac", value: "\(reports.crashes.count)")
                } else {
                    Text("Отчётов о вылетах и зависаниях Lead Generator на этом Mac нет.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Отправить последний отчёт…") { reports.compose(crash: reports.crashes.first) }
                        .disabled(reports.crashes.isEmpty)
                    Button("Сообщить о проблеме…") { reports.compose(crash: nil) }
                    Spacer()
                }
            }
            Section("Журнал ошибок") {
                Toggle("Записывать ошибки в журнал", isOn: $reports.logErrors)
                Toggle("Прикладывать последние ошибки к отчёту", isOn: $reports.includeLog)
                HStack {
                    Button("Показать журнал") { reports.showLog() }
                    Button("Очистить журнал") { ErrorLog.clear() }
                    Spacer()
                }
                Text("В журнал попадают сообщения об ошибках поиска, экспорта и резервных копий. Он хранится только на этом Mac: ~/Library/Logs/LeadGenerator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Сами по себе отчёты никуда не уходят. По кнопке приложение покажет текст отчёта, его можно поправить, а затем откроется новое обращение в Issues на GitHub: отправляете его вы, со своей бесплатной учётной записью. Домашняя папка и имя пользователя Mac из текста убираются, контакты лидов в отчёт не попадают.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { reports.refresh() }
    }
}
