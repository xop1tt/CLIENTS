import AppKit
import LeadGenCore
import SwiftUI

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?

    private func found(_ source: String, days: Int) -> Int {
        let from = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return model.leads.filter { $0.data.source == source && $0.discoveredAt >= from }.count
    }

    private var keys: [String] {
        Array(Set(model.sources.map(\.source)).union(SourceCatalog.known.keys.filter { $0 != "site_checker" })).sorted()
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $selected) {
            Section("Подключённые источники") {
                ForEach(keys, id: \.self) { key in
                    let state = model.sources.first { $0.source == key }
                    HStack(spacing: 12) {
                        SourceBadge(source: key, showTitle: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SourceCatalog.title(key)).appFont(13, .medium)
                            Text(SourceCatalog.known[key]?.note ?? "").appFont(11.5).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Tag(text: SourceCatalog.known[key]?.access ?? "—",
                            color: SourceCatalog.known[key]?.access == "Бесплатно" ? .green : .blue)
                        statusLabel(state).frame(width: 150, alignment: .leading)
                        Text("\(found(key, days: 7))").appFont(12.5).monospacedDigit().frame(width: 40, alignment: .trailing)
                            .help("Найдено за 7 дней")
                    }
                    .scaledPadding(.vertical, 4)
                    .tag(key)
                }
            }
            Section("Не подключены") {
                ForEach(Array(SourceCatalog.unavailable.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 12) {
                        Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0).appFont(13, .medium)
                            Text(item.1).appFont(11.5).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Tag(text: "Недоступно бесплатно", color: .red)
                    }
                    .scaledPadding(.vertical, 4)
                    .selectionDisabled()
                }
            }
        }
        .navigationTitle("Источники")
        .onChange(of: selected) { _, v in model.selectedSource = v }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.dispatchSearch(force: true) } } label: { Label("Проверить все сейчас", systemImage: "play.fill") }
                    .help("Запустить поиск в Actions без учёта интервалов источников")
            }
        }
    }

    @ViewBuilder private func statusLabel(_ s: SourceState?) -> some View {
        if let s {
            if s.consecutiveFailures > 0 {
                Label("Ошибки: \(s.consecutiveFailures)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).appFont(12)
            } else {
                Label(s.lastSuccessAt.map { "Работает · \($0.shortRelative)" } ?? "Работает", systemImage: "circle.fill")
                    .foregroundStyle(.green).appFont(12)
            }
        } else {
            Label("Нет данных", systemImage: "circle").foregroundStyle(.secondary).appFont(12)
        }
    }
}

struct SourcesInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let key = model.selectedSource {
            let state = model.sources.first { $0.source == key }
            let info = SourceCatalog.known[key]
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        SourceBadge(source: key, showTitle: false)
                        Text(SourceCatalog.title(key)).appFont(16, .semibold)
                    }
                    if let info {
                        VStack(alignment: .leading, spacing: 6) {
                            PanelHeader(title: "Условия доступа")
                            Tag(text: info.access, color: info.access == "Бесплатно" ? .green : .blue)
                            Text(info.note).appFont(12.5).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PanelHeader(title: "Состояние")
                        row("Статус", state?.status ?? "нет данных")
                        row("Последний успех", state?.lastSuccessAt?.fullRu ?? "—")
                        row("Последняя попытка", state?.lastAttemptAt?.fullRu ?? "—")
                        row("Ошибок подряд", "\(state?.consecutiveFailures ?? 0)")
                        row("Лидов всего", "\(model.leads.filter { $0.data.source == key }.count)")
                    }
                    if let err = state?.lastError, !err.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            PanelHeader(title: "Последняя ошибка")
                            Text(err).appFont(12).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                        }
                    }
                    let errs = model.pipelineErrors.filter { $0.module == key }
                    if !errs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            PanelHeader(title: "Журнал ошибок")
                            ForEach(errs.prefix(10)) { e in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.message).appFont(12).lineLimit(3)
                                    if let at = e.at { Text(at.fullRu).appFont(11).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PanelHeader(title: "Настройки")
                        Text("Частота, лимиты, каналы и регионы задаются в config.yaml репозитория: поиск выполняется в GitHub Actions. Редактор этих настроек в приложении — следующий этап.")
                            .appFont(12).foregroundStyle(.secondary)
                        if model.githubConfig.isComplete,
                           let url = URL(string: "https://github.com/\(model.githubOwner)/\(model.githubRepo)/blob/\(model.githubBranch)/config.yaml") {
                            Link("Открыть config.yaml на GitHub", destination: url).appFont(12.5)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Источник не выбран", systemImage: "cylinder.split.1x2",
                                   description: Text("Выберите источник, чтобы увидеть состояние, ошибки и условия доступа."))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).appFont(12.5).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(v).appFont(12.5)
        }
    }
}
