import LeadGenCore
import LeadSearch
import SwiftUI

/// Журнал запусков поиска на этом Mac.
struct SearchLogView: View {
    @Environment(\.appModel) private var model

    var body: some View {
        Group {
            if model.syncLog.isEmpty {
                ContentUnavailableView {
                    Label("Поиск ещё не запускался", systemImage: "clock")
                } description: {
                    Text("Нажмите «Найти лиды» вверху. Пока приложение открыто, поиск повторяется автоматически по интервалам источников.")
                } actions: {
                    Button("Найти лиды") { model.runSearch() }.disabled(model.searching)
                }
            } else {
                Table(model.syncLog) {
                    TableColumn("") { (e: SyncLogEntry) in
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(e.ok ? .green : .orange)
                    }
                    .width(24)
                    TableColumn("Когда") { (e: SyncLogEntry) in Text(e.at?.fullRu ?? "—").appFont(12.5) }
                        .width(min: 140, ideal: 170)
                    TableColumn("Новых") { (e: SyncLogEntry) in Text("\(e.added)").monospacedDigit().appFont(12.5) }
                        .width(60)
                    TableColumn("Обновлено") { (e: SyncLogEntry) in Text("\(e.updated)").monospacedDigit().appFont(12.5) }
                        .width(80)
                    TableColumn("Итог") { (e: SyncLogEntry) in Text(e.message).appFont(12.5).lineLimit(2) }
                }
            }
        }
        .navigationTitle("Журнал поиска")
    }
}

/// Правая панель журнала: последний запуск по источникам и ошибки.
struct SearchLogInspector: View {
    @Environment(\.appModel) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let report = model.lastReport {
                    VStack(alignment: .leading, spacing: 8) {
                        PanelHeader(title: "Последний запуск")
                        ForEach(report.sources) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    SourceBadge(source: r.source)
                                    Spacer()
                                    if r.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                                }
                                Text(line(r)).appFont(11.5).foregroundStyle(.secondary)
                                ForEach(r.errors.prefix(3), id: \.self) { Text($0).appFont(11).foregroundStyle(.orange).lineLimit(3) }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    PanelHeader(title: "Ошибки и предупреждения")
                    if model.pipelineErrors.isEmpty { Text("Нет").appFont(12.5).foregroundStyle(.secondary) }
                    ForEach(model.pipelineErrors.prefix(30)) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(SourceCatalog.title(e.module)).appFont(12, .medium)
                            Text(e.message).appFont(11.5).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                            if let at = e.at { Text(at.fullRu).appFont(10.5).foregroundStyle(.tertiary) }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ r: SourceReport) -> String {
        if let s = r.skipped { return "Пропущен: \(s)" }
        return "Найдено \(r.found), новых \(r.added), обновлено \(r.updated), повторов \(r.duplicates)"
    }
}
