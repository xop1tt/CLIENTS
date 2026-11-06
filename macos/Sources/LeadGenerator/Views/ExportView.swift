import AppKit
import LeadGenCore
import SwiftUI
import UniformTypeIdentifiers

/// Вкладки окна «Экспорт в…».
enum ExportTab: String, CaseIterable, Identifiable {
    case file, bitrix, notion, webhook
    var id: String { rawValue }
    var title: String {
        switch self {
        case .file: return "Файл"
        case .bitrix: return "Bitrix24"
        case .notion: return "Notion"
        case .webhook: return "Вебхук"
        }
    }
    var menuTitle: String {
        switch self {
        case .file: return "Файл CSV или JSON…"
        case .bitrix: return "Bitrix24…"
        case .notion: return "Notion…"
        case .webhook: return "Вебхук (Make, n8n, Zapier)…"
        }
    }
    var icon: String {
        switch self {
        case .file: return "doc.text"
        case .bitrix: return "building.2"
        case .notion: return "tablecells"
        case .webhook: return "point.3.connected.trianglepath.dotted"
        }
    }
    var crm: CRMKind? {
        switch self {
        case .file: return nil
        case .bitrix: return .bitrix
        case .notion: return .notion
        case .webhook: return .webhook
        }
    }
    static let lastKey = "export.lastTab"
    static var last: ExportTab { UserDefaults.standard.string(forKey: lastKey).flatMap(ExportTab.init) ?? .file }
}

// MARK: - Подключения: секреты в Связке ключей, остальное в UserDefaults

/// Настройки Notion, кроме ключа: база, её свойства и сопоставление полей.
struct NotionLink: Codable, Equatable {
    var databaseID: String
    var title: String
    var properties: [Prop]
    var mapping: [String: String]

    struct Prop: Codable, Equatable { var name: String; var type: String }

    var notionProperties: [NotionProperty] { properties.map { NotionProperty(name: $0.name, type: $0.type) } }
    var fieldMapping: [String: ExportField] { mapping.compactMapValues(ExportField.init) }
}

extension AppModel {
    private var exportUser: String { username.lowercased() }

    func crmSecret(_ kind: CRMKind) -> String? {
        Keychain.get("\(kind.keychainAccount).\(exportUser)").flatMap { $0.isEmpty ? nil : $0 }
    }

    func setCRMSecret(_ kind: CRMKind, _ value: String?) {
        Keychain.set("\(kind.keychainAccount).\(exportUser)", value ?? "")
    }

    var notionLink: NotionLink? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "export.notion.\(exportUser)") else { return nil }
            return try? JSONDecoder().decode(NotionLink.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "export.notion.\(exportUser)")
            } else {
                UserDefaults.standard.removeObject(forKey: "export.notion.\(exportUser)")
            }
        }
    }

    func exportLedger(_ destination: CRMDestination) -> ExportLedger {
        ExportLedger.decode(store?.value(ExportLedger.storageKey(kind: destination.kind, target: destination.target)))
    }

    func saveExportLedger(_ ledger: ExportLedger, for destination: CRMDestination) {
        try? store?.setValue(ExportLedger.storageKey(kind: destination.kind, target: destination.target), ledger.encoded())
    }

    /// Лиды для экспорта: выбранные или все показанные в текущем разделе.
    var exportItems: [LeadItem] {
        let visible = visibleLeads.sorted { $0.data.score > $1.data.score }
        guard !selection.isEmpty else { return visible }
        let chosen = visible.filter { selection.contains($0.id) }
        return chosen.isEmpty ? selection.compactMap(lead) : chosen
    }

    /// Открыть «Экспорт в…» на нужной вкладке (из меню, кнопки или контекстного меню).
    func openExport(_ tab: ExportTab? = nil) {
        if !section.isLeadList && selection.isEmpty { section = .all }
        let t = tab ?? ExportTab.last
        if exportTab != t { exportTab = t }
    }
}

// MARK: - Ход отправки

@MainActor @Observable
final class CRMRun {
    var done = 0
    var total = 0
    var running = false
    var report: CRMReport?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(_ items: [LeadItem], to destination: CRMDestination, model: AppModel, resend: Bool) {
        guard !running else { return }
        running = true
        report = nil
        done = 0
        total = items.count
        let ledger = model.exportLedger(destination)
        task = Task { [weak self] in
            let (report, updated) = await CRMExporter.run(items, to: destination, ledger: ledger, resend: resend) { i, n in
                Task { @MainActor [weak self] in
                    guard let self, self.running else { return }
                    if self.done != i { self.done = i }
                    if self.total != n { self.total = n }
                }
            }
            guard let self else { return }
            // Журнал сохраняется и после отмены: отправленное уже лежит в CRM.
            model.saveExportLedger(updated, for: destination)
            self.report = report
            self.running = false
            if report.failures.isEmpty {
                model.lastMessage = "\(destination.kind.title): \(report.summary.lowercased())"
            } else {
                model.lastError = "\(destination.kind.title): \(report.summary.lowercased()). \(report.failures[0].message)"
            }
        }
    }

    func cancel() { task?.cancel() }
}

// MARK: - Окно

struct ExportSheet: View {
    @Environment(\.appModel) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [LeadItem]
    @State var tab: ExportTab
    @State private var run = CRMRun()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Экспорт в…").appFont(15, .semibold)
                Spacer()
                Text(items.count == 1 ? "1 лид" : "Лидов: \(items.count)").appFont(12).foregroundStyle(.secondary)
            }
            Picker("Куда", selection: $tab) {
                ForEach(ExportTab.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(run.running)
            Divider()
            Group {
                switch tab {
                case .file: FileExportPane(items: items, close: { dismiss() })
                case .bitrix: BitrixPane(items: items, run: run)
                case .notion: NotionPane(items: items, run: run)
                case .webhook: WebhookPane(items: items, run: run)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if tab != .file {
                    Link("Как подключить", destination: Updates.wikiPage.appendingPathComponent("Экспорт-в-CRM"))
                        .appFont(12)
                }
                Spacer()
                if run.running {
                    Button("Остановить") { run.cancel() }
                }
                Button(tab == .file ? "Отмена" : "Закрыть") { run.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onChange(of: tab) { _, t in
            UserDefaults.standard.set(t.rawValue, forKey: ExportTab.lastKey)
            if !run.running { run.report = nil }
        }
    }
}

/// Прежний экспорт в файл.
private struct FileExportPane: View {
    @Environment(\.appModel) private var model
    let items: [LeadItem]
    let close: () -> Void
    @State private var format: ExportFormat = .csv
    @State private var fields: Set<ExportField> = Set(ExportField.defaults)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Text("CSV открывается в Excel и Numbers, его же принимает импорт amoCRM, HubSpot и большинства CRM.")
                .appFont(11).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Сохранить…") { save() }.keyboardShortcut(.defaultAction).disabled(fields.isEmpty || items.isEmpty)
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "leads.\(format.fileExtension)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(items, format: format, fields: ExportField.allCases.filter(fields.contains), to: url)
        close()
    }
}

// MARK: - Общие части

/// Подсказка, что делать на стороне сервиса.
private struct Steps: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").appFont(12, .medium).foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
                    Text(s).appFont(12).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ConnectedHeader: View {
    let title: String
    let detail: String
    let disconnect: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).appFont(13, .semibold)
                Text(detail).appFont(11).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Отключить", role: .destructive, action: disconnect)
        }
    }
}

/// Кнопка отправки, ход и итог. Общая для всех сервисов.
private struct SendSection: View {
    @Environment(\.appModel) private var model
    let items: [LeadItem]
    let destination: CRMDestination?
    let run: CRMRun
    var note: String? = nil
    @State private var resend = false

    private var alreadySent: Int {
        guard let destination else { return 0 }
        let ledger = model.exportLedger(destination)
        return items.filter { ledger.sent[$0.id] != nil }.count
    }

    var body: some View {
        let sent = alreadySent
        let toSend = resend ? items.count : items.count - sent
        VStack(alignment: .leading, spacing: 10) {
            if sent > 0 {
                Toggle("Отправить повторно уже отправленные сюда (\(sent))", isOn: $resend)
                    .toggleStyle(.checkbox).appFont(12)
                    .disabled(run.running)
            }
            if let note { Text(note).appFont(11).foregroundStyle(.secondary) }
            if run.running {
                ProgressView(value: Double(run.done), total: Double(max(run.total, 1))) {
                    Text("Отправлено \(run.done) из \(run.total)…").appFont(12)
                }
            } else if let r = run.report {
                VStack(alignment: .leading, spacing: 4) {
                    Label(r.summary + (r.stoppedEarly ? ". Остановлено." : ""),
                          systemImage: r.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(r.failures.isEmpty ? Color.green : Color.orange)
                        .appFont(12, .medium)
                    ForEach(Array(r.failures.prefix(4).enumerated()), id: \.offset) { _, f in
                        Text("• \(f.title): \(f.message)").appFont(11).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if r.failures.count > 4 { Text("…и ещё \(r.failures.count - 4)").appFont(11).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Spacer()
                Button(toSend == 0 && !items.isEmpty ? "Все уже отправлены" : "Отправить лиды: \(toSend)") {
                    if let destination { run.start(items, to: destination, model: model, resend: resend) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil || run.running || toSend == 0)
            }
        }
    }
}

private struct ErrorText: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).appFont(12)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Bitrix24

private struct BitrixPane: View {
    @Environment(\.appModel) private var model
    let items: [LeadItem]
    let run: CRMRun
    @State private var secret: String?
    @State private var input = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let secret, let d = try? Bitrix24Destination(webhook: secret) {
                ConnectedHeader(title: "Bitrix24 подключён", detail: d.target) {
                    model.setCRMSecret(.bitrix, nil); self.secret = nil
                }
                Text("Каждый лид станет лидом в CRM: название, компания, телефоны, email, сайт, адрес, бюджет; описание, ссылка и оценка — в комментарии.")
                    .appFont(12).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SendSection(items: items, destination: d, run: run,
                            note: "Повторно отправленные лиды не обновляют прежние, а создают новые записи.")
            } else {
                Text("Подключить Bitrix24").appFont(14, .semibold)
                Steps(lines: [
                    "В Bitrix24 откройте «Разработчикам» → «Другое» → «Входящий вебхук».",
                    "В правах отметьте «CRM (crm)» и сохраните.",
                    "Скопируйте адрес вебхука и вставьте сюда.",
                ])
                SecureField("https://ваш-портал.bitrix24.ru/rest/1/…/", text: $input)
                    .textFieldStyle(.roundedBorder)
                Text("Адрес вебхука — это ключ доступа к CRM. Он хранится только в Связке ключей этого Mac.")
                    .appFont(11).foregroundStyle(.secondary)
                ErrorText(text: error)
                HStack {
                    Spacer()
                    if checking { ProgressView().controlSize(.small) }
                    Button("Проверить и подключить") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                }
            }
        }
        .onAppear { secret = model.crmSecret(.bitrix) }
    }

    private func connect() {
        error = nil
        let d: Bitrix24Destination
        do { d = try Bitrix24Destination(webhook: input) } catch { self.error = error.localizedDescription; return }
        checking = true
        Task {
            do {
                try await d.check()
                model.setCRMSecret(.bitrix, d.base.absoluteString)
                secret = d.base.absoluteString
                input = ""
            } catch { self.error = error.localizedDescription }
            checking = false
        }
    }
}

// MARK: - Notion

private struct NotionPane: View {
    @Environment(\.appModel) private var model
    let items: [LeadItem]
    let run: CRMRun
    @State private var token: String?
    @State private var link: NotionLink?
    @State private var tokenInput = ""
    @State private var dbInput = ""
    @State private var busy = false
    @State private var error: String?

    private var destination: NotionDestination? {
        guard let token, let link else { return nil }
        return NotionDestination(token: token, databaseID: link.databaseID,
                                 properties: link.notionProperties, mapping: link.fieldMapping)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let link, token != nil {
                ConnectedHeader(title: "Notion: «\(link.title)»", detail: link.databaseID) {
                    model.setCRMSecret(.notion, nil)
                    model.notionLink = nil
                    token = nil; self.link = nil
                }
                mappingEditor(link)
                ErrorText(text: error)
                SendSection(items: items, destination: hasTitle(link) ? destination : nil, run: run,
                            note: hasTitle(link) ? "Описание, ссылка и оценка лида пишутся в текст страницы." : "Сопоставьте с чем-нибудь свойство-заголовок базы, иначе Notion не примет страницу.")
            } else {
                Text("Подключить Notion").appFont(14, .semibold)
                Steps(lines: [
                    "Откройте notion.so/my-integrations → «New integration» (тип Internal), скопируйте ключ.",
                    "Откройте базу данных для лидов → ••• → «Подключения» → добавьте эту интеграцию.",
                    "Скопируйте ссылку на базу (••• → «Скопировать ссылку») и вставьте ниже.",
                ])
                SecureField("Ключ интеграции (ntn_… или secret_…)", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                TextField("Ссылка на базу данных или её ID", text: $dbInput)
                    .textFieldStyle(.roundedBorder)
                Text("Ключ хранится только в Связке ключей этого Mac.").appFont(11).foregroundStyle(.secondary)
                ErrorText(text: error)
                HStack {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Проверить и подключить") { connect(token: tokenInput, database: dbInput) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty || dbInput.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
        .onAppear {
            token = model.crmSecret(.notion)
            link = model.notionLink
        }
    }

    private func hasTitle(_ link: NotionLink) -> Bool {
        link.properties.contains { $0.type == "title" && link.mapping[$0.name] != nil }
    }

    @ViewBuilder private func mappingEditor(_ link: NotionLink) -> some View {
        let writable = link.notionProperties.filter(\.isWritable)
        HStack {
            Text("Сопоставление полей").appFont(12, .medium).foregroundStyle(.secondary)
            Spacer()
            Button("Обновить свойства базы") {
                if let token { connect(token: token, database: link.databaseID, keepMapping: link.mapping) }
            }
            .buttonStyle(.link).appFont(12).disabled(busy || run.running)
        }
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(writable) { p in
                    GridRow {
                        Text(p.name).appFont(12).lineLimit(1)
                        Text(p.typeTitle).appFont(11).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { link.mapping[p.name].flatMap(ExportField.init) },
                            set: { f in
                                var l = link
                                l.mapping[p.name] = f?.rawValue
                                self.link = l
                                model.notionLink = l
                            })) {
                            Text("Не заполнять").tag(ExportField?.none)
                            Divider()
                            ForEach(ExportField.allCases) { Text($0.title).tag(ExportField?.some($0)) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                }
            }
        }
        .frame(maxHeight: 220)
        let skipped = link.properties.count - writable.count
        if skipped > 0 {
            Text("Свойств, которые экспорт не заполняет (статус, связи, формулы и т. п.): \(skipped)")
                .appFont(11).foregroundStyle(.secondary)
        }
    }

    private func connect(token raw: String, database: String, keepMapping: [String: String]? = nil) {
        error = nil
        let id: String
        do { id = try NotionDestination.databaseID(from: database) } catch { self.error = error.localizedDescription; return }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            do {
                let db = try await NotionDestination.fetchDatabase(token: token, id: id)
                var mapping = NotionDestination.autoMapping(db.properties).mapValues(\.rawValue)
                if let keepMapping {
                    let names = Set(db.properties.map(\.name))
                    mapping = keepMapping.filter { names.contains($0.key) }
                }
                let l = NotionLink(databaseID: db.id, title: db.title,
                                   properties: db.properties.map { .init(name: $0.name, type: $0.type) }, mapping: mapping)
                model.setCRMSecret(.notion, token)
                model.notionLink = l
                self.token = token
                link = l
                tokenInput = ""; dbInput = ""
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

// MARK: - Вебхук

private struct WebhookPane: View {
    @Environment(\.appModel) private var model
    let items: [LeadItem]
    let run: CRMRun
    @State private var secret: String?
    @State private var input = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let secret, let d = try? WebhookDestination(url: secret) {
                ConnectedHeader(title: "Вебхук подключён", detail: d.url.host ?? "") {
                    model.setCRMSecret(.webhook, nil); self.secret = nil
                }
                Text("Каждый лид уходит отдельным POST-запросом с JSON: lead_id и все поля экспорта.")
                    .appFont(12).foregroundStyle(.secondary)
                SendSection(items: items, destination: d, run: run)
            } else {
                Text("Подключить вебхук").appFont(14, .semibold)
                Text("Подходит для бесплатных тарифов Make, n8n (в том числе своего сервера), Zapier и Pipedream: оттуда лиды можно передать в amoCRM, Google Таблицы, Airtable, Trello и другие сервисы.")
                    .appFont(12).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Steps(lines: [
                    "Создайте сценарий с триггером «Webhook» (Custom webhook / Catch hook).",
                    "Скопируйте его адрес (https://…) и вставьте сюда.",
                ])
                SecureField("https://hook.eu1.make.com/…", text: $input)
                    .textFieldStyle(.roundedBorder)
                Text("Адрес хранится только в Связке ключей этого Mac.").appFont(11).foregroundStyle(.secondary)
                ErrorText(text: error)
                HStack {
                    Spacer()
                    Button("Подключить") {
                        do {
                            let d = try WebhookDestination(url: input)
                            model.setCRMSecret(.webhook, d.url.absoluteString)
                            secret = d.url.absoluteString
                            input = ""; error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { secret = model.crmSecret(.webhook) }
    }
}
