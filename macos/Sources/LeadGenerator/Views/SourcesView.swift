import AppKit
import LeadGenCore
import LeadSearch
import SwiftUI

/// Раздел «Источники»: список слева, настройки выбранного источника справа.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppearanceSettings.self) private var look

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            List(selection: $model.selectedSource) {
                Section("Источники поиска") {
                    ForEach(SourceKey.all, id: \.self) { key in
                        SourceRow(key: key).tag(key)
                    }
                }
                Section("Не подключены") {
                    ForEach(Array(SourceCatalog.unavailable.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.0).appFont(12.5, .medium)
                                Text(item.1).appFont(11).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .scaledPadding(.vertical, 2)
                        .selectionDisabled()
                    }
                }
            }
            .listStyle(.inset)
            .frame(width: 290 * look.scale)
            Divider()
            Group {
                if let key = model.selectedSource {
                    SourceEditor(key: key).id(key)
                } else {
                    ContentUnavailableView("Выберите источник", systemImage: "cylinder.split.1x2")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Источники")
    }
}

private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        let state = model.sources.first { $0.source == key }
        let enabled = model.searchSettings.isEnabled(key)
        HStack(spacing: 10) {
            SourceBadge(source: key, showTitle: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(SourceCatalog.title(key)).appFont(13, .medium)
                Group {
                    if !enabled {
                        Text("Выключен")
                    } else if let p = model.problem(key) {
                        Text("Не настроен: \(p)").foregroundStyle(.orange)
                    } else if let s = state, s.consecutiveFailures > 0 {
                        Text("Ошибки: \(s.consecutiveFailures) подряд").foregroundStyle(.orange)
                    } else if let at = state?.lastSuccessAt {
                        Text("Работает · \(at.shortRelative)")
                    } else {
                        Text("Ещё не запускался")
                    }
                }
                .appFont(11).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(dot(enabled, state)).frame(width: 7, height: 7)
        }
        .scaledPadding(.vertical, 3)
    }

    private func dot(_ enabled: Bool, _ s: SourceState?) -> Color {
        guard enabled else { return .gray.opacity(0.4) }
        if model.problem(key) != nil || (s?.consecutiveFailures ?? 0) > 0 { return .orange }
        return .green
    }
}

/// Настройки одного источника.
struct SourceEditor: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    SourceBadge(source: key, showTitle: false).scaleEffect(1.6).padding(6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SourceCatalog.title(key)).font(.title3.weight(.semibold))
                        Text(SourceCatalog.known[key]?.note ?? "").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Tag(text: SourceCatalog.known[key]?.access ?? "—",
                        color: SourceCatalog.known[key]?.access == "Бесплатно" ? .green : .blue)
                }
                Toggle("Включён", isOn: enabledBinding)
                Picker("Проверять", selection: intervalBinding) {
                    ForEach(intervals, id: \.self) { h in Text(intervalTitle(h)).tag(h) }
                }
                HStack {
                    Button("Проверить сейчас") { model.runSearch(force: true, only: [key]) }
                        .disabled(model.searching || !model.searchSettings.isEnabled(key) || model.problem(key) != nil)
                    if let p = model.problem(key), model.searchSettings.isEnabled(key) {
                        Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    }
                    Spacer()
                    Button("Начать заново") { model.resetSourceMemory(key) }
                        .help("Забыть, какие записи уже обработаны: следующий поиск заново прочитает ленты, каналы и регионы")
                }
            }
            switch key {
            case SourceKey.rss: rss
            case SourceKey.telegram: telegram
            case SourceKey.vk: vk
            case SourceKey.osm: osm
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: RSS

    @ViewBuilder private var rss: some View {
        @Bindable var model = model
        Section {
            TokenListEditor(title: "Ленты", placeholder: "https://www.fl.ru/rss/all.xml",
                            items: $model.searchSettings.rss.feeds, normalize: SourceInput.feedURL,
                            invalidHint: "Нужен публичный адрес http(s)")
        } header: { Text("RSS и Atom") } footer: {
            Text("Любые публичные ленты заказов. Повторно уже обработанные записи не читаются.")
        }
        keywordsSection($model.searchSettings.rss.keywords,
                        footer: "Пусто — в оценку идут все записи ленты. Слова ищутся как часть слова: «разработ» найдёт «разработка» и «разработчик».")
    }

    // MARK: Telegram

    @ViewBuilder private var telegram: some View {
        @Bindable var model = model
        Section {
            TokenListEditor(title: "Каналы", placeholder: "имя, @имя или ссылка t.me/имя",
                            items: $model.searchSettings.telegram.channels, normalize: SourceInput.telegramChannel,
                            invalidHint: "Имя канала: латиница, цифры и _, от 4 символов")
            Stepper("Страниц на канал за запуск: \(model.searchSettings.telegram.maxPages)",
                    value: $model.searchSettings.telegram.maxPages, in: 1...10)
        } header: { Text("Публичные каналы") } footer: {
            Text("Читается веб-превью t.me/s/канал — только публичные каналы. Приватные каналы и чаты недоступны.")
        }
        keywordsSection($model.searchSettings.telegram.keywords,
                        footer: "Пост попадает в оценку, если содержит хотя бы одно слово. Пусто — все посты.")
    }

    // MARK: VK

    @ViewBuilder private var vk: some View {
        @Bindable var model = model
        Section {
            VKTokenField()
            TokenListEditor(title: "Сообщества", placeholder: "короткое имя или ссылка vk.com/имя",
                            items: $model.searchSettings.vk.communities, normalize: SourceInput.vkCommunity,
                            invalidHint: "Короткое имя сообщества из адреса vk.com/…")
            Stepper("Страниц на сообщество: \(model.searchSettings.vk.maxPages)",
                    value: $model.searchSettings.vk.maxPages, in: 1...10)
        } header: { Text("Открытые сообщества") } footer: {
            Text("Сервисный ключ бесплатный: dev.vk.com → Мои приложения → создать приложение → «Сервисный ключ доступа». Ключ хранится в Связке ключей этого Mac.")
        }
        keywordsSection($model.searchSettings.vk.keywords, footer: "Пусто — все посты стены.")
    }

    // MARK: OpenStreetMap

    @ViewBuilder private var osm: some View {
        @Bindable var model = model
        Section {
            TokenListEditor(title: "Города и регионы", placeholder: "например, Казань",
                            items: $model.searchSettings.osm.regions, normalize: SourceInput.region,
                            invalidHint: "Название города или региона")
        } header: { Text("Где искать") } footer: {
            Text("Название как в OpenStreetMap: на местном языке, по-русски или по-английски.")
        }
        Section("Категории организаций") {
            ForEach($model.searchSettings.osm.categories) { $cat in
                Toggle(isOn: $cat.enabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cat.label)
                        Text(cat.filters.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        Section {
            Toggle("Проверять сайты организаций", isOn: $model.searchSettings.osm.checkWebsites)
            Stepper("Новых организаций за запуск: \(model.searchSettings.osm.maxNewPerRun)",
                    value: $model.searchSettings.osm.maxNewPerRun, in: 5...200, step: 5)
            Stepper("Повторять одинаковый запрос не чаще чем раз в \(Int(model.searchSettings.osm.refreshDays)) дн.",
                    value: $model.searchSettings.osm.refreshDays, in: 1...60)
        } header: { Text("Лимиты") } footer: {
            Text("Overpass API бесплатный и общий для всех, поэтому запросы экономятся. Данные © участники OpenStreetMap (ODbL).")
        }
    }

    // MARK: Общее

    private func keywordsSection(_ items: Binding<[String]>, footer: String) -> some View {
        Section {
            TokenListEditor(title: "Ключевые слова", placeholder: "слово или несколько через запятую",
                            items: items, normalize: SourceInput.keyword, invalidHint: nil)
        } header: { Text("Ключевые слова") } footer: { Text(footer) }
    }

    private var intervals: [Double] {
        let base: [Double] = [1, 2, 3, 6, 12, 24, 72, 120, 168]
        let current = model.searchSettings.intervalHours(key)
        return base.contains(current) ? base : (base + [current]).sorted()
    }

    private func intervalTitle(_ h: Double) -> String {
        switch h {
        case 1: return "Каждый час"
        case ..<24: return "Каждые \(Int(h)) ч"
        case 24: return "Раз в сутки"
        default: return "Раз в \(Int(h / 24)) дн."
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.searchSettings.isEnabled(key) }, set: { on in
            switch key {
            case SourceKey.rss: model.searchSettings.rss.enabled = on
            case SourceKey.telegram: model.searchSettings.telegram.enabled = on
            case SourceKey.vk: model.searchSettings.vk.enabled = on
            case SourceKey.osm: model.searchSettings.osm.enabled = on
            default: break
            }
        })
    }

    private var intervalBinding: Binding<Double> {
        Binding(get: { model.searchSettings.intervalHours(key) }, set: { h in
            switch key {
            case SourceKey.rss: model.searchSettings.rss.intervalHours = h
            case SourceKey.telegram: model.searchSettings.telegram.intervalHours = h
            case SourceKey.vk: model.searchSettings.vk.intervalHours = h
            case SourceKey.osm: model.searchSettings.osm.intervalHours = h
            default: break
            }
        })
    }
}

private struct VKTokenField: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        HStack {
            Text("Сервисный ключ VK")
            SecureField("", text: $token, prompt: Text(model.hasVKToken ? "сохранён" : "вставьте ключ"))
                .labelsHidden()
                .inputField()
            Button("Сохранить") { model.vkToken = token; token = "" }.disabled(token.isEmpty)
            if model.hasVKToken {
                Button("Удалить", role: .destructive) { model.vkToken = "" }
            }
        }
    }
}

/// Правая панель раздела «Источники»: состояние и журнал ошибок выбранного источника.
struct SourcesInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let key = model.selectedSource {
            let state = model.sources.first { $0.source == key }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        SourceBadge(source: key, showTitle: false)
                        Text(SourceCatalog.title(key)).appFont(16, .semibold)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PanelHeader(title: "Состояние")
                        row("Статус", statusTitle(state?.status))
                        row("Последний успех", state?.lastSuccessAt?.fullRu ?? "—")
                        row("Последняя попытка", state?.lastAttemptAt?.fullRu ?? "—")
                        row("Ошибок подряд", "\(state?.consecutiveFailures ?? 0)")
                        row("Лидов всего", "\(model.leads.filter { $0.data.source == key }.count)")
                        row("За 7 дней", "\(found(key, days: 7))")
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
                            PanelHeader(title: "Журнал")
                            ForEach(errs.prefix(15)) { e in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.message).appFont(12).lineLimit(3).textSelection(.enabled)
                                    if let at = e.at { Text(at.fullRu).appFont(11).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Источник не выбран", systemImage: "cylinder.split.1x2",
                                   description: Text("Выберите источник, чтобы увидеть состояние и ошибки."))
        }
    }

    private func found(_ source: String, days: Int) -> Int {
        let from = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return model.leads.filter { $0.data.source == source && $0.discoveredAt >= from }.count
    }

    private func statusTitle(_ s: String?) -> String {
        switch s {
        case "ok": return "Работает"
        case "partial": return "Работает, часть запросов с ошибками"
        case "error": return "Ошибка"
        default: return "Ещё не запускался"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).appFont(12.5).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(v).appFont(12.5)
        }
    }
}
