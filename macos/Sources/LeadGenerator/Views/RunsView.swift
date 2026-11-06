import AppKit
import LeadGenCore
import SwiftUI

struct RunsView: View {
    @Environment(AppModel.self) private var model
    @State private var loading = false

    var body: some View {
        Group {
            if !model.githubConfig.isComplete || !model.hasToken {
                ContentUnavailableView {
                    Label("Нет доступа к GitHub", systemImage: "key")
                } description: {
                    Text("Укажите репозиторий и токен в настройках синхронизации, чтобы видеть запуски поиска.")
                } actions: { SettingsLink { Text("Открыть настройки") } }
            } else if model.runs.isEmpty && !loading {
                ContentUnavailableView("Запусков нет", systemImage: "clock",
                                       description: Text("Поиск ещё не запускался или GitHub не вернул данные."))
            } else {
                Table(model.runs) {
                    TableColumn("№") { (r: WorkflowRun) in Text("\(r.runNumber)").monospacedDigit().appFont(12.5) }
                        .width(50)
                    TableColumn("Статус") { (r: WorkflowRun) in
                        Label(r.statusTitle, systemImage: icon(r)).foregroundStyle(color(r)).appFont(12.5)
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn("Начало") { (r: WorkflowRun) in Text((r.runStartedAt ?? r.createdAt)?.fullRu ?? "—").appFont(12.5) }
                    TableColumn("Длительность") { (r: WorkflowRun) in Text(r.duration.map(durationText) ?? "—").appFont(12.5).monospacedDigit() }
                        .width(min: 90, ideal: 110)
                    TableColumn("Как запущен") { (r: WorkflowRun) in
                        Text(r.event == "schedule" ? "По расписанию" : r.event == "workflow_dispatch" ? "Вручную" : r.event).appFont(12.5)
                    }
                    TableColumn("") { (r: WorkflowRun) in
                        HStack {
                            if r.failed {
                                Button("Повторить") { Task { await model.rerun(r) } }
                            }
                            if let url = r.htmlURL {
                                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                                    .buttonStyle(.borderless).help("Открыть в GitHub (логи)")
                            }
                        }
                    }
                    .width(min: 110, ideal: 130)
                }
            }
        }
        .navigationTitle("История запусков")
        .task { await refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await refresh() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                Button { Task { await model.dispatchSearch() } } label: { Label("Запустить поиск", systemImage: "play.fill") }
                    .disabled(model.dispatching)
            }
        }
    }

    private func refresh() async {
        loading = true
        await model.loadRuns()
        loading = false
    }

    private func icon(_ r: WorkflowRun) -> String {
        if r.status != "completed" { return "hourglass" }
        return r.conclusion == "success" ? "checkmark.circle.fill" : r.failed ? "xmark.octagon.fill" : "minus.circle"
    }

    private func color(_ r: WorkflowRun) -> Color {
        if r.status != "completed" { return .blue }
        return r.conclusion == "success" ? .green : r.failed ? .red : .secondary
    }
}

/// Правая панель для раздела запусков: журнал синхронизаций.
struct SyncInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Синхронизации")
                if model.syncLog.isEmpty { Text("Ещё не было").appFont(12.5).foregroundStyle(.secondary) }
                ForEach(model.syncLog) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(e.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.message).appFont(12.5).lineLimit(4)
                            if let at = e.at { Text(at.fullRu).appFont(11).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
