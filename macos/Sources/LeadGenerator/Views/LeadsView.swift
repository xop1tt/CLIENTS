import AppKit
import LeadGenCore
import SwiftUI
import UniformTypeIdentifiers

struct LeadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppearanceSettings.self) private var look
    @State private var sortOrder: [KeyPathComparator<LeadItem>] = [KeyPathComparator(\LeadItem.score, order: .reverse)]
    @State private var exportShown = false

    private var items: [LeadItem] { model.visibleLeads.sorted(using: sortOrder) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            filterBar
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                table
            }
            if !model.selection.isEmpty && model.selection.count > 1 { bulkBar }
            Divider()
            statusBar
        }
        .navigationTitle(model.section.title)
        .navigationSubtitle("\(items.count)")
        .searchable(text: $model.filter.search, placement: .toolbar, prompt: "Поиск по названию, контактам, тексту")
        .toolbar { toolbarItems }
        .sheet(isPresented: $exportShown) {
            ExportSheet(items: model.selection.isEmpty ? items : items.filter { model.selection.contains($0.id) })
        }
        .onChange(of: model.selection) { _, ids in
            // Открытый лид считается просмотренным.
            if ids.count == 1 { model.markSeen(ids) }
        }
    }

    // MARK: Таблица

    private var table: some View {
        @Bindable var model = model
        return Table(items, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("") { (l: LeadItem) in
                Button { model.toggleFavorite([l.id]) } label: {
                    Image(systemName: l.favorite ? "star.fill" : "star")
                        .foregroundStyle(l.favorite ? Color.yellow : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .width(22 * look.scale)

            TableColumn("Компания или заказ", value: \LeadItem.title) { (l: LeadItem) in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if l.isNew { Circle().fill(.blue).frame(width: 6, height: 6) }
                        Text(l.data.title).appFont(13, .medium).lineLimit(1)
                    }
                    Text(subtitle(l)).appFont(11.5).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, look.density.rowPadding * look.scale)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Тип", value: \LeadItem.kindTitle) { (l: LeadItem) in
                Label(l.data.kind.title, systemImage: l.data.kind == .order ? "briefcase" : "building.2")
                    .appFont(12).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Источник", value: \LeadItem.source) { (l: LeadItem) in
                SourceBadge(source: l.data.source)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Оценка", value: \LeadItem.score) { (l: LeadItem) in
                ScoreView(score: l.data.score)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Сигналы") { (l: LeadItem) in
                HStack(spacing: 4) {
                    ForEach(Array(signals(l).enumerated()), id: \.offset) { _, s in Tag(text: s.0, color: s.1) }
                }
            }
            .width(min: 120, ideal: 220)

            TableColumn("Найден", value: \LeadItem.discoveredAt) { (l: LeadItem) in
                Text(l.discoveredAt.shortRelative).appFont(12).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            model.selection = ids
            model.inspectorShown = true
        }
    }

    private func subtitle(_ l: LeadItem) -> String {
        let d = l.data
        var parts: [String] = []
        if let b = d.budget { parts.append("\(Int(b).formatted()) \(d.currency == "RUB" || d.currency == nil ? "₽" : d.currency!)") }
        if let a = d.address, !a.isEmpty { parts.append(a) }
        if let r = d.region, !r.isEmpty, !(d.address ?? "").contains(r) { parts.append(r) }
        if parts.isEmpty, !d.description.isEmpty { parts.append(String(d.description.prefix(120))) }
        return parts.joined(separator: " · ")
    }

    /// Короткие сигналы из фактов: только проверенные данные.
    private func signals(_ l: LeadItem) -> [(String, Color)] {
        let d = l.data
        var out: [(String, Color)] = []
        let facts = d.facts.joined(separator: " ").lowercased()
        if d.kind == .organization {
            if (d.website ?? "").isEmpty { out.append(("Нет сайта", .red)) }
            if facts.contains("не открылся") { out.append(("Сайт не открылся", .red)) }
            if facts.contains("viewport") { out.append(("Нет моб. версии", .orange)) }
            if facts.contains("https") && facts.contains("нет") { out.append(("Нет HTTPS", .orange)) }
        } else {
            if d.budget != nil { out.append(("Бюджет", .green)) }
            if d.scoreReasons.contains(where: { $0.contains("явный запрос") }) { out.append(("Явный запрос", .green)) }
            if d.scoreReasons.contains(where: { $0.contains("срочно") }) { out.append(("Срочно", .orange)) }
        }
        if !d.externalResults.isEmpty { out.append(("Анализ", .purple)) }
        return Array(out.prefix(2))
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        if !ids.isEmpty {
            let one = ids.count == 1 ? model.lead(ids.first!) : nil
            if let one, let url = URL(string: one.data.url), !one.data.url.isEmpty {
                Button("Открыть оригинал") { NSWorkspace.shared.open(url) }
            }
            Button(ids.compactMap(model.lead).allSatisfy(\.favorite) ? "Убрать из избранного" : "В избранное") {
                model.toggleFavorite(ids)
            }
            if model.section == .archive {
                Button("Вернуть из архива") { model.setArchived(ids, false) }
            } else {
                Button("В архив") { model.setArchived(ids, true) }
            }
            Button("Экспортировать…") { model.selection = ids; exportShown = true }
            if let one {
                Divider()
                if let domain = one.data.domain { Button("Исключить домен \(domain)") { model.exclude(.domain, domain) } }
                ForEach(one.data.phones, id: \.self) { p in Button("Исключить телефон \(p)") { model.exclude(.phone, p) } }
                Button("Исключить по названию") { model.exclude(.name, one.data.title) }
            }
            Divider()
            Button("Удалить", role: .destructive) { model.delete(ids) }
        }
    }

    // MARK: Панели

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Picker("Тип", selection: $model.filter.kind) {
                Text("Все типы").tag(LeadKind?.none)
                ForEach(LeadKind.allCases, id: \.self) { Text($0.title).tag(LeadKind?.some($0)) }
            }
            .fixedSize()
            Picker("Источник", selection: $model.filter.source) {
                Text("Все источники").tag(String?.none)
                ForEach(model.allSources, id: \.self) { Text(SourceCatalog.title($0)).tag(String?.some($0)) }
            }
            .fixedSize()
            if !model.allRegions.isEmpty {
                Picker("Регион", selection: $model.filter.region) {
                    Text("Все регионы").tag(String?.none)
                    ForEach(model.allRegions, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
            }
            Picker("Оценка", selection: $model.filter.minScore) {
                Text("Любая оценка").tag(0.0)
                Text("от 25").tag(25.0)
                Text("от 45").tag(45.0)
                Text("от 60").tag(60.0)
                Text("от 70").tag(70.0)
            }
            .fixedSize()
            Toggle("Скрыть неподходящие", isOn: $model.filter.hideRejected)
                .toggleStyle(.checkbox)
            Spacer()
            if model.filter != LeadFilter(search: model.filter.search) {
                Button("Сбросить") { model.filter = LeadFilter(search: model.filter.search) }
                    .buttonStyle(.link)
            }
        }
        .labelsHidden()
        .appFont(12)
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 8)
    }

    private var bulkBar: some View {
        HStack(spacing: 14) {
            Text("Выбрано: \(model.selection.count)").appFont(12.5, .semibold)
            Button { model.toggleFavorite(model.selection) } label: { Label("В избранное", systemImage: "star") }
            Button { exportShown = true } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
            if model.section == .archive {
                Button { model.setArchived(model.selection, false) } label: { Label("Из архива", systemImage: "tray.and.arrow.up") }
            } else {
                Button { model.setArchived(model.selection, true) } label: { Label("В архив", systemImage: "archivebox") }
            }
            Button(role: .destructive) { model.delete(model.selection) } label: { Label("Удалить", systemImage: "trash") }
            Spacer()
            Button("Снять выбор") { model.selection = [] }.buttonStyle(.link)
        }
        .buttonStyle(.borderless)
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 7)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label("Все данные хранятся на этом Mac", systemImage: "lock.shield")
            Text(model.databasePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let at = model.lastStateAt { Text("Последний поиск в Actions: \(at.shortRelative)") }
        }
        .appFont(11)
        .foregroundStyle(.secondary)
        .scaledPadding(.horizontal, 14)
        .scaledPadding(.vertical, 5)
    }

    @ViewBuilder private var emptyState: some View {
        if model.leads.isEmpty {
            ContentUnavailableView {
                Label("Лидов пока нет", systemImage: "tray")
            } description: {
                Text(model.syncConfigured
                     ? "Нажмите «Синхронизировать», чтобы забрать результаты поиска из GitHub Actions."
                     : "Поиск выполняется в GitHub Actions. Укажите в настройках токен GitHub и ключ шифрования состояния, чтобы получать лиды.")
            } actions: {
                if model.syncConfigured {
                    Button("Синхронизировать") { Task { await model.syncNow(force: true) } }
                } else {
                    SettingsLink { Text("Открыть настройки") }
                }
            }
        } else {
            ContentUnavailableView.search(text: model.filter.search)
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { exportShown = true } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                .help("Экспорт выбранных или всех показанных лидов")
            Button { Task { await model.syncNow() } } label: {
                Label("Синхронизировать", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.syncing)
            .help("Забрать свежие результаты из GitHub Actions (⌘R)")
            Button { Task { await model.dispatchSearch() } } label: { Label("Запустить поиск", systemImage: "play.fill") }
                .disabled(model.dispatching)
                .help("Запустить поиск в GitHub Actions сейчас (⇧⌘R)")
            Button { model.inspectorShown.toggle() } label: { Label("Правая панель", systemImage: "sidebar.right") }
        }
    }
}

// MARK: - Экспорт

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [LeadItem]
    @State private var format: ExportFormat = .csv
    @State private var fields: Set<ExportField> = Set(ExportField.defaults)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Экспорт лидов: \(items.count)").appFont(15, .semibold)
            Picker("Формат", selection: $format) {
                ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Поля").appFont(12, .medium).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(ExportField.allCases) { f in
                    Toggle(f.title, isOn: Binding(get: { fields.contains(f) }, set: { if $0 { fields.insert(f) } else { fields.remove(f) } }))
                        .toggleStyle(.checkbox)
                }
            }
            Text("XLSX, PDF и XML появятся в следующей версии. CSV открывается в Excel и Numbers.")
                .appFont(11).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить…") { save() }.keyboardShortcut(.defaultAction).disabled(fields.isEmpty || items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "leads.\(format.fileExtension)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ordered = ExportField.allCases.filter(fields.contains)
        model.export(items, format: format, fields: ordered, to: url)
        dismiss()
    }
}
